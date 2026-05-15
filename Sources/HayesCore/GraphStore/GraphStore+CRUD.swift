import Foundation
import GRDB

public extension GraphStore {
    /// Inserts a new node. Retries on primary-key collisions up to an internal budget.
    /// - Parameters:
    ///   - text: The node's text.
    ///   - embedding: The node's embedding vector.
    /// - Returns: The inserted ``Node``.
    func insertNode(text: String, embedding: [Float]) throws -> Node {
        let data = dataFromFloats(embedding)
        return try withIDRetry { id in
            try database.write { db in
                try db.execute(
                    sql: "INSERT INTO nodes (id, text, embedding) VALUES (?, ?, ?)",
                    arguments: [id, text, data]
                )
            }
            cacheEmbedding(id: id, embedding: embedding)
            return Node(id: id, text: text, embedding: embedding)
        }
    }

    /// Looks up a node by identifier.
    /// - Parameter id: The node identifier.
    /// - Returns: The matching ``Node`` or `nil`.
    func findNode(id: String) throws -> Node? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, text, embedding FROM nodes WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return GraphStore.makeNode(row: row)
        }
    }

    /// Returns all nodes currently in the graph.
    func allNodes() throws -> [Node] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, text, embedding FROM nodes")
                .map { GraphStore.makeNode(row: $0) }
        }
    }

    /// Inserts a new edge. Weight is clamped to `[-1.0, 1.0]`.
    /// - Parameters:
    ///   - sourceID: The source node identifier.
    ///   - targetID: The target node identifier.
    ///   - weight: The edge weight (will be clamped).
    ///   - provenance: Optional provenance metadata. When `nil`, the
    ///     three provenance columns are stored as NULL.
    /// - Returns: The inserted ``Edge``.
    func insertEdge(
        sourceID: String,
        targetID: String,
        weight: Double,
        provenance: EdgeProvenance? = nil
    ) throws -> Edge {
        let clamped = weight.clampedToUnit
        let now = Date()
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO edges
                    (source_id, target_id, weight, updated_at,
                     source_transcript, turn_index, source_excerpt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    sourceID,
                    targetID,
                    clamped,
                    now.timeIntervalSince1970,
                    provenance?.sourceTranscript,
                    provenance?.turnIndex,
                    provenance?.sourceExcerpt,
                ]
            )
        }
        return Edge(sourceID: sourceID, targetID: targetID, weight: clamped, updatedAt: now)
    }

    /// Updates the weight of an existing edge. Weight is clamped to `[-1.0, 1.0]`.
    /// - Parameters:
    ///   - sourceID: The source node identifier.
    ///   - targetID: The target node identifier.
    ///   - weight: The new weight (will be clamped).
    ///   - provenance: Optional new provenance. When `nil`, the row's
    ///     existing provenance columns are left untouched.
    func updateEdgeWeight(
        sourceID: String,
        targetID: String,
        weight: Double,
        provenance: EdgeProvenance? = nil
    ) throws {
        let clamped = weight.clampedToUnit
        let now = Date().timeIntervalSince1970
        try database.write { db in
            if let provenance {
                try db.execute(
                    sql: """
                    UPDATE edges
                    SET weight = ?, updated_at = ?,
                        source_transcript = ?, turn_index = ?, source_excerpt = ?
                    WHERE source_id = ? AND target_id = ?
                    """,
                    arguments: [
                        clamped,
                        now,
                        provenance.sourceTranscript,
                        provenance.turnIndex,
                        provenance.sourceExcerpt,
                        sourceID,
                        targetID,
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                    UPDATE edges SET weight = ?, updated_at = ? WHERE source_id = ? AND target_id = ?
                    """,
                    arguments: [clamped, now, sourceID, targetID]
                )
            }
            if db.changesCount == 0 {
                throw GraphStore.Error.edgeNotFound(sourceID: sourceID, targetID: targetID)
            }
        }
    }

    /// Returns outgoing edges for `sourceID`, ordered by descending weight.
    /// - Parameter sourceID: The source node identifier.
    func outgoingEdges(from sourceID: String) throws -> [Edge] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT \(GraphStore.edgeColumns) FROM edges
                WHERE source_id = ? ORDER BY weight DESC
                """,
                arguments: [sourceID]
            ).map { GraphStore.makeEdge(row: $0) }
        }
    }

    /// Returns the top `limit` edges in the graph by weight (descending).
    /// - Parameter limit: The maximum number of edges to return.
    func topEdgesByWeight(limit: Int) throws -> [Edge] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT \(GraphStore.edgeColumns) FROM edges
                ORDER BY weight DESC LIMIT ?
                """,
                arguments: [limit]
            ).map { GraphStore.makeEdge(row: $0) }
        }
    }

    /// Returns the most-recently-reinforced edges (descending by
    /// `updated_at`), capped at `limit`.
    /// - Parameter limit: The maximum number of edges to return.
    func topEdgesByRecency(limit: Int) throws -> [Edge] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT \(GraphStore.edgeColumns) FROM edges
                ORDER BY updated_at DESC LIMIT ?
                """,
                arguments: [limit]
            ).map { GraphStore.makeEdge(row: $0) }
        }
    }

    /// Deletes a single edge by source/target. Leaves the endpoint
    /// nodes intact so they remain available to retrieval and to other
    /// edges that may reference them.
    /// - Parameters:
    ///   - sourceID: The source node identifier.
    ///   - targetID: The target node identifier.
    /// - Throws: ``GraphStore/Error/edgeNotFound(sourceID:targetID:)`` when
    ///   no row matches `(sourceID, targetID)`.
    func deleteEdge(sourceID: String, targetID: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM edges WHERE source_id = ? AND target_id = ?",
                arguments: [sourceID, targetID]
            )
            if db.changesCount == 0 {
                throw GraphStore.Error.edgeNotFound(sourceID: sourceID, targetID: targetID)
            }
        }
    }

    /// Returns a single edge by source/target, if present.
    /// - Parameters:
    ///   - sourceID: The source node identifier.
    ///   - targetID: The target node identifier.
    func findEdge(sourceID: String, targetID: String) throws -> Edge? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(GraphStore.edgeColumns) FROM edges
                WHERE source_id = ? AND target_id = ?
                """,
                arguments: [sourceID, targetID]
            ) else { return nil }
            return GraphStore.makeEdge(row: row)
        }
    }
}

extension GraphStore {
    /// Fetches multiple nodes by ID in a single query.
    public func findNodes(ids: [String]) throws -> [Node] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let arguments: [any DatabaseValueConvertible] = ids
            return try Row.fetchAll(
                db,
                sql: "SELECT id, text, embedding FROM nodes WHERE id IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            ).map { GraphStore.makeNode(row: $0) }
        }
    }

    /// Fetches all outgoing edges whose `source_id` is in `sourceIDs`.
    func outgoingEdges(sourceIDs: [String]) throws -> [Edge] {
        guard !sourceIDs.isEmpty else { return [] }
        return try database.read { db in
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ",")
            let arguments: [any DatabaseValueConvertible] = sourceIDs
            return try Row.fetchAll(
                db,
                sql: """
                SELECT \(GraphStore.edgeColumns) FROM edges
                WHERE source_id IN (\(placeholders))
                """,
                arguments: StatementArguments(arguments)
            ).map { GraphStore.makeEdge(row: $0) }
        }
    }
}

extension GraphStore {
    static func makeNode(row: Row) -> Node {
        let data: Data = row["embedding"] ?? Data()
        return Node(
            id: row["id"],
            text: row["text"],
            embedding: floatsFromData(data)
        )
    }

    static func makeEdge(row: Row) -> Edge {
        let transcript: String? = row["source_transcript"]
        let turnIndex: Int? = row["turn_index"]
        let excerpt: String? = row["source_excerpt"]
        let provenance: EdgeProvenance? = if transcript != nil || turnIndex != nil || excerpt != nil {
            EdgeProvenance(
                sourceTranscript: transcript,
                turnIndex: turnIndex,
                sourceExcerpt: excerpt
            )
        } else {
            nil
        }
        return Edge(
            sourceID: row["source_id"],
            targetID: row["target_id"],
            weight: row["weight"],
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            provenance: provenance
        )
    }

    /// Comma-separated column list for `SELECT … FROM edges` queries.
    /// Centralised so adding a column (e.g. provenance) updates every
    /// read site at once.
    static let edgeColumns: String = """
    source_id, target_id, weight, updated_at,
    source_transcript, turn_index, source_excerpt
    """
}
