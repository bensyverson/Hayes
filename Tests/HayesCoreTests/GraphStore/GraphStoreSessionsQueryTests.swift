import Foundation
@testable import HayesCore
import Testing

@Suite("GraphStore session reads + reset")
struct GraphStoreSessionsQueryTests {
    @Test("listSessions returns all known sessions, most-recent last_seen_at first")
    func listSessions() async throws {
        let store = try await GraphStore.inMemory()
        let seed = try await store.insertNode(text: "seed", embedding: [0.1])
        let behavior = try await store.insertNode(text: "behavior", embedding: [0.1])
        _ = try await store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: 0.5)

        try await store.recordInjection(
            sessionID: "older",
            sourceID: seed.id,
            targetID: behavior.id,
            matchedText: "x"
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        try await store.recordInjection(
            sessionID: "newer",
            sourceID: seed.id,
            targetID: behavior.id,
            matchedText: "y"
        )

        let sessions = try await store.listSessions()
        #expect(sessions.map(\.sessionID) == ["newer", "older"])
        let newerCount = sessions.first { $0.sessionID == "newer" }?.injectionCount
        #expect(newerCount == 1)
    }

    @Test("injectionsInSession returns all rows for that session in injected_at order")
    func injectionsInSession() async throws {
        let store = try await GraphStore.inMemory()
        let s1 = try await store.insertNode(text: "s1", embedding: [0.1])
        let b1 = try await store.insertNode(text: "b1", embedding: [0.1])
        let b2 = try await store.insertNode(text: "b2", embedding: [0.1])
        _ = try await store.insertEdge(sourceID: s1.id, targetID: b1.id, weight: 0.5)
        _ = try await store.insertEdge(sourceID: s1.id, targetID: b2.id, weight: 0.5)

        try await store.recordInjection(
            sessionID: "S",
            sourceID: s1.id,
            targetID: b1.id,
            matchedText: "first match"
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        try await store.recordInjection(
            sessionID: "S",
            sourceID: s1.id,
            targetID: b2.id,
            matchedText: "second match"
        )

        let rows = try await store.injectionsInSession("S")
        #expect(rows.count == 2)
        #expect(rows[0].sourceID == s1.id)
        #expect(rows[0].targetID == b1.id)
        #expect(rows[0].matchedText == "first match")
        #expect(rows[1].targetID == b2.id)
    }

    @Test("resetSession clears injection rows but leaves the session row")
    func resetSession() async throws {
        let store = try await GraphStore.inMemory()
        let seed = try await store.insertNode(text: "seed", embedding: [0.1])
        let behavior = try await store.insertNode(text: "behavior", embedding: [0.1])
        _ = try await store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: 0.5)
        try await store.recordInjection(
            sessionID: "S",
            sourceID: seed.id,
            targetID: behavior.id,
            matchedText: "x"
        )

        try await store.resetSession("S")

        let injected = try await store.injectedEdges(in: "S")
        #expect(injected.isEmpty)
        let sessions = try await store.listSessions()
        #expect(sessions.contains { $0.sessionID == "S" })
    }
}
