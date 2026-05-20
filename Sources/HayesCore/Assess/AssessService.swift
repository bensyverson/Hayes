import Foundation
import Operator

/// The offline library entrypoint that turns a completed transcript
/// into graph edges.
///
/// `AssessService` is what the `hayes assess` CLI subcommand calls. It
/// runs an analyzer (live or canned) over the input messages — either
/// per-turn in parallel or one-shot over the whole conversation — and
/// reinforces graph edges for each distilled ``Lesson``, threading
/// provenance fields (`source_transcript`, `turn_index`,
/// `source_excerpt`) into the writes.
///
/// Assessment is idempotent per transcript: the service records the
/// highest turn index it has processed (see
/// ``GraphStore/advanceAssessProgress(identity:to:)``) and on later runs
/// analyzes only newer turns, so each turn reinforces its edges exactly
/// once even though hooks pass the full transcript every time. Pass
/// ``AssessOptions/reassess`` to force a full reprocess.
public struct AssessService: Sendable {
    private let store: GraphStore
    private let embeddings: any EmbeddingProvider
    private let analyzer: any Analyzing
    private let backend: MemoryBackend
    private let config: RetrievalConfig

    /// Errors thrown by ``assess(messages:transcriptIdentity:options:)``.
    public enum AssessError: Swift.Error, Sendable, LocalizedError {
        /// The caller requested
        /// ``AssessOptions/Strategy/oneShot`` on
        /// ``MemoryBackend/appleIntelligence``, whose context window
        /// cannot accommodate a full transcript.
        case oneShotNotSupportedOnAppleIntelligence

        public var errorDescription: String? {
            switch self {
            case .oneShotNotSupportedOnAppleIntelligence:
                "One-shot assess is not supported on Apple Intelligence; use --strategy parallel."
            }
        }
    }

    /// Creates a new service.
    /// - Parameters:
    ///   - store: The graph store.
    ///   - embeddings: The embedding provider used to materialize seed
    ///     and behavior nodes.
    ///   - analyzer: The lesson-extraction backend.
    ///   - backend: The model backend the analyzer is configured with.
    ///     Used to validate strategy compatibility.
    ///   - config: Retrieval configuration. Drives `dedupThreshold`
    ///     and the per-source reinforcement scale.
    public init(
        store: GraphStore,
        embeddings: any EmbeddingProvider,
        analyzer: any Analyzing,
        backend: MemoryBackend,
        config: RetrievalConfig = .default
    ) {
        self.store = store
        self.embeddings = embeddings
        self.analyzer = analyzer
        self.backend = backend
        self.config = config
    }

    /// Runs one assess pass over `messages` and writes any lessons it
    /// produces.
    /// - Parameters:
    ///   - messages: The transcript to analyze.
    ///   - transcriptIdentity: The harness-native session id or other
    ///     stable identifier for `messages`. Persisted as
    ///     `edges.source_transcript` unless `options.storeSource` is
    ///     `false`.
    ///   - options: Caller knobs (strategy, source-storage toggle,
    ///     excerpt length).
    /// - Returns: The lessons that were materialized into the graph.
    public func assess(
        messages: [Operator.Message],
        transcriptIdentity: String?,
        options: AssessOptions = .default
    ) async throws -> AssessResult {
        guard !messages.isEmpty else { return .empty }
        try validate(options.strategy)

        // The highest turn already assessed for this transcript, used to
        // skip turns we've processed before. Tracked regardless of
        // `storeSource` — progress is internal bookkeeping, not
        // provenance — and ignored entirely under `--reassess`.
        let priorMax: Int? = if let transcriptIdentity, !options.reassess {
            try await store.assessProgress(for: transcriptIdentity)
        } else {
            nil
        }

        let turns = Self.splitByTurn(messages)
        let transcriptMaxTurn = turns.last?.turnIndex

        let chunks = try await produceChunks(
            messages: messages,
            turns: turns,
            strategy: options.strategy,
            priorMax: priorMax
        )
        guard !chunks.isEmpty else { return .empty }

        // Funnel through the shared ingest seam. `ingest` advances progress
        // after a successful persist (even for lesson-less turns, so they
        // aren't re-analyzed); on a failed write nothing advances and the
        // turns retry next run. Progress is keyed on the real identity
        // regardless of `storeSource` since it's bookkeeping, not provenance.
        let storeIdentity = options.storeSource ? transcriptIdentity : nil
        let analyzedTurns = chunks.map { chunk in
            AnalyzedTurn(
                turnIndex: chunk.turnIndex,
                lessons: chunk.lessons,
                excerpt: options.storeSource
                    ? Self.excerpt(for: chunk.messages, limit: options.sourceExcerptLimit)
                    : nil
            )
        }
        let persisted = try await ingest(
            turns: analyzedTurns,
            provenanceIdentity: storeIdentity,
            progressIdentity: transcriptIdentity,
            advanceProgressTo: transcriptMaxTurn
        )
        return AssessResult(lessons: persisted)
    }

