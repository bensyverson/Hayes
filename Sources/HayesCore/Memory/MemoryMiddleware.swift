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
    private let bypassFirstRun: Bool

    private let lock = NSLock()
    /// Carries context-node IDs from `beforeRequest` to the matching
    /// `afterRun`. Key is a stable hash of the triggering user message —
    /// good enough for single-user CLI. Swap for a real run ID when
    /// Operator exposes one.
    private var runContextNodeIDs: [String: [String]] = [:]
    /// Most recent extractor output, fed back in as `priorPhrases` on the
    /// next turn so the working context drifts smoothly across turns
    /// instead of being re-inferred from scratch.
    private var lastExtractedPhrases: [String] = []
    /// Set to `true` once the first `afterRun` completes. Gates the
    /// ``bypassFirstRun`` behaviour so only the very first run in a
    /// session skips `beforeRequest` injection.
    private var hasCompletedFirstRun = false

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
    ///   - bypassFirstRun: When `true`, the very first `beforeRequest`
    ///     in a session is a no-op — no phrase extraction, no retrieval,
    ///     no memory tool exchange. Context extraction happens in the
    ///     matching `afterRun` instead so the act still gets seed IDs.
    ///     Works around Anthropic extended thinking suppressing the
    ///     first assistant response's thinking block when the request
    ///     already contains a synthetic tool_use / tool_result pair.
    ///     Defaults to `false`.
    public init(
        store: GraphStore,
        embeddings: any EmbeddingProvider,
        extractor: ContextExtractor,
        analyzer: AnalysisRunner,
        config: RetrievalConfig = .default,
        bypassFirstRun: Bool = false
    ) {
        self.store = store
        self.embeddings = embeddings
        self.extractor = extractor
        self.analyzer = analyzer
        self.config = config
        self.bypassFirstRun = bypassFirstRun

        var localContinuation: AsyncStream<MiddlewareEvent>.Continuation!
        events = AsyncStream<MiddlewareEvent> { localContinuation = $0 }
        continuation = localContinuation
    }

    deinit {
        continuation.finish()
    }

    public func beforeRequest(_ context: inout RequestContext) async throws {
        let window = Self.trimWindow(context.messages, size: config.contextWindowSize)
        guard !window.isEmpty else { return }

        guard let triggerKey = Self.runKey(from: window) else { return }

        // Per-turn idempotency: if this trigger has already been processed
        // (inner tool-use rounds within the same turn), do nothing. This
        // used to be gated on the presence of a memory tool call in the
        // transcript, but that conflated "already processed this turn"
        // with "turn 2 sees turn 1's persisted injection", which made
        // `afterRun` start a new act with `seedIDs = []`.
        let (alreadyProcessed, isFirstRun): (Bool, Bool) = lock.withLock {
            (runContextNodeIDs[triggerKey] != nil, !hasCompletedFirstRun)
        }
        if alreadyProcessed { return }

        // First-run bypass: with Anthropic extended thinking, injecting
        // a synthetic assistant tool_use / tool_result exchange before
        // the model's first response suppresses the thinking block on
        // that response. Skip injection here; ``afterRun`` will run
        // the same extraction so the act still gets seed IDs.
        if bypassFirstRun, isFirstRun { return }

        let tracked = try await extractAndTrackContext(
            window: window,
            triggerKey: triggerKey
        )

        // If a memory tool exchange from a prior turn is already in the
        // transcript (persisted by Operative back into the conversation),
        // skip re-injection to avoid stacking. The LLM still sees the
        // prior turn's exchange; we just track this turn's seeds for
        // `afterRun`.
        if !context.messages.contains(where: Self.isMemoryToolCall) {
            let payload = tracked.retrieval.behaviors.map { scored in
                BehaviorPayload(id: scored.value.id, text: scored.value.text, score: scored.score)
            }
            // Anthropic's adapter requires tool-use `input` to decode as a
            // JSON object. Wrap the phrases in a dict with a named key so
            // the top-level encoding stays object-shaped regardless of how
            // many phrases were inferred.
            try context.appendToolExchange(
                toolName: memoryToolName,
                arguments: MemoryToolArguments(phrases: tracked.phrases),
                result: ToolOutput(encoding: payload)
            )
        }
    }

    /// Runs phrase extraction + retrieval + node dedupe, emits
    /// ``MiddlewareEvent/memoryInjected``, and records the resulting
    /// seed-node IDs against `triggerKey` for a later ``afterRun`` to
    /// pick up. Shared by the pre-request injection path and the
    /// first-run-bypass path that defers context extraction to
    /// `afterRun`.
    private func extractAndTrackContext(
        window: [Operator.Message],
        triggerKey: String
    ) async throws -> (phrases: [String], retrieval: RetrievalResult) {
        let priorPhrases: [String] = lock.withLock { lastExtractedPhrases }
        let phrases = try await extractor.extract(
            recentMessages: window,
            priorPhrases: priorPhrases
        )

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

        lock.withLock {
            runContextNodeIDs[triggerKey] = contextNodes.map(\.id)
            lastExtractedPhrases = phrases
        }

        return (phrases, result)
    }

    public func afterRun(_ context: RunContext) async throws {
        // If `beforeRequest` was bypassed (first run of a session with
        // `bypassFirstRun == true`), `runContextNodeIDs` is empty for
        // this trigger. Run extraction now so the act still gets seeds.
        if bypassFirstRun {
            try await extractContextIfMissing(for: context.messages)
        }

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

        let turnMessages = Self.lastTurnMessages(context.messages)
        let result = try await analyzer.analyze(
            messages: turnMessages,
            thinking: context.thinking,
            recentActs: summaries
        )

        // Labels are resolved against the pending summaries above so
        // UI rendering doesn't have to fall back to act IDs.
        let labels: [String: String] = Dictionary(
            uniqueKeysWithValues: summaries.map { summary in
                (summary.id, Self.formatActLabel(behaviors: summary.behaviors))
            }
        )
        func attributed(_ entries: [ActFeedback]) -> [MiddlewareEvent.AttributedFeedback] {
            entries.map { entry in
                MiddlewareEvent.AttributedFeedback(
                    actID: entry.actID,
                    label: labels[entry.actID] ?? entry.actID,
                    sentiment: entry.sentiment
                )
            }
        }

        // Sequential by design: each call mutates the same `GraphStore`
        // actor, so parallelism would collapse to serialization anyway and
        // ordering would become nondeterministic. User feedback runs first
        // so it wins the once-feedback-per-act race against self-assessment.
        try await applyFeedback(result.userFeedback, scale: config.userFeedbackScale)
        emit(.userFeedback(attributed(result.userFeedback)))

        try await applyFeedback(result.selfAssessment, scale: config.selfAssessmentScale)
        emit(.selfAssessment(attributed(result.selfAssessment)))

        var snapshot = await store.embeddingSnapshot()
        var behaviorNodeList: [Node] = []
        for move in result.moves {
            let embedding = try embeddings.embed(move)
            let node = try await ensureNode(text: move, embedding: embedding, in: &snapshot)
            behaviorNodeList.append(node)
        }
        emit(.movesExtracted(texts: result.moves))
        if result.moves.isEmpty {
            // The act is still created (seeds + empty behaviors), so the
            // diagnostic is visible in the store, but surface it as a
            // discrete event so the CLI doesn't have to infer from a
            // blank `movesExtracted` that something went wrong.
            emit(.analysisEmpty(reason: "analyzer returned empty moves"))
        }

        let triggerKey = Self.runKey(from: context.messages)
        let seedIDs: [String] = lock.withLock {
            guard let key = triggerKey else { return [] }
            return runContextNodeIDs.removeValue(forKey: key) ?? []
        }

        let behaviorIDs = behaviorNodeList.map(\.id)
        let act = try await store.insertAct(seedIDs: seedIDs, behaviorIDs: behaviorIDs)
        emit(.actCreated(id: act.id, seedIDs: seedIDs, behaviorIDs: behaviorIDs))

        lock.withLock { hasCompletedFirstRun = true }
    }

    /// Extracts context phrases and tracks seed IDs if none have been
    /// recorded for the current trigger yet. Used by ``afterRun`` when
    /// ``bypassFirstRun`` is enabled and the matching ``beforeRequest``
    /// was a no-op.
    ///
    /// Uses ``lastTurnMessages(_:)`` rather than ``trimWindow(_:size:)``
    /// because `afterRun` fires at the end of a run that may include
    /// several tool-use rounds — by which point the triggering user
    /// message has dropped out of a fixed 5-message tail. The last-turn
    /// slice always includes the user message so ``runKey(from:)``
    /// returns a non-nil trigger.
    private func extractContextIfMissing(for messages: [Operator.Message]) async throws {
        let turn = Self.lastTurnMessages(messages)
        guard !turn.isEmpty, let triggerKey = Self.runKey(from: turn) else { return }
        let alreadyTracked: Bool = lock.withLock {
            runContextNodeIDs[triggerKey] != nil
        }
        if alreadyTracked { return }
        _ = try await extractAndTrackContext(window: turn, triggerKey: triggerKey)
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

    /// Builds a compact, human-readable label for an act from its
    /// behavior phrases. Used to enrich feedback events so the UI can
    /// show the act's content rather than an opaque ID.
    static func formatActLabel(behaviors: [String]) -> String {
        let trimmed = behaviors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return "(empty act)" }
        return trimmed.joined(separator: ", ")
    }

    /// Returns the tail of `messages` starting at the most recent
    /// genuine user turn — excluding tool-result messages, which are
    /// encoded with `role == .user` but carry a `toolCallId`. If no
    /// such message is found, returns the full array.
    static func lastTurnMessages(_ messages: [Operator.Message]) -> [Operator.Message] {
        let idx = messages.lastIndex { $0.role == .user && $0.toolCallId == nil }
        guard let start = idx else { return messages }
        return Array(messages[start...])
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

    /// The shape of the synthetic `memory` tool-call's `arguments` field.
    ///
    /// Wraps the inferred phrases in an object so the JSON encoding stays
    /// object-shaped — Anthropic's adapter requires tool-use inputs to
    /// decode as `[String: JSONValue]` and rejects top-level arrays.
    struct MemoryToolArguments: Encodable {
        let phrases: [String]
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
