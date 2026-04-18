import Foundation
@testable import HayesCore
import Testing

@Suite("GraphStore CRUD")
struct GraphStoreCRUDTests {
    @Test("insertNode round-trip")
    func insertAndFindNode() async throws {
        let store = try GraphStore.inMemory()
        let node = try await store.insertNode(text: "yoga studio", embedding: [0.1, 0.2, 0.3])
        let found = try await store.findNode(id: node.id)
        #expect(found == node)
    }

    @Test("allNodes() returns inserted nodes")
    func allNodes() async throws {
        let store = try GraphStore.inMemory()
        _ = try await store.insertNode(text: "one", embedding: [1.0])
        _ = try await store.insertNode(text: "two", embedding: [2.0])
        let nodes = try await store.allNodes()
        #expect(nodes.count == 2)
        #expect(Set(nodes.map(\.text)) == ["one", "two"])
    }

    @Test("insertEdge round-trip and clamping")
    func insertEdgeClamps() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])

        let normal = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.3)
        #expect(normal.weight == 0.3)

        let over = try await store.insertEdge(sourceID: b.id, targetID: a.id, weight: 1.7)
        #expect(over.weight == 1.0)

        let c = try await store.insertNode(text: "c", embedding: [0.0])
        let under = try await store.insertEdge(sourceID: a.id, targetID: c.id, weight: -0.5)
        #expect(under.weight == 0.0)
    }

    @Test("updateEdgeWeight clamps and persists")
    func updateEdgeWeight() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.3)

        try await store.updateEdgeWeight(sourceID: a.id, targetID: b.id, weight: 1.5)
        let edges = try await store.outgoingEdges(from: a.id)
        #expect(edges.first?.weight == 1.0)

        try await store.updateEdgeWeight(sourceID: a.id, targetID: b.id, weight: -0.2)
        let clamped = try await store.outgoingEdges(from: a.id)
        #expect(clamped.first?.weight == 0.0)
    }

    @Test("outgoingEdges filters by source")
    func outgoingEdgesFilter() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        let c = try await store.insertNode(text: "c", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.5)
        _ = try await store.insertEdge(sourceID: a.id, targetID: c.id, weight: 0.6)
        _ = try await store.insertEdge(sourceID: b.id, targetID: c.id, weight: 0.7)

        let out = try await store.outgoingEdges(from: a.id)
        #expect(out.count == 2)
        #expect(Set(out.map(\.targetID)) == [b.id, c.id])
    }

    @Test("topEdgesByWeight returns descending order")
    func topEdgesDescending() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        let c = try await store.insertNode(text: "c", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.3)
        _ = try await store.insertEdge(sourceID: a.id, targetID: c.id, weight: 0.9)
        _ = try await store.insertEdge(sourceID: b.id, targetID: c.id, weight: 0.6)

        let top = try await store.topEdgesByWeight(limit: 2)
        #expect(top.count == 2)
        #expect(top[0].weight == 0.9)
        #expect(top[1].weight == 0.6)
    }

    @Test("insertAct round-trip and default status")
    func actRoundTrip() async throws {
        let store = try GraphStore.inMemory()
        let act = try await store.insertAct(seedIDs: ["s1", "s2"], behaviorIDs: ["b1"])
        #expect(act.status == .pending)
        #expect(act.seedIDs == ["s1", "s2"])
        #expect(act.behaviorIDs == ["b1"])

        let recent = try await store.recentActs(limit: 10)
        #expect(recent.count == 1)
        #expect(recent.first == act)
    }

    @Test("recentActs filters by status set")
    func recentActsFilter() async throws {
        let store = try GraphStore.inMemory()
        let pending = try await store.insertAct(seedIDs: ["s"], behaviorIDs: ["b"])
        let accepted = try await store.insertAct(seedIDs: ["s"], behaviorIDs: ["b"])
        try await store.setActStatus(id: accepted.id, status: .accepted)

        let onlyPending = try await store.recentActs(limit: 10)
        #expect(onlyPending.count == 1)
        #expect(onlyPending.first?.id == pending.id)

        let all = try await store.recentActs(limit: 10, statuses: [.pending, .accepted])
        #expect(all.count == 2)
    }

    @Test("setActStatus persists")
    func statusRoundTrip() async throws {
        let store = try GraphStore.inMemory()
        let act = try await store.insertAct(seedIDs: ["s"], behaviorIDs: ["b"])
        try await store.setActStatus(id: act.id, status: .accepted)
        let reloaded = try await store.recentActs(limit: 10, statuses: [.accepted])
        #expect(reloaded.first?.status == .accepted)
    }

    @Test("insertNode retries on ID collision")
    func collisionRetry() async throws {
        final class Counter: @unchecked Sendable {
            var calls = 0
        }
        let counter = Counter()
        let generator: @Sendable () -> String = {
            counter.calls += 1
            if counter.calls == 1 { return "fixed1" }
            if counter.calls == 2 { return "fixed1" } // collision with existing node
            return "fixed2"
        }
        let store = try GraphStore.inMemory(idGenerator: generator)
        let first = try await store.insertNode(text: "a", embedding: [0.0])
        #expect(first.id == "fixed1")
        let second = try await store.insertNode(text: "b", embedding: [0.0])
        #expect(second.id == "fixed2")
        #expect(counter.calls == 3)
    }
}
