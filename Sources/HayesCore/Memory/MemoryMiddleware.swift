import Foundation
import Operator

private let memoryToolName = "memory"

/// `Operator.Middleware` that wires Hayes's memory pipeline around a run.
///
/// - `beforeRequest` infers functional-context phrases from the recent
///   conversation, embeds them, deduplicates against the corpus, retrieves
///   related seeds + behaviors, and injects them via a synthetic
///   `memory` tool exchange.
/// - `afterRun` summarises pending acts, runs the analysis call, applies
///   `user_feedback` / `self_assessment` attributions to prior acts, inserts
///   behavior nodes for any `moves`, and creates a new pending act for the
///   current turn.
public final class MemoryMiddleware: Middleware, @unchecked Sendable {
    private let store: GraphStore
    private let embeddings: any EmbeddingProvider
    private let extractor: ContextExtractor
    private let analyzer: AnalysisRunner
    private let config: RetrievalConfig

    private let lock = NSLock()
    /// Carries context-node IDs from `beforeRequest` to the matching
    /// `afterRun`. Key is a stable hash of the triggering user message —
    /// good enough for single-user CLI. Swap for a real run ID when
    /// Operator exposes one.
    private var runContextNodeIDs: [String: [String]] = [:]

    private let continuation: AsyncStream<MiddlewareEvent>.Continuation
    /// Stream of memory-pipeline events produced during middleware execution.
    public let events: AsyncStream<MiddlewareEvent>

    /// Creates a new middleware.
    /// - Parameters:
    ///   - store: The graph store.
    ///   - embeddings: The embedding provider.
    ///   - extractor: The context extractor (pre-gen inference stage).
    ///   - analyzer: The analysis runner (post-run analysis stage).
    ///   - config: Tunable parameters for retrieval and reinforcement.
    public init(
        store: GraphStore,
        embeddings: any EmbeddingProvider,
        extractor: ContextExtractor,
        analyzer: AnalysisRunner,
        config: RetrievalConfig = .default
    ) {
        self.store = store
        self.embeddings = embeddings
        self.extractor = extractor
        self.analyzer = analyzer
        self.config = config

        var localContinuation: AsyncStream<MiddlewareEvent>.Continuation!
        events = AsyncStream<MiddlewareEvent> { localContinuation = $0 }
        continuation = localContinuation
    }

    deinit {
        continuation.finish()
    }

    public func beforeRequest(_ context: inout RequestContext) async throws {
        if context.messages.contains(where: Self.isMemoryToolCall) {
            return
        }

        let window = Self.trimWindow(context.messages, size: config.contextWindowSize)
        guard !window.isEmpty else { return }

        guard let triggerKey = Self.runKey(from: window) else { return }

        let phrases = try await extractor.extract(recentMessages: window)

        // Embed first so retrieval runs against the prior corpus. Otherwise
        // fresh phrases inserted before retrieval would surface as their
        // own seeds in an empty or near-empty graph.
        let phraseEmbeddings = try phrases.map { try embeddings.embed($0) }

        let result = try await store.retrieve(
            contextEmbeddings: phraseEmbeddings,
            config: config
        )

        var snapshot = await store.embeddingSnapshot()
        var contextNodes: [Node] = []
        for (phrase, embedding) in zip(phrases, phraseEmbeddings) {
            let node = try await ensureNode(text: phrase, embedding: embedding, in: &snapshot)
            contextNodes.append(node)
        }

        emit(.memoryInjected(seeds: result.seeds, behaviors: result.behaviors))

        let payload = result.behaviors.map { scored in
            BehaviorPayload(id: scored.value.id, text: scored.value.text, score: scored.score)
        }
        try context.appendToolExchange(
            toolName: memoryToolName,
            arguments: phrases,
            result: ToolOutput(encoding: payload)
        )

        lock.withLock {
            runContextNodeIDs[triggerKey] = contextNodes.map(\.id)
        }
    }