    // MARK: - Strategy validation

    private func validate(_ strategy: AssessOptions.Strategy) throws {
        switch (strategy, backend) {
        case (.oneShot, .appleIntelligence):
            throw AssessError.oneShotNotSupportedOnAppleIntelligence
        default:
            return
        }
    }

    // MARK: - Lesson extraction

    /// A turn-aligned slice of the transcript paired with the lessons
    /// the analyzer extracted from it.
    private struct Chunk {
        let turnIndex: Int?
        let messages: [Operator.Message]
        let lessons: [Lesson]
    }

    /// Runs the analyzer over the turns not yet assessed per the
    /// requested strategy. Parallel mode analyzes each turn whose index
    /// exceeds `priorMax`; one-shot tracks at transcript granularity, so
    /// a non-nil `priorMax` means "already assessed" and yields no
    /// chunks. Parallel mode bounds the number of in-flight calls.
    private func produceChunks(
        messages: [Operator.Message],
        turns: [(turnIndex: Int, messages: [Operator.Message])],
        strategy: AssessOptions.Strategy,
        priorMax: Int?
    ) async throws -> [Chunk] {
        switch strategy {
        case let .parallel(concurrency):
            let floor = priorMax ?? -1
            let newTurns = turns.filter { $0.turnIndex > floor }
            return try await runParallel(turns: newTurns, concurrency: max(1, concurrency))
        case .oneShot:
            guard priorMax == nil else { return [] }
            let result = try await analyzer.analyze(messages: messages, thinking: "")
            return [Chunk(turnIndex: nil, messages: messages, lessons: result.lessons)]
        }
    }

    /// Runs `analyzer.analyze` per turn with at most `concurrency`
    /// concurrent calls in flight. Returns chunks in input order.
    private func runParallel(
        turns: [(turnIndex: Int, messages: [Operator.Message])],
        concurrency: Int
    ) async throws -> [Chunk] {
        guard !turns.isEmpty else { return [] }

        let indexed = turns.enumerated().map { (offset: $0.offset, turn: $0.element) }
        var byOffset: [Int: Chunk] = [:]

        try await withThrowingTaskGroup(of: (Int, Chunk).self) { group in
            var iterator = indexed.makeIterator()
            var inFlight = 0

            func enqueueNext() -> Bool {
                guard let entry = iterator.next() else { return false }
                let offset = entry.offset
                let turn = entry.turn
                let analyzer = self.analyzer
                group.addTask {
                    let result = try await analyzer.analyze(messages: turn.messages, thinking: "")
                    let chunk = Chunk(
                        turnIndex: turn.turnIndex,
                        messages: turn.messages,
                        lessons: result.lessons
                    )
                    return (offset, chunk)
                }
                inFlight += 1
                return true
            }

            for _ in 0 ..< concurrency where enqueueNext() {}
            while inFlight > 0, let (offset, chunk) = try await group.next() {
                byOffset[offset] = chunk
                inFlight -= 1
                _ = enqueueNext()
            }
        }

        return indexed.compactMap { byOffset[$0.offset] }
    }

    // MARK: - Persistence

    /// A turn's analyzer output ready to reinforce: its index, the
    /// distilled lessons, and the optional source excerpt. The live assess
    /// path and the batch collector both funnel through ``ingest(turns:provenanceIdentity:progressIdentity:advanceProgressTo:)``
    /// so reinforcement is identical across them.
    struct AnalyzedTurn {
        /// The zero-based turn index, or `nil` for a one-shot whole-transcript pass.
        let turnIndex: Int?
        /// The lessons distilled from the turn.
        let lessons: [Lesson]
        /// The source excerpt to stamp on each edge, or `nil`.
        let excerpt: String?
    }

