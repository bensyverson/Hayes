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

        let chunks = try await produceChunks(messages: messages, strategy: options.strategy)
        guard chunks.contains(where: { !$0.lessons.isEmpty }) else { return .empty }

        let persisted = try await persist(
            chunks: chunks,
            transcriptIdentity: transcriptIdentity,
            options: options
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

    /// Splits `messages` into chunks per the requested strategy and
    /// runs the analyzer for each chunk. Parallel mode bounds the
    /// number of in-flight calls.
    private func produceChunks(
        messages: [Operator.Message],
        strategy: AssessOptions.Strategy
    ) async throws -> [Chunk] {
        switch strategy {
        case let .parallel(concurrency):
            let turns = Self.splitByTurn(messages)
            return try await runParallel(turns: turns, concurrency: max(1, concurrency))
        case .oneShot:
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

    /// For each lesson across all chunks, finds-or-creates the seed
    /// and behavior nodes, reinforces the edge between them with the
    /// chunk's provenance, and returns a flat list of persisted
    /// lessons.
    private func persist(
        chunks: [Chunk],
        transcriptIdentity: String?,
        options: AssessOptions
    ) async throws -> [AssessResult.PersistedLesson] {
        var output: [AssessResult.PersistedLesson] = []
        var snapshot = await store.embeddingSnapshot()

        for chunk in chunks {
            guard !chunk.lessons.isEmpty else { continue }
            let excerpt = options.storeSource
                ? Self.excerpt(for: chunk.messages, limit: options.sourceExcerptLimit)
                : nil
            let identity = options.storeSource ? transcriptIdentity : nil

            for lesson in chunk.lessons {
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
                    sourceTranscript: identity,
                    turnIndex: chunk.turnIndex,
                    sourceExcerpt: excerpt
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
                    turnIndex: chunk.turnIndex,
                    edgeWeight: edge?.weight ?? 0
                ))
            }
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
