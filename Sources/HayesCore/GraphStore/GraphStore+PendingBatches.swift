import Foundation
import GRDB

public extension GraphStore {
    /// Records a submitted batch covering `minTurn ... maxTurn` of
    /// `transcript`.
    ///
    /// The `transcript` column is unique, so this throws if the transcript
    /// already has a batch in flight — callers (reconcile) check
    /// ``pendingBatch(forTranscript:)`` first.
    /// - Parameters:
    ///   - batchID: The Anthropic batch id.
    ///   - transcript: The transcript identity the batch covers.
    ///   - minTurn: The lowest turn index in the batch (inclusive).
    ///   - maxTurn: The highest turn index in the batch (inclusive).
    func insertPendingBatch(batchID: String, transcript: String, minTurn: Int, maxTurn: Int) throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO pending_batches (batch_id, transcript, min_turn, max_turn, submitted_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [batchID, transcript, minTurn, maxTurn, now]
            )
        }
    }

    /// Returns the in-flight batch for `transcript`, or `nil` when none.
    /// - Parameter transcript: The transcript identity.
    func pendingBatch(forTranscript transcript: String) throws -> PendingBatch? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM pending_batches WHERE transcript = ?",
                arguments: [transcript]
            ).map(Self.pendingBatch(from:))
        }
    }

    /// Returns every in-flight batch, oldest first.
    func pendingBatches() throws -> [PendingBatch] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM pending_batches ORDER BY submitted_at ASC"
            ).map(Self.pendingBatch(from:))
        }
    }

    /// Deletes the pending-batch row for `batchID` once it's collected.
    /// - Parameter batchID: The Anthropic batch id.
    func deletePendingBatch(batchID: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM pending_batches WHERE batch_id = ?",
                arguments: [batchID]
            )
        }
    }

    private static func pendingBatch(from row: Row) -> PendingBatch {
        PendingBatch(
            batchID: row["batch_id"],
            transcript: row["transcript"],
            minTurn: row["min_turn"],
            maxTurn: row["max_turn"],
            submittedAt: Date(timeIntervalSince1970: row["submitted_at"])
        )
    }
}