    /// Reinforces every lesson across `turns` and advances the stored
    /// assess progress.
    ///
    /// For each lesson it finds-or-creates the seed and behavior nodes and
    /// reinforces the edge between them with the turn's provenance. When
    /// both `progressIdentity` and `advanceProgressTo` are supplied it
    /// advances the progress mark — even if `turns` produced no lessons, so
    /// processed turns aren't re-analyzed.
    /// - Parameters:
    ///   - turns: The analyzed turns to reinforce.
    ///   - provenanceIdentity: The identity stamped on each edge's
    ///     `source_transcript`, or `nil` to omit it (the
    ///     `--no-store-source` shape).
    ///   - progressIdentity: The transcript identity whose progress mark to
    ///     advance, or `nil` to skip progress tracking. Independent of
    ///     `provenanceIdentity` because progress is bookkeeping, not
    ///     provenance.
    ///   - advanceProgressTo: The turn index to advance the mark to.
    /// - Returns: The persisted lessons, in turn order.
    func ingest(
        turns: [AnalyzedTurn],
        provenanceIdentity: String?,
        progressIdentity: String?,
        advanceProgressTo: Int?
    ) async throws -> [AssessResult.PersistedLesson] {
        var output: [AssessResult.PersistedLesson] = []
        var snapshot = await store.embeddingSnapshot()

        for turn in turns where !turn.lessons.isEmpty {
            for lesson in turn.lessons {
                let seedEmbedding = try embeddings.embed(lesson.seed)
                let seedNode = try await ensureNode(
                    text: lesson.seed,
                    embedding: seedEmbedding,
                    in: &snapshot
                )
                let behaviorEmbedding = try embeddings.embed(lesson.behavior)
                let behaviorNode = try await ensureNode(
                    text: lesson.behavior,
                    embedding: behaviorEmbedding,
                    in: &snapshot
                )

                let scale: Double = switch lesson.source {
                case .user: config.userFeedbackScale
                case .selfAssessment: config.selfAssessmentScale
                }
                let provenance = EdgeProvenance(
                    sourceTranscript: provenanceIdentity,
                    turnIndex: turn.turnIndex,
                    sourceExcerpt: turn.excerpt
                )
                try await store.reinforceEdge(
                    seedID: seedNode.id,
                    behaviorID: behaviorNode.id,
                    sentiment: lesson.sentiment,
                    sourceScale: scale,
                    config: config,
                    provenance: provenance
                )

                let edge = try await store.findEdge(
                    sourceID: seedNode.id,
                    targetID: behaviorNode.id
                )
                output.append(AssessResult.PersistedLesson(
                    seedID: seedNode.id,
                    seedText: lesson.seed,
                    behaviorID: behaviorNode.id,
                    behaviorText: lesson.behavior,
                    sentiment: lesson.sentiment,
                    source: lesson.source,
                    turnIndex: turn.turnIndex,
                    edgeWeight: edge?.weight ?? 0
                ))
            }
        }

        if let progressIdentity, let advanceProgressTo {
            try await store.advanceAssessProgress(identity: progressIdentity, to: advanceProgressTo)
        }
        return output
    }

    /// Returns the existing closest-similar node when one clears
    /// `config.dedupThreshold`, otherwise inserts a new node and
    /// updates `snapshot`.
    private func ensureNode(
        text: String,
        embedding: [Float],
        in snapshot: inout [String: [Float]]
    ) async throws -> Node {
        var bestID: String?
        var bestSim: Float = -.infinity
        for (id, candidate) in snapshot where candidate.count == embedding.count {
            let sim = cosineSimilarity(embedding, candidate)
            if sim > bestSim {
                bestSim = sim
                bestID = id
            }
        }
        if let bestID, bestSim >= config.dedupThreshold,
           let existing = try await store.findNode(id: bestID)
        {
            return existing
        }
        let inserted = try await store.insertNode(text: text, embedding: embedding)
        snapshot[inserted.id] = embedding
        return inserted
    }

    // MARK: - Helpers

    /// Splits `messages` into turn-aligned chunks. Each chunk begins
    /// at a genuine user message (role `.user` with `toolCallId ==
    /// nil`) and contains every subsequent message up to but not
    /// including the next user-anchor. Messages preceding the first
    /// user message are dropped — they're harness preamble, not a
    /// turn the analyzer can reason about.
    static func splitByTurn(
        _ messages: [Operator.Message]
    ) -> [(turnIndex: Int, messages: [Operator.Message])] {
        var turns: [(Int, [Operator.Message])] = []
        var current: [Operator.Message] = []
        var index = -1
        var seenUser = false

        for message in messages {
            let isUserAnchor = message.role == .user && message.toolCallId == nil
            if isUserAnchor {
                if seenUser, !current.isEmpty {
                    turns.append((index, current))
                }
                index += 1
                seenUser = true
                current = [message]
            } else if seenUser {
                current.append(message)
            }
        }
        if seenUser, !current.isEmpty {
            turns.append((index, current))
        }
        return turns
    }

    /// Builds the excerpt persisted on each edge produced from this
    /// chunk: the chunk's first user message text, truncated.
    static func excerpt(for messages: [Operator.Message], limit: Int) -> String? {
        guard let text = messages.first(where: { $0.role == .user && $0.toolCallId == nil })?
            .textContent
        else { return nil }
        if text.count <= limit { return text }
        return String(text.prefix(limit))
    }
}
