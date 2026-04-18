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
        for _ in 0 ..< 5 {
            let id = nextID()
            do {
                try database.write { db in
                    try db.execute(
                        sql: "INSERT INTO nodes (id, text, embedding) VALUES (?, ?, ?)",
                        arguments: [id, text, data]
                    )
                }
                let node = Node(id: id, text: text, embedding: embedding)
                cacheEmbedding(id: id, embedding: embedding)
                return node
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                continue
            }
        }
        throw GraphStore.Error.idCollisionExhausted
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

    /// Inserts a new edge. Weight is clamped to `[0.0, 1.0]`.
    /// - Parameters:
    ///   - sourceID: The source node identifier.
    ///   - targetID: The target node identifier.
    ///   - weight: The edge weight (will be clamped).
    /// - Returns: The inserted ``Edge``.
    func insertEdge(sourceID: String, targetID: String, weight: Double) throws -> Edge {
        let clamped = max(0.0, min(1.0, weight))
        let now = Date()
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO edges (source_id, target_id, weight, updated_at) VALUES (?, ?, ?, ?)
                """,
                arguments: [sourceID, targetID, clamped, now.timeIntervalSince1970]
            )
        }
        return Edge(sourceID: sourceID, targetID: targetID, weight: clamped, updatedAt: now)
    }

    /// Updates the weight of an existing edge. Weight is clamped to `[0.0, 1.0]`.
    /// - Parameters:
    ///   - sourceID: The source node identifier.
    ///   - targetID: The target node identifier.
    ///   - weight: The new weight (will be clamped).
    func updateEdgeWeight(sourceID: String, targetID: String, weight: Double) throws {
        let clamped = max(0.0, min(1.0, weight))
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(
                sql: """
                UPDATE edges SET weight = ?, updated_at = ? WHERE source_id = ? AND target_id = ?
                """,
                arguments: [clamped, now, sourceID, targetID]
            )
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
                SELECT source_id, target_id, weight, updated_at FROM edges
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
                SELECT source_id, target_id, weight, updated_at FROM edges
                ORDER BY weight DESC LIMIT ?
                """,
                arguments: [limit]
            ).map { GraphStore.makeEdge(row: $0) }
        }
    }

    /// Inserts a new ``Act``. Status defaults to ``ActStatus/pending``.
    /// - Parameters:
    ///   - seedIDs: The seed node identifiers.
    ///   - behaviorIDs: The behavior node identifiers.
    /// - Returns: The inserted ``Act``.
    func insertAct(seedIDs: [String], behaviorIDs: [String]) throws -> Act {
        let storedInterval = Date().timeIntervalSince1970
        let createdAt = Date(timeIntervalSince1970: storedInterval)
        let seedJSON = try String(data: JSONEncoder().encode(seedIDs), encoding: .utf8) ?? "[]"
        let behaviorJSON = try String(data: JSONEncoder().encode(behaviorIDs), encoding: .utf8) ?? "[]"
        for _ in 0 ..< 5 {
            let id = nextID()
            do {
                try database.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO acts (id, created_at, seed_ids, behavior_ids, status)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            id,
                            storedInterval,
                            seedJSON,
                            behaviorJSON,
                            ActStatus.pending.rawValue,
                        ]
                    )
                }
                return Act(
                    id: id,
                    createdAt: createdAt,
                    seedIDs: seedIDs,
                    behaviorIDs: behaviorIDs,
                    status: .pending
                )
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                continue
            }
        }
        throw GraphStore.Error.idCollisionExhausted
    }

    /// Returns the most recent acts matching the given status set.
    /// - Parameters:
    ///   - limit: The maximum number of acts to return.
    ///   - statuses: The statuses to include (defaults to ``ActStatus/pending``).
    func recentActs(
        limit: Int,
        statuses: Set<ActStatus> = [.pending]
    ) throws -> [Act] {
        try database.read { db in
            let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ",")
            let sql = """
            SELECT id, created_at, seed_ids, behavior_ids, status FROM acts
            WHERE status IN (\(placeholders))
            ORDER BY created_at DESC
            LIMIT ?
            """
            var arguments: [any DatabaseValueConvertible] = statuses.map(\.rawValue)
            arguments.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .compactMap { GraphStore.makeAct(row: $0) }
        }
    }

    /// Returns a single act by identifier.
    /// - Parameter id: The act identifier.
    func findAct(id: String) throws -> Act? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, created_at, seed_ids, behavior_ids, status FROM acts WHERE id = ?
                """,
                arguments: [id]
            ) else { return nil }
            return GraphStore.makeAct(row: row)
        }
    }

    /// Updates an act's lifecycle status.
    /// - Parameters:
    ///   - id: The act identifier.
    ///   - status: The new status.
    func setActStatus(id: String, status: ActStatus) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE acts SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
            if db.changesCount == 0 {
                throw GraphStore.Error.actNotFound(id: id)
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
                SELECT source_id, target_id, weight, updated_at FROM edges
                WHERE source_id = ? AND target_id = ?
                """,
                arguments: [sourceID, targetID]
            ) else { return nil }
            return GraphStore.makeEdge(row: row)
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
        Edge(
            sourceID: row["source_id"],
            targetID: row["target_id"],
            weight: row["weight"],
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    static func makeAct(row: Row) -> Act? {
        let seedJSON: String = row["seed_ids"]
        let behaviorJSON: String = row["behavior_ids"]
        guard
            let seedData = seedJSON.data(using: .utf8),
            let behaviorData = behaviorJSON.data(using: .utf8),
            let seedIDs = try? JSONDecoder().decode([String].self, from: seedData),
            let behaviorIDs = try? JSONDecoder().decode([String].self, from: behaviorData),
            let status = ActStatus(rawValue: row["status"])
        else { return nil }
        return Act(
            id: row["id"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            seedIDs: seedIDs,
            behaviorIDs: behaviorIDs,
            status: status
        )
    }
}
