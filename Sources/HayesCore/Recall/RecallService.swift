import Foundation
import Operator

/// The hook-path entry point that surfaces relevant memory pairs for an
/// in-flight conversation.
///
/// `RecallService` is the library service the `hayes recall` CLI
/// subcommand calls. It bypasses ``MemoryMiddleware`` (which is wired for
/// live Operator runs) and orchestrates a single retrieval pass:
///
/// 1. Trim the conversation tail to a context window.
/// 2. Optionally enrich the window via a `ContextExtractor` LLM call.
/// 3. Embed the query phrases with the configured ``EmbeddingProvider``.
/// 4. Call ``GraphStore/retrieve(contextEmbeddings:config:)`` for
///    candidate seeds + behaviors.
/// 5. For each candidate behavior, pick the strongest contributing seed
///    edge to form a single surfaced (seed, behavior) pair.
/// 6. Skip pairs already recorded in `session_injections` for this
///    session.
/// 7. Record fresh injections (unless ``RecallOptions/storeInjection``
///    is `false` or ``RecallOptions/dryRun`` is `true`).
public struct RecallService: Sendable {
    private let store: GraphStore
    private let embeddings: any EmbeddingProvider
    private let extractor: ContextExtractor?
    private let config: RetrievalConfig
    private let matchedTextLimit: Int

    /// Creates a new recall service.
    /// - Parameters:
    ///   - store: The graph store.
    ///   - embeddings: The embedding provider used for the query.
    ///   - extractor: An optional context extractor. When `nil`, the
    ///     last user message is used verbatim as the only query phrase.
    ///   - config: Retrieval configuration.
    ///   - matchedTextLimit: Maximum length, in characters, of the
    ///     `matched_text` excerpt persisted with each injection. Defaults
    ///     to 500.
    public init(
        store: GraphStore,
        embeddings: any EmbeddingProvider,
        extractor: ContextExtractor? = nil,
        config: RetrievalConfig = .default,
        matchedTextLimit: Int = 500
    ) {
        self.store = store
        self.embeddings = embeddings
        self.extractor = extractor
        self.config = config
        self.matchedTextLimit = matchedTextLimit
    }

    /// Runs one recall pass and returns the surfaced pairs.
    /// - Parameters:
    ///   - messages: The conversation tail (the live transcript).
    ///   - sessionID: The session under which to dedup injections.
    ///   - options: Caller knobs.
    /// - Returns: The recall outcome.
    public func recall(
        messages: [Operator.Message],
        sessionID: String,
        options: RecallOptions = .default
    ) async throws -> RecallResult {
        let windowSize = options.windowSize ?? config.contextWindowSize
        let window = Self.trimWindow(messages, size: windowSize)
        guard !window.isEmpty else { return .empty }

        let phrases = try await resolvePhrases(window: window)
        guard !phrases.isEmpty else { return .empty }

        let phraseEmbeddings = try phrases.map { try embeddings.embed($0) }
        let retrieval = try await store.retrieve(
            contextEmbeddings: phraseEmbeddings,
            config: config
        )
        guard !retrieval.seeds.isEmpty, !retrieval.behaviors.isEmpty else {
            return RecallResult(phrases: phrases, surfaced: [], skipped: [])
        }

        let pairs = try await contributingPairs(from: retrieval)
        let alreadyInjected = try await store.injectedEdges(in: sessionID)

        var surfaced: [RecallResult.SurfacedPair] = []
        var skipped: [RecallResult.SkippedPair] = []
        for pair in pairs {
            let key = EdgeKey(sourceID: pair.seedID, targetID: pair.behaviorID)
            if alreadyInjected.contains(key) {
                if options.dryRun {
                    skipped.append(RecallResult.SkippedPair(
                        seedID: pair.seedID,
                        seedText: pair.seedText,
                        behaviorID: pair.behaviorID,
                        behaviorText: pair.behaviorText,
                        reason: .alreadyInjectedThisSession
                    ))
                }
                continue
            }
            surfaced.append(pair)
        }

        if !options.dryRun, options.storeInjection, !surfaced.isEmpty {
            let matchedText = Self.matchedText(for: window, limit: matchedTextLimit)
            for pair in surfaced {
                try await store.recordInjection(
                    sessionID: sessionID,
                    sourceID: pair.seedID,
                    targetID: pair.behaviorID,
                    matchedText: matchedText
                )
            }
        }

        return RecallResult(phrases: phrases, surfaced: surfaced, skipped: skipped)
    }

    // MARK: - Helpers

    /// Returns the inferred query phrases for the window. With a
    /// configured extractor that's the extractor's output; otherwise the
    /// last user message verbatim.
    private func resolvePhrases(
        window: [Operator.Message]
    ) async throws -> [String] {
        if let extractor {
            return try await extractor.extract(recentMessages: window)
        }
        guard let lastUser = Self.lastUserText(in: window), !lastUser.isEmpty else {
            return []
        }
        return [lastUser]
    }

    /// For each behavior in `retrieval.behaviors`, finds the strongest
    /// contributing edge from any retrieved seed (above the configured
    /// edge-weight floor) and returns one surfaced pair per behavior.
    /// Behaviors with no qualifying contributing edge are dropped.
    private func contributingPairs(
        from retrieval: RetrievalResult
    ) async throws -> [RecallResult.SurfacedPair] {
        var pairs: [RecallResult.SurfacedPair] = []
        for scoredBehavior in retrieval.behaviors {
            var best: (seed: RetrievalResult.Scored<Node>, weight: Double)?
            for scoredSeed in retrieval.seeds {
                guard let edge = try await store.findEdge(
                    sourceID: scoredSeed.value.id,
                    targetID: scoredBehavior.value.id
                ), edge.weight >= config.minEdgeWeight
                else { continue }
                if best == nil || edge.weight > best!.weight {
                    best = (scoredSeed, edge.weight)
                }
            }
            if let best {
                pairs.append(RecallResult.SurfacedPair(
                    seedID: best.seed.value.id,
                    seedText: best.seed.value.text,
                    seedSimilarity: best.seed.score,
                    behaviorID: scoredBehavior.value.id,
                    behaviorText: scoredBehavior.value.text,
                    edgeWeight: best.weight
                ))
            }
        }
        return pairs
    }

    /// Returns the tail of `messages` of length up to `size`, anchored at
    /// the most recent user turn so context windows don't begin
    /// mid-assistant-response.
    static func trimWindow(_ messages: [Operator.Message], size: Int) -> [Operator.Message] {
        guard size > 0 else { return [] }
        let tail = Array(messages.suffix(size))
        if let firstUser = tail.firstIndex(where: { $0.role == .user }) {
            return Array(tail[firstUser...])
        }
        return tail
    }

    /// Returns the latest user text in `messages`, ignoring tool-result
    /// messages (which are role `.user` plumbing rather than user
    /// speech).
    static func lastUserText(in messages: [Operator.Message]) -> String? {
        messages.reversed().first { $0.role == .user && $0.toolCallId == nil }?.textContent
    }

    /// Builds the `matched_text` excerpt persisted with each injection
    /// from this recall pass.
    static func matchedText(for window: [Operator.Message], limit: Int) -> String? {
        guard let text = lastUserText(in: window) else { return nil }
        if text.count <= limit { return text }
        return String(text.prefix(limit))
    }
}
