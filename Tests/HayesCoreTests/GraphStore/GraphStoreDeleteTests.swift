import Foundation
@testable import HayesCore
import Testing

@Suite("GraphStore.deleteEdge")
struct GraphStoreDeleteEdgeTests {
    @Test("deleteEdge removes the row and a follow-up findEdge returns nil")
    func deleteRemovesRow() async throws {
        let store = try await GraphStore.inMemory()
        let seed = try await store.insertNode(text: "seed", embedding: [0.1])
        let behavior = try await store.insertNode(text: "behavior", embedding: [0.1])
        _ = try await store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: 0.5)

        try await store.deleteEdge(sourceID: seed.id, targetID: behavior.id)
        let after = try await store.findEdge(sourceID: seed.id, targetID: behavior.id)
        #expect(after == nil)
    }

    @Test("deleteEdge on a missing edge throws edgeNotFound")
    func deleteMissingThrows() async throws {
        let store = try await GraphStore.inMemory()
        await #expect(throws: GraphStore.Error.edgeNotFound(sourceID: "x", targetID: "y")) {
            try await store.deleteEdge(sourceID: "x", targetID: "y")
        }
    }
}

@Suite("GraphStore.topEdgesByRecency")
struct GraphStoreTopEdgesByRecencyTests {
    @Test("returns edges sorted by descending updated_at, capped by limit")
    func sortedByRecency() async throws {
        let store = try await GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.1])
        let b = try await store.insertNode(text: "b", embedding: [0.1])
        let c = try await store.insertNode(text: "c", embedding: [0.1])

        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.4)
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await store.insertEdge(sourceID: a.id, targetID: c.id, weight: 0.2)
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await store.insertEdge(sourceID: b.id, targetID: c.id, weight: 0.9)

        let recent = try await store.topEdgesByRecency(limit: 2)
        #expect(recent.count == 2)
        #expect(recent[0].sourceID == b.id)
        #expect(recent[0].targetID == c.id)
        #expect(recent[1].sourceID == a.id)
        #expect(recent[1].targetID == c.id)
    }
}

@Suite("Edge provenance round-trip")
struct EdgeProvenanceRoundTripTests {
    @Test("findEdge returns provenance fields populated when written")
    func findEdgeWithProvenance() async throws {
        let store = try await GraphStore.inMemory()
        let seed = try await store.insertNode(text: "seed", embedding: [0.1])
        let behavior = try await store.insertNode(text: "behavior", embedding: [0.1])

        _ = try await store.insertEdge(
            sourceID: seed.id,
            targetID: behavior.id,
            weight: 0.5,
            provenance: EdgeProvenance(
                sourceTranscript: "session-abc",
                turnIndex: 3,
                sourceExcerpt: "design the landing page"
            )
        )

        let edge = try await store.findEdge(sourceID: seed.id, targetID: behavior.id)
        #expect(edge?.provenance?.sourceTranscript == "session-abc")
        #expect(edge?.provenance?.turnIndex == 3)
        #expect(edge?.provenance?.sourceExcerpt == "design the landing page")
    }

    @Test("findEdge returns nil provenance when none was written")
    func findEdgeWithoutProvenance() async throws {
        let store = try await GraphStore.inMemory()
        let seed = try await store.insertNode(text: "seed", embedding: [0.1])
        let behavior = try await store.insertNode(text: "behavior", embedding: [0.1])

        _ = try await store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: 0.5)
        let edge = try await store.findEdge(sourceID: seed.id, targetID: behavior.id)
        #expect(edge?.provenance == nil)
    }
}
