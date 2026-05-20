import Foundation

/// A batch of analyzer requests submitted to the Anthropic Message
/// Batches API and awaiting collection.
///
/// One row per in-flight batch. The `transcript` is unique — a transcript
/// has at most one batch in flight at a time, which keeps the
/// `assess_progress` high-water mark contiguous (no holes from
/// out-of-order or overlapping batches). `minTurn ... maxTurn` is the
/// inclusive backlog range the batch covers.
public struct PendingBatch: Friendly {
    /// The Anthropic batch id (e.g. `msgbatch_…`).
    public let batchID: String
    /// The transcript identity whose backlog this batch covers.
    public let transcript: String
    /// The lowest turn index in the batch (inclusive).
    public let minTurn: Int
    /// The highest turn index in the batch (inclusive).
    public let maxTurn: Int
    /// When the batch was submitted.
    public let submittedAt: Date

    /// Creates a pending-batch record.
    public init(batchID: String, transcript: String, minTurn: Int, maxTurn: Int, submittedAt: Date) {
        self.batchID = batchID
        self.transcript = transcript
        self.minTurn = minTurn
        self.maxTurn = maxTurn
        self.submittedAt = submittedAt
    }
}
