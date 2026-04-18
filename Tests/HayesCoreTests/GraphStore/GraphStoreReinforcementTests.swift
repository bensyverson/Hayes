import Foundation
@testable import HayesCore
import Testing

@Suite("GraphStore reinforcement")
struct GraphStoreReinforcementTests {
    @Test("positive feedback adds posDelta · sentiment · sourceScale")
    func positiveFeedback() async throws {
        let store = try GraphStore.inMemory()
        let s = try await store.insertNode(text: "seed", embedding: [0.0])
        let b = try await store.insertNode(text: "behavior", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: s.id, targetID: b.id, weight: 0.5)
        let act = try await store.insertAct(seedIDs: [s.id], behaviorIDs: [b.id])

        try await store.applyFeedback(actID: act.id, sentiment: 1.0, sourceScale: 1.0)
        let edge = try await store.findEdge(sourceID: s.id, targetID: b.id)
        #expect(abs((edge?.weight ?? 0) - 0.55) < 1e-9)
    }

    @Test("positive feedback clamps at 1.0")
    func positiveClampsAtOne() async throws {
        let store = try GraphStore.inMemory()
        let s = try await store.insertNode(text: "seed", embedding: [0.0])
        let b = try await store.insertNode(text: "behavior", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: s.id, targetID: b.id, weight: 0.98)
        let act = try await store.insertAct(seedIDs: [s.id], behaviorIDs: [b.id])

        try await store.applyFeedback(actID: act.id, sentiment: 1.0, sourceScale: 1.0)
        let edge = try await store.findEdge(sourceID: s.id, targetID: b.id)
        #expect(edge?.weight == 1.0)
    }

    @Test("negative feedback decays by (1 - negDecay · |sentiment| · sourceScale)")
    func negativeFeedback() async throws {
        let store = try GraphStore.inMemory()
        let s = try await store.insertNode(text: "seed", embedding: [0.0])
        let b = try await store.insertNode(text: "behavior", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: s.id, targetID: b.id, weight: 0.5)
        let act = try await store.insertAct(seedIDs: [s.id], behaviorIDs: [b.id])

        try await store.applyFeedback(actID: act.id, sentiment: -1.0, sourceScale: 1.0)
        let edge = try await store.findEdge(sourceID: s.id, targetID: b.id)
        #expect(abs((edge?.weight ?? 0) - 0.45) < 1e-9)
    }

    @Test("negative feedback clamps at 0.0 after enough decay")
    func negativeClampsAtZero() async throws {
        let store = try GraphStore.inMemory()
        let s = try await store.insertNode(text: "seed", embedding: [0.0])
        let b = try await store.insertNode(text: "behavior", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: s.id, targetID: b.id, weight: 0.01)
        let act = try await store.insertAct(seedIDs: [s.id], behaviorIDs: [b.id])

        // run many rounds; insertAct can only be applied once per act — so use fresh acts
        for _ in 0 ..< 200 {
            let freshAct = try await store.insertAct(seedIDs: [s.id], behaviorIDs: [b.id])
            try await store.applyFeedback(actID: freshAct.id, sentiment: -1.0, sourceScale: 1.0)
        }
        _ = act
        let edge = try await store.findEdge(sourceID: s.id, targetID: b.id)
        #expect((edge?.weight ?? 1) < 0.0001)
    }

    @Test("sourceScale=0.3 produces 30% of sourceScale=1.0 positive delta")
    func sourceScaleContrast() async throws {
        let makeStore: () async throws -> (GraphStore, String, String, String) = {
            let store = try GraphStore.inMemory()
            let seed = try await store.insertNode(text: "seed", embedding: [0.0])
            let behavior = try await store.insertNode(text: "behavior", embedding: [0.0])
            _ = try await store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: 0.5)
            let act = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [behavior.id])
            return (store, seed.id, behavior.id, act.id)
        }

        let (fullStore, seedF, behaviorF, actF) = try await makeStore()
        try await fullStore.applyFeedback(actID: actF, sentiment: 1.0, sourceScale: 1.0)
        let fullEdge = try await fullStore.findEdge(sourceID: seedF, targetID: behaviorF)
        let fullDelta = (fullEdge?.weight ?? 0) - 0.5

        let (partialStore, seedP, behaviorP, actP) = try await makeStore()
        try await partialStore.applyFeedback(actID: actP, sentiment: 1.0, sourceScale: 0.3)
        let partialEdge = try await partialStore.findEdge(sourceID: seedP, targetID: behaviorP)
        let partialDelta = (partialEdge?.weight ?? 0) - 0.5

        #expect(abs(partialDelta - fullDelta * 0.3) < 1e-9)
    }

    @Test("positive sentiment flips act status to accepted; negative flips to revised")
    func statusTransitions() async throws {
        let store = try GraphStore.inMemory()
        let s = try await store.insertNode(text: "seed", embedding: [0.0])
        let b = try await store.insertNode(text: "behavior", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: s.id, targetID: b.id, weight: 0.5)

        let actA = try await store.insertAct(seedIDs: [s.id], behaviorIDs: [b.id])
        try await store.applyFeedback(actID: actA.id, sentiment: 0.5, sourceScale: 1.0)
        let reloadA = try await store.findAct(id: actA.id)
        #expect(reloadA?.status == .accepted)

        let actB = try await store.insertAct(seedIDs: [s.id], behaviorIDs: [b.id])
        try await store.applyFeedback(actID: actB.id, sentiment: -0.3, sourceScale: 1.0)
        let reloadB = try await store.findAct(id: actB.id)
        #expect(reloadB?.status == .revised)

        let actC = try await store.insertAct(seedIDs: [s.id], behaviorIDs: [b.id])
        try await store.applyFeedback(actID: actC.id, sentiment: 0.0, sourceScale: 1.0)
        let reloadC = try await store.findAct(id: actC.id)
        #expect(reloadC?.status == .revised)
    }

    @Test("non-pending acts are ignored by applyFeedback (once-feedback-wins)")
    func onceFeedbackWins() async throws {
        let store = try GraphStore.inMemory()
        let s = try await store.insertNode(text: "seed", embedding: [0.0])
        let b = try await store.insertNode(text: "behavior", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: s.id, targetID: b.id, weight: 0.5)
        let act = try await store.insertAct(seedIDs: [s.id], behaviorIDs: [b.id])

        try await store.applyFeedback(actID: act.id, sentiment: 1.0, sourceScale: 1.0)
        let afterFirst = try await store.findEdge(sourceID: s.id, targetID: b.id)
        let firstWeight = afterFirst?.weight ?? 0

        // Second call should be a no-op because the act is no longer .pending.
        try await store.applyFeedback(actID: act.id, sentiment: 1.0, sourceScale: 1.0)
        let afterSecond = try await store.findEdge(sourceID: s.id, targetID: b.id)
        #expect(afterSecond?.weight == firstWeight)
    }
}
