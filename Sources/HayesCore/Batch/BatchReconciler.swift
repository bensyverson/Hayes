import Foundation
import Operator

/// Drives the no-daemon batch assess path: one idempotent `reconcile()`
/// that collects ready batches and submits backlog, both derived from
/// durable state (`assess_progress` + `pending_batches`).
///
/// `collect()` runs first and globally — it reinforces whatever has come
/// back — then `submit(transcript:messages:)` queues new work for the
/// transcripts in scope. Because everything is reconstructed from the
/// store, the reconciler tolerates missed events and the Claude Code /
/// OpenCode event asymmetry: call it at session start, per-turn, on a cron,
/// or at session end and it converges.
///
/// Anthropic-only — the live synchronous path handles other backends. See
/// `project/2026-05-20-batch-assess-pipeline.md`.
public struct BatchReconciler: Sendable {
    private let store: GraphStore
    private let assess: AssessService
    private let analyzer: AnalysisRunner
    private let batchClient: AnthropicBatchClient

    /// Creates a reconciler.
    /// - Parameters:
    ///   - store: The graph store (owns `pending_batches` and `assess_progress`).
    ///   - assess: The assess service whose ingest seam reinforces collected turns.
    ///   - analyzer: The analyzer used to build per-turn batch request bodies.
    ///   - batchClient: The Anthropic Message Batches client.
    public init(
        store: GraphStore,
        assess: AssessService,
        analyzer: AnalysisRunner,
        batchClient: AnthropicBatchClient
    ) {
        self.store = store
        self.assess = assess
        self.analyzer = analyzer
        self.batchClient = batchClient
    }

    /// Collects every ready batch, then submits backlog for `transcripts`.
    /// - Parameter transcripts: The transcripts to submit backlog for, each
    ///   an identity paired with its loaded messages.
    public func reconcile(submitting transcripts: [Submission]) async throws {
        try await collect()
        for submission in transcripts {
            try await submit(transcript: submission.identity, messages: submission.messages)
        }
    }

    /// A transcript to submit backlog for.
    public struct Submission: Sendable {
        /// The transcript identity.
        public let identity: String
        /// The transcript's loaded messages.
        public let messages: [Operator.Message]

        /// Creates a submission.
        public init(identity: String, messages: [Operator.Message]) {
            self.identity = identity
            self.messages = messages
        }
    }

    // MARK: - Collect

    /// Polls every pending batch; for each that has ended, reinforces its
    /// contiguous succeeded turns, advances progress to the last of them,
    /// and drops the row. A gap (any non-succeeded result) stops ingestion
    /// there, so the uncovered tail re-enters the backlog on the next
    /// `submit`. In-progress batches are left untouched.
    public func collect() async throws {
        for pending in try await store.pendingBatches() {
            let status = try await batchClient.status(batchID: pending.batchID)
            guard status.processingStatus == .ended, let resultsURL = status.resultsURL else { continue }

            let entries = try await batchClient.results(at: resultsURL)
            let outcomesByTurn: [Int: AnthropicBatchClient.Outcome] = Dictionary(
                entries.compactMap { entry in Int(entry.customID).map { ($0, entry.outcome) } },
                uniquingKeysWith: { first, _ in first }
            )

            var turns: [AssessService.AnalyzedTurn] = []
            var lastContiguous: Int?
            var index = pending.minTurn
            while index <= pending.maxTurn {
                guard case let .succeeded(result)? = outcomesByTurn[index] else { break }
                turns.append(AssessService.AnalyzedTurn(turnIndex: index, lessons: result.lessons, excerpt: nil))
                lastContiguous = index
                index += 1
            }

            _ = try await assess.ingest(
                turns: turns,
                provenanceIdentity: pending.transcript,
                progressIdentity: pending.transcript,
                advanceProgressTo: lastContiguous
            )
            try await store.deletePendingBatch(batchID: pending.batchID)
        }
    }

    // MARK: - Submit

    /// Submits the transcript's backlog (turns past `assess_progress`) as a
    /// single batch, unless a batch is already in flight for it. Each turn
    /// becomes one request keyed by its turn index.
    /// - Parameters:
    ///   - identity: The transcript identity.
    ///   - messages: The transcript's loaded messages.
    public func submit(transcript identity: String, messages: [Operator.Message]) async throws {
        guard try await store.pendingBatch(forTranscript: identity) == nil else { return }

        let floor = try await store.assessProgress(for: identity) ?? -1
        let backlog = AssessService.splitByTurn(messages).filter { $0.turnIndex > floor }
        guard let first = backlog.first, let last = backlog.last else { return }

        var requests: [AnthropicBatchClient.Request] = []
        for turn in backlog {
            // nil only on non-Anthropic backends; batch is Anthropic-only.
            guard let body = try analyzer.analyzerRequest(for: turn.messages, thinking: "") else { return }
            requests.append(AnthropicBatchClient.Request(customID: String(turn.turnIndex), params: body))
        }

        let batchID = try await batchClient.submit(requests)
        try await store.insertPendingBatch(
            batchID: batchID,
            transcript: identity,
            minTurn: first.turnIndex,
            maxTurn: last.turnIndex
        )
    }
}
