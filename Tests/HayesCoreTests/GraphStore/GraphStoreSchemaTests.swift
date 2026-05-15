import Foundation
import GRDB
@testable import HayesCore
import Testing

@Suite("GraphStore schema")
struct GraphStoreSchemaTests {
    @Test("inMemory() succeeds and yields an empty graph")
    func inMemorySucceeds() async throws {
        let store = try GraphStore.inMemory()
        let nodes = try await store.allNodes()
        #expect(nodes.isEmpty)
    }

    @Test("schema survives close/reopen for a file-backed store")
    func fileReopen() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hayes-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = try GraphStore(path: url)
            _ = try await store.insertNode(text: "hello", embedding: [0.1, 0.2])
        }

        let reopened = try GraphStore(path: url)
        let nodes = try await reopened.allNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.text == "hello")
    }
}

@Suite("GraphStore schema v2 — provenance and sessions")
struct GraphStoreSchemaV2Tests {
    @Test("edges table carries provenance columns (nullable)")
    func edgesProvenanceColumns() async throws {
        let store = try GraphStore.inMemory()
        let columns = try await store.database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(edges)")
        }
        let byName = Dictionary(uniqueKeysWithValues: columns.map { row in
            (row["name"] as String, row)
        })

        let transcript = try #require(byName["source_transcript"])
        #expect(transcript["type"] as String == "TEXT")
        #expect(transcript["notnull"] as Int == 0)

        let turn = try #require(byName["turn_index"])
        #expect(turn["type"] as String == "INTEGER")
        #expect(turn["notnull"] as Int == 0)

