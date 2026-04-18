import Foundation
import Operator

/// The tool name used for the synthetic tool-exchange injected into the
/// conversation in ``MemoryMiddleware/beforeRequest(_:)``.
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
///
/// The middleware is `final class ... @unchecked Sendable` — matching the
/// ``NLEmbeddingProvider`` pattern — so it can hold per-run mutable state
/// behind an `NSLock`. An actor would force double isolation-hops into
/// ``GraphStore``.
public final class MemoryMiddleware: Middleware, @unchecked Sendable {
    private let store: GraphStore
    private let embeddings: any EmbeddingProvider
    private let extractor: ContextExtractor
    private let analyzer: AnalysisRunner
    private let config: RetrievalConfig

    private let lock = NSLock()
    /// Per-run context-node-ID map. Keyed by SHA256-short of the triggering
    /// user message. Written in `beforeRequest`, read + cleared in `afterRun`.
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
        // Idempotence: if a prior call already injected the synthetic `memory`
        // tool exchange, no-op.
        if context.messages.contains(where: Self.isMemoryToolCall) {
            return
        }

        let window = Self.trimWindow(context.messages, size: config.contextWindowSize)
        guard !window.isEmpty else { return }

        guard let triggerKey = Self.runKey(from: window) else { return }

        let phrases = try await extractor.extract(recentMessages: window)

        // Embed first so we can retrieve against prior corpus state before
        // inserting new context nodes. This keeps the new phrases from
        // retrieving themselves as seeds in an empty or near-empty graph.
        let phraseEmbeddings = try phrases.map { try embeddings.embed($0) }

        let result = try await store.retrieve(
            contextEmbeddings: phraseEmbeddings,
            config: config
        )

        var contextNodes: [Node] = []
        for (phrase, embedding) in zip(phrases, phraseEmbeddings) {
            let node = try await ensureNode(text: phrase, embedding: embedding)
            contextNodes.append(node)
        }

        emit(.memoryInjected(seeds: result.seeds, behaviors: result.behaviors))

        let behaviorsJSON = try Self.encodeBehaviors(result.behaviors)
        try context.appendToolExchange(
            toolName: memoryToolName,
            arguments: phrases,
            result: .init(behaviorsJSON)
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

        for feedback in result.userFeedback {
            do {
                try await store.applyFeedback(
                    actID: feedback.actID,
                    sentiment: feedback.sentiment,
                    sourceScale: config.userFeedbackScale,
                    config: config
                )
            } catch GraphStore.Error.actNotFound {
                continue
            }
        }
        emit(.userFeedback(result.userFeedback))

        for feedback in result.selfAssessment {
            do {
                try await store.applyFeedback(
                    actID: feedback.actID,
                    sentiment: feedback.sentiment,
                    sourceScale: config.selfAssessmentScale,
                    config: config
                )
            } catch GraphStore.Error.actNotFound {
                continue
            }
        }
        emit(.selfAssessment(result.selfAssessment))

        var behaviorNodeList: [Node] = []
        for move in result.moves {
            let embedding = try embeddings.embed(move)
            let node = try await ensureNode(text: move, embedding: embedding)
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

    private func ensureNode(text: String, embedding: [Float]) async throws -> Node {
        let snapshot = await store.embeddingSnapshot()
        var bestID: String?
        var bestSim: Float = -.infinity
        for (id, candidate) in snapshot where candidate.count == embedding.count {
            let sim = cosineSimilarity(embedding, candidate)
            if sim > bestSim {
                bestSim = sim
                bestID = id
            }
        }
        if let bestID, bestSim >= config.dedupThreshold {
            if let existing = try await store.findNode(id: bestID) {
                return existing
            }
        }
        return try await store.insertNode(text: text, embedding: embedding)
    }

    static func trimWindow(_ messages: [Operator.Message], size: Int) -> [Operator.Message] {
        guard size > 0 else { return [] }
        let tail = Array(messages.suffix(size))
        // Trim leading assistant turns so the window starts on user when possible.
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
        // Non-crypto stable hash — SHA-free to keep HayesCore dependency-light.
        // Collisions are vanishingly unlikely for single-user CLI traffic; if
        // Operator later exposes a stable run ID, swap this out.
        var hasher = Hasher()
        hasher.combine(text)
        let value = UInt(bitPattern: hasher.finalize())
        return String(value, radix: 16)
    }

    static func encodeBehaviors(_ behaviors: [RetrievalResult.Scored<Node>]) throws -> String {
        if behaviors.isEmpty { return "{}" }
        let payload = behaviors.map { scored in
            BehaviorPayload(id: scored.value.id, text: scored.value.text, score: scored.score)
        }
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
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

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock(); defer { unlock() }
        return body()
    }
}