    public func afterRun(_ context: RunContext) async throws {
        let pending = try await store.recentActs(
            limit: config.recentActsWindow,
            statuses: [.pending]
        )
        let behaviorIDSet: [String] = pending.flatMap(\.behaviorIDs).unique
        let behaviorNodes = try await store.findNodes(ids: behaviorIDSet)
        let textByID: [String: String] = Dictionary(
            uniqueKeysWithValues: behaviorNodes.map { ($0.id, $0.text) }
        )

        let summaries: [AnalysisRunner.RecentActSummary] = pending.map { act in
            let texts = act.behaviorIDs.compactMap { textByID[$0] }
            return AnalysisRunner.RecentActSummary(
                id: act.id,
                behaviors: texts,
                createdAt: act.createdAt
            )
        }

        let userMessage = Self.lastUserText(in: context.messages) ?? ""
        let result = try await analyzer.analyze(
            userMessage: userMessage,
            thinking: context.thinking,
            recentActs: summaries
        )

        // Sequential by design: each call mutates the same `GraphStore`
        // actor, so parallelism would collapse to serialization anyway and
        // ordering would become nondeterministic. User feedback runs first
        // so it wins the once-feedback-per-act race against self-assessment.
        try await applyFeedback(result.userFeedback, scale: config.userFeedbackScale)
        emit(.userFeedback(result.userFeedback))

        try await applyFeedback(result.selfAssessment, scale: config.selfAssessmentScale)
        emit(.selfAssessment(result.selfAssessment))

        var snapshot = await store.embeddingSnapshot()
        var behaviorNodeList: [Node] = []
        for move in result.moves {
            let embedding = try embeddings.embed(move)
            let node = try await ensureNode(text: move, embedding: embedding, in: &snapshot)
            behaviorNodeList.append(node)
        }
        emit(.movesExtracted(texts: result.moves))

        let triggerKey = Self.runKey(from: context.messages)
        let seedIDs: [String] = lock.withLock {
            guard let key = triggerKey else { return [] }
            return runContextNodeIDs.removeValue(forKey: key) ?? []
        }

        let behaviorIDs = behaviorNodeList.map(\.id)
        let act = try await store.insertAct(seedIDs: seedIDs, behaviorIDs: behaviorIDs)
        emit(.actCreated(id: act.id, seedIDs: seedIDs, behaviorIDs: behaviorIDs))
    }

    // MARK: - Helpers

    private func emit(_ event: MiddlewareEvent) {
        continuation.yield(event)
    }

    private func applyFeedback(_ feedback: [ActFeedback], scale: Double) async throws {
        for entry in feedback {
            do {
                try await store.applyFeedback(
                    actID: entry.actID,
                    sentiment: entry.sentiment,
                    sourceScale: scale,
                    config: config
                )
            } catch GraphStore.Error.actNotFound {
                continue
            }
        }
    }

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

    static func trimWindow(_ messages: [Operator.Message], size: Int) -> [Operator.Message] {
        guard size > 0 else { return [] }
        let tail = Array(messages.suffix(size))
        if let firstUser = tail.firstIndex(where: { $0.role == .user }) {
            return Array(tail[firstUser...])
        }
        return tail
    }

    static func isMemoryToolCall(_ message: Operator.Message) -> Bool {
        guard message.role == .assistant, let calls = message.toolCalls else { return false }
        return calls.contains { $0.name == memoryToolName }
    }

    static func lastUserText(in messages: [Operator.Message]) -> String? {
        messages.reversed().first { $0.role == .user }?.textContent
    }

    static func runKey(from messages: [Operator.Message]) -> String? {
        guard let text = lastUserText(in: messages) else { return nil }
        return shortHash(text)
    }

    static func shortHash(_ text: String) -> String {
        // `Hasher` is per-process-seeded, which is fine: the map's lifetime
        // is a single process. If state is ever persisted or a stable run
        // ID becomes available, revisit.
        var hasher = Hasher()
        hasher.combine(text)
        let value = UInt(bitPattern: hasher.finalize())
        return String(value, radix: 16)
    }

    private struct BehaviorPayload: Encodable {
        let id: String
        let text: String
        let score: Double
    }
}

private extension Array where Element: Hashable {
    var unique: [Element] {
        var seen: Set<Element> = []
        var out: [Element] = []
        for item in self where seen.insert(item).inserted {
            out.append(item)
        }
        return out
    }
}
