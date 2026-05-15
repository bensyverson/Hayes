import Foundation
import GRDB
@testable import HayesCore
import Testing

@Suite("GraphStore sessions and injections")
struct GraphStoreSessionsTests {
    @Test("touchSession inserts a new row with matching created_at and last_seen_at")
    func touchSessionInserts() async throws {
        let store = try GraphStore.inMemory()
        try await store.touchSession("sess-1")

        let row = try await store.database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT created_at, last_seen_at FROM sessions WHERE session_id = ?",
                arguments: ["sess-1"]
            )
        }
        let unwrapped = try #require(row)
        let created: Double = unwrapped["created_at"]
        let lastSeen: Double = unwrapped["last_seen_at"]
        #expect(created > 0)
        #expect(abs(lastSeen - created) < 0.01)
    }

    @Test("touchSession on an existing session bumps last_seen_at and leaves created_at fixed")
    func touchSessionUpdates() async throws {
        let store = try GraphStore.inMemory()
        try await store.touchSession("sess-1")

        let originalCreated: Double = try await store.database.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT created_at FROM sessions WHERE session_id = ?",
                arguments: ["sess-1"]
            ) ?? -1
        }

        try await Task.sleep(nanoseconds: 20_000_000) // ~20 ms
        try await store.touchSession("sess-1")

        let row = try await store.database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT created_at, last_seen_at FROM sessions WHERE session_id = ?",
                arguments: ["sess-1"]
            )
        }
        let unwrapped = try #require(row)
        let created: Double = unwrapped["created_at"]
        let lastSeen: Double = unwrapped["last_seen_at"]
        #expect(created == originalCreated)
        #expect(lastSeen > created)
    }

    @Test("recordInjection persists a row with the given matched_text")
    func recordInjectionPersists() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.5)

        try await store.touchSession("sess-1")
        try await store.recordInjection(
            sessionID: "sess-1",
            sourceID: a.id,
            targetID: b.id,
            matchedText: "show me yoga sites"
        )

        let row = try await store.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT matched_text FROM session_injections
                WHERE session_id = ? AND source_id = ? AND target_id = ?
                """,
                arguments: ["sess-1", a.id, b.id]
            )
        }
        let unwrapped = try #require(row)
        #expect(unwrapped["matched_text"] as String? == "show me yoga sites")
    }

    @Test("recordInjection is idempotent: calling twice with the same key is a no-op")
    func recordInjectionIdempotent() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.5)
        try await store.touchSession("sess-1")

        try await store.recordInjection(
            sessionID: "sess-1", sourceID: a.id, targetID: b.id, matchedText: "first"
        )
        try await store.recordInjection(
            sessionID: "sess-1", sourceID: a.id, targetID: b.id, matchedText: "second"
        )

        let count = try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_injections") ?? -1
        }
        #expect(count == 1)
        let matched = try await store.database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT matched_text FROM session_injections LIMIT 1"
            )
        }
        // First write wins — second call must not overwrite matched_text.
        #expect(matched == "first")
    }

    @Test("recordInjection auto-creates the session row if missing")
    func recordInjectionAutoCreatesSession() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.5)

        try await store.recordInjection(
            sessionID: "sess-new",
            sourceID: a.id,
            targetID: b.id,
            matchedText: nil
        )

        let sessionCount = try await store.database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions WHERE session_id = ?",
                arguments: ["sess-new"]
            ) ?? -1
        }
        #expect(sessionCount == 1)
    }

    @Test("injectedEdges returns the (source, target) pairs already recorded for a session")
    func injectedEdgesReturnsRecorded() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        let c = try await store.insertNode(text: "c", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.5)
        _ = try await store.insertEdge(sourceID: a.id, targetID: c.id, weight: 0.6)

        try await store.recordInjection(
            sessionID: "sess-1", sourceID: a.id, targetID: b.id, matchedText: nil
        )
        try await store.recordInjection(
            sessionID: "sess-1", sourceID: a.id, targetID: c.id, matchedText: nil
        )

        let edges = try await store.injectedEdges(in: "sess-1")
        #expect(edges.count == 2)
        #expect(edges.contains(EdgeKey(sourceID: a.id, targetID: b.id)))
        #expect(edges.contains(EdgeKey(sourceID: a.id, targetID: c.id)))
    }

    @Test("injectedEdges is scoped per session")
    func injectedEdgesScopedPerSession() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.5)

        try await store.recordInjection(
            sessionID: "sess-A", sourceID: a.id, targetID: b.id, matchedText: nil
        )

        #expect(try await store.injectedEdges(in: "sess-A").count == 1)
        #expect(try await store.injectedEdges(in: "sess-B").isEmpty)
    }
}
