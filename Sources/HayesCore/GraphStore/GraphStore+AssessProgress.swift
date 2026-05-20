import Foundation
import GRDB

public extension GraphStore {
    /// Returns the highest turn index already assessed for `identity`,
    /// or `nil` when the transcript has never been assessed.
    ///
    /// `AssessService` uses this to skip turns it has already processed,
    /// so reinforcement happens once per turn instead of once per
    /// assess run. One-shot assess records progress too, but only at
    /// transcript granularity (assessed-or-not).
    /// - Parameter identity: The transcript identity.
    func assessProgress(for identity: String) throws -> Int? {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT max_turn_index FROM assess_progress WHERE identity = ?",
                arguments: [identity]
            )
        }
    }

    /// Advances the stored max-assessed turn index for `identity` to
    /// `maxTurnIndex`, never moving it backward.
    ///
    /// Upserts an `assess_progress` row, taking the larger of the
    /// existing and supplied indices so out-of-order or repeated calls
    /// can't lower progress. `updated_at` always advances to "now."
    /// - Parameters:
    ///   - identity: The transcript identity.
    ///   - maxTurnIndex: The highest turn index now assessed.
    func advanceAssessProgress(identity: String, to maxTurnIndex: Int) throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO assess_progress (identity, max_turn_index, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(identity) DO UPDATE SET
                    max_turn_index = MAX(max_turn_index, excluded.max_turn_index),
                    updated_at = excluded.updated_at
                """,
                arguments: [identity, maxTurnIndex, now]
            )
        }
    }
}
