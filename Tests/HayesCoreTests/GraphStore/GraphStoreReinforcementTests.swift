import Foundation
@testable import HayesCore
import Testing

@Suite("GraphStore reinforcement")
struct GraphStoreReinforcementTests {
    private struct Fixture {
        let store: GraphStore
        let seedID: String
        let behaviorID: String
        let actID: String
    }

    private func makeFixture(initialWeight: Double = 0.5) async throws -> Fixture {
        let store = try GraphStore.inMemory()
        let seed = try await store.insertNode(text: "seed", embedding: [0.0])
        let behavior = try await store.insertNode(text: "behavior", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: initialWeight)
        let act = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [behavior.id])
        return Fixture(store: store, seedID: seed.id, behaviorID: behavior.id, actID: act.id)
    }

    @Test("positive feedback adds posDelta · sentiment · sourceScale")
    func positiveFeedback() async throws {
        let f = try await makeFixture()
        try await f.store.applyFeedback(actID: f.actID, sentiment: 1.0, sourceScale: 1.0)
        let edge = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        #expect(abs((edge?.weight ?? 0) - 0.55) < 1e-9)
    }

    @Test("positive feedback clamps at 1.0")
    func positiveClampsAtOne() async throws {
        let f = try await makeFixture(initialWeight: 0.98)
        try await f.store.applyFeedback(actID: f.actID, sentiment: 1.0, sourceScale: 1.0)
        let edge = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        #expect(edge?.weight == 1.0)
    }

    @Test("negative feedback decays by (1 - negDecay · |sentiment| · sourceScale)")
    func negativeFeedback() async throws {
        let f = try await makeFixture()
        try await f.store.applyFeedback(actID: f.actID, sentiment: -1.0, sourceScale: 1.0)
        let edge = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        #expect(abs((edge?.weight ?? 0) - 0.45) < 1e-9)
    }

    @Test("negative feedback clamps at 0.0 after enough decay")
    func negativeClampsAtZero() async throws {
        let f = try await makeFixture(initialWeight: 0.01)
        for _ in 0 ..< 200 {
            let freshAct = try await f.store.insertAct(seedIDs: [f.seedID], behaviorIDs: [f.behaviorID])
            try await f.store.applyFeedback(actID: freshAct.id, sentiment: -1.0, sourceScale: 1.0)
        }
        let edge = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        #expect((edge?.weight ?? 1) < 0.0001)
    }

    @Test("sourceScale=0.3 produces 30% of sourceScale=1.0 positive delta")
    func sourceScaleContrast() async throws {
        let full = try await makeFixture()
        try await full.store.applyFeedback(actID: full.actID, sentiment: 1.0, sourceScale: 1.0)
        let fullEdge = try await full.store.findEdge(sourceID: full.seedID, targetID: full.behaviorID)
        let fullDelta = (fullEdge?.weight ?? 0) - 0.5

        let partial = try await makeFixture()
        try await partial.store.applyFeedback(actID: partial.actID, sentiment: 1.0, sourceScale: 0.3)
        let partialEdge = try await partial.store.findEdge(sourceID: partial.seedID, targetID: partial.behaviorID)
        let partialDelta = (partialEdge?.weight ?? 0) - 0.5

        #expect(abs(partialDelta - fullDelta * 0.3) < 1e-9)
    }

    @Test("positive sentiment flips act status to accepted; negative flips to revised")
    func statusTransitions() async throws {
        let f = try await makeFixture()
        try await f.store.applyFeedback(actID: f.actID, sentiment: 0.5, sourceScale: 1.0)
        let reloadA = try await f.store.findAct(id: f.actID)
        #expect(reloadA?.status == .accepted)

        let actB = try await f.store.insertAct(seedIDs: [f.seedID], behaviorIDs: [f.behaviorID])
        try await f.store.applyFeedback(actID: actB.id, sentiment: -0.3, sourceScale: 1.0)
        let reloadB = try await f.store.findAct(id: actB.id)
        #expect(reloadB?.status == .revised)

        let actC = try await f.store.insertAct(seedIDs: [f.seedID], behaviorIDs: [f.behaviorID])
        try await f.store.applyFeedback(actID: actC.id, sentiment: 0.0, sourceScale: 1.0)
        let reloadC = try await f.store.findAct(id: actC.id)
        #expect(reloadC?.status == .revised)
    }

    @Test("non-pending acts are ignored by applyFeedback (once-feedback-wins)")
    func onceFeedbackWins() async throws {
        let f = try await makeFixture()
        try await f.store.applyFeedback(actID: f.actID, sentiment: 1.0, sourceScale: 1.0)
        let afterFirst = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        let firstWeight = afterFirst?.weight ?? 0

        try await f.store.applyFeedback(actID: f.actID, sentiment: 1.0, sourceScale: 1.0)
        let afterSecond = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        #expect(afterSecond?.weight == firstWeight)
    }
}