        let excerpt = try #require(byName["source_excerpt"])
        #expect(excerpt["type"] as String == "TEXT")
        #expect(excerpt["notnull"] as Int == 0)
    }

    @Test("provenance round-trips through raw insert and select")
    func provenanceRoundTrip() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])

        try await store.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO edges
                    (source_id, target_id, weight, updated_at,
                     source_transcript, turn_index, source_excerpt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [a.id, b.id, 0.5, 0.0, "session-abc", 7, "user said: hi"]
            )
        }

        let row = try await store.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT source_transcript, turn_index, source_excerpt
                FROM edges WHERE source_id = ? AND target_id = ?
                """,
                arguments: [a.id, b.id]
            )
        }
        let unwrapped = try #require(row)
        #expect(unwrapped["source_transcript"] as String == "session-abc")
        #expect(unwrapped["turn_index"] as Int == 7)
        #expect(unwrapped["source_excerpt"] as String == "user said: hi")
    }

    @Test("provenance columns accept NULL")
    func provenanceNullable() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.3)

        let row = try await store.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT source_transcript, turn_index, source_excerpt
                FROM edges WHERE source_id = ? AND target_id = ?
                """,
                arguments: [a.id, b.id]
            )
        }
        let unwrapped = try #require(row)
        #expect((unwrapped["source_transcript"] as String?) == nil)
        #expect((unwrapped["turn_index"] as Int?) == nil)
        #expect((unwrapped["source_excerpt"] as String?) == nil)
    }

    @Test("sessions table has the expected columns and PK")
    func sessionsTableShape() async throws {
        let store = try GraphStore.inMemory()
        let columns = try await store.database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(sessions)")
        }
        let byName = Dictionary(uniqueKeysWithValues: columns.map { row in
            (row["name"] as String, row)
        })

        let sessionID = try #require(byName["session_id"])
        #expect(sessionID["type"] as String == "TEXT")
        #expect(sessionID["notnull"] as Int == 1)
        #expect(sessionID["pk"] as Int == 1)

        let created = try #require(byName["created_at"])
        #expect(created["type"] as String == "REAL")
        #expect(created["notnull"] as Int == 1)

        let lastSeen = try #require(byName["last_seen_at"])
        #expect(lastSeen["type"] as String == "REAL")
        #expect(lastSeen["notnull"] as Int == 1)
    }

    @Test("session_injections table has the expected columns and composite PK")
    func injectionsTableShape() async throws {
        let store = try GraphStore.inMemory()
        let columns = try await store.database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(session_injections)")
        }
        let byName = Dictionary(uniqueKeysWithValues: columns.map { row in
            (row["name"] as String, row)
        })

        let session = try #require(byName["session_id"])
        #expect(session["type"] as String == "TEXT")
        #expect(session["notnull"] as Int == 1)
        #expect(session["pk"] as Int > 0)

        let source = try #require(byName["source_id"])
        #expect(source["type"] as String == "TEXT")
        #expect(source["notnull"] as Int == 1)
        #expect(source["pk"] as Int > 0)

        let target = try #require(byName["target_id"])
        #expect(target["type"] as String == "TEXT")
        #expect(target["notnull"] as Int == 1)
        #expect(target["pk"] as Int > 0)

        let injectedAt = try #require(byName["injected_at"])
        #expect(injectedAt["type"] as String == "REAL")
        #expect(injectedAt["notnull"] as Int == 1)

        let matched = try #require(byName["matched_text"])
        #expect(matched["type"] as String == "TEXT")
        #expect(matched["notnull"] as Int == 0)
    }

    @Test("session_injections declares ON DELETE CASCADE foreign keys")
    func injectionsForeignKeys() async throws {
        let store = try GraphStore.inMemory()
        let fks = try await store.database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(session_injections)")
        }

        let toSessions = fks.filter { ($0["table"] as String) == "sessions" }
        #expect(toSessions.count == 1)
        #expect(toSessions.first?["on_delete"] as String? == "CASCADE")

        let toEdges = fks.filter { ($0["table"] as String) == "edges" }
        #expect(toEdges.count == 2) // composite FK: one row per column
        for row in toEdges {
            #expect(row["on_delete"] as String? == "CASCADE")
        }
    }

    @Test("foreign_keys pragma is enabled on every connection")
    func foreignKeysEnabled() async throws {
        let store = try GraphStore.inMemory()
        let enabled = try await store.database.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0
        }
        #expect(enabled == 1)
    }

    @Test("deleting a session cascades to its injection rows")
    func cascadeFromSession() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.5)

        try await store.database.write { db in
            try db.execute(
                sql: "INSERT INTO sessions (session_id, created_at, last_seen_at) VALUES (?, ?, ?)",
                arguments: ["sess-1", 0.0, 0.0]
            )
            try db.execute(
                sql: """
                INSERT INTO session_injections
                    (session_id, source_id, target_id, injected_at, matched_text)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["sess-1", a.id, b.id, 0.0, "hi"]
            )
        }

        try await store.database.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE session_id = ?", arguments: ["sess-1"])
        }

        let remaining = try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_injections") ?? -1
        }
        #expect(remaining == 0)
    }

    @Test("deleting an edge cascades to its injection rows")
    func cascadeFromEdge() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.5)

        try await store.database.write { db in
            try db.execute(
                sql: "INSERT INTO sessions (session_id, created_at, last_seen_at) VALUES (?, ?, ?)",
                arguments: ["sess-2", 0.0, 0.0]
            )
            try db.execute(
                sql: """
                INSERT INTO session_injections
                    (session_id, source_id, target_id, injected_at, matched_text)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["sess-2", a.id, b.id, 0.0, nil]
            )
        }

        try await store.database.write { db in
            try db.execute(
                sql: "DELETE FROM edges WHERE source_id = ? AND target_id = ?",
                arguments: [a.id, b.id]
            )
        }

        let remaining = try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_injections") ?? -1
        }
        #expect(remaining == 0)
    }

    @Test("inserting an injection without a matching session is rejected")
    func injectionRequiresSession() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.5)

        await #expect(throws: (any Error).self) {
            try await store.database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO session_injections
                        (session_id, source_id, target_id, injected_at, matched_text)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: ["no-such-session", a.id, b.id, 0.0, nil]
                )
            }
        }
    }
}
