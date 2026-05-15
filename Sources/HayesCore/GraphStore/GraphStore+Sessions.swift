import Foundation
import GRDB

public extension GraphStore {
    /// Upserts a `sessions` row for `sessionID`.
    ///
    /// On insert both `created_at` and `last_seen_at` are set to "now."
    /// On update only `last_seen_at` advances — the original `created_at`
    /// is preserved so session-list orderings stay stable.
    /// - Parameter sessionID: The session identifier.
    func touchSession(_ sessionID: String) throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (session_id, created_at, last_seen_at)
                VALUES (?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET last_seen_at = excluded.last_seen_at
                """,
                arguments: [sessionID, now, now]
            )
        }
    }

    /// Records that the edge `(sourceID → targetID)` was injected during
    /// `sessionID`.
    ///
    /// Auto-creates the session row if missing. Uses `INSERT OR IGNORE`
    /// against the `(session_id, source_id, target_id)` primary key, so
    /// repeated calls with the same triple are no-ops — the first write
    /// wins.
    /// - Parameters:
    ///   - sessionID: The session identifier.
    ///   - sourceID: The seed node identifier.
    ///   - targetID: The behavior node identifier.
    ///   - matchedText: The user-prompt excerpt that triggered this
    ///     injection. Pass `nil` to omit.
    func recordInjection(
        sessionID: String,
        sourceID: String,
        targetID: String,
        matchedText: String?
    ) throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (session_id, created_at, last_seen_at)
                VALUES (?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET last_seen_at = excluded.last_seen_at
                """,
                arguments: [sessionID, now, now]
            )
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO session_injections
                    (session_id, source_id, target_id, injected_at, matched_text)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [sessionID, sourceID, targetID, now, matchedText]
            )
        }
    }

    /// Returns the set of edges already injected in `sessionID`.
    /// - Parameter sessionID: The session identifier.
    func injectedEdges(in sessionID: String) throws -> Set<EdgeKey> {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT source_id, target_id FROM session_injections
                WHERE session_id = ?
                """,
                arguments: [sessionID]
            )
            return Set(rows.map { EdgeKey(sourceID: $0["source_id"], targetID: $0["target_id"]) })
        }
    }
}
