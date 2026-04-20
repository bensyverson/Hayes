import Foundation
@testable import HayesCore
import Testing

@Suite("GraphStore reinforcement")
struct GraphStoreReinforcementTests {
    private struct Fixture {
        let store: GraphStore
        let seedID: String
        let behaviorID: String
    }

    private func makeFixture(initialWeight: Double = 0.5) async throws -> Fixture {
        let store = try GraphStore.inMemory()
        let seed = try await store.insertNode(text: "seed", embedding: [0.0])
        let behavior = try await store.insertNode(text: "behavior", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: initialWeight)
        return Fixture(store: store, seedID: seed.id, behaviorID: behavior.id)
    }

    @Test("positive feedback pulls weight toward +1 by rate · (1 − w)")
    func positiveFeedback() async throws {
        // w=0.5, rate=0.10, sentiment=1.0, scale=1.0
        // w' = 0.5 + 0.10 · 1.0 · 1.0 · (1 − 0.5) = 0.55
        let f = try await makeFixture()
        try await f.store.reinforceEdge(
            seedID: f.seedID,
            behaviorID: f.behaviorID,
            sentiment: 1.0,
            sourceScale: 1.0
        )
        let edge = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        #expect(abs((edge?.weight ?? 0) - 0.55) < 1e-9)
    }

    @Test("positive feedback asymptotes toward 1.0 without overshoot")
    func positiveAsymptote() async throws {
        let f = try await makeFixture(initialWeight: 0.98)
        try await f.store.reinforceEdge(
            seedID: f.seedID,
            behaviorID: f.behaviorID,
            sentiment: 1.0,
            sourceScale: 1.0
        )
        let edge = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        // w' = 0.98 + 0.10 · (1 − 0.98) = 0.982
        let weight = edge?.weight ?? 0
        #expect(weight > 0.98)
        #expect(weight <= 1.0)
    }

    @Test("negative feedback pulls weight toward −1 across zero")
    func negativeFeedback() async throws {
        // w=0.5, sentiment=-1.0 → target=-1, α=0.10
        // w' = 0.5 + 0.10 · (−1 − 0.5) = 0.35
        let f = try await makeFixture()
        try await f.store.reinforceEdge(
            seedID: f.seedID,
            behaviorID: f.behaviorID,
            sentiment: -1.0,
            sourceScale: 1.0
        )
        let edge = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        #expect(abs((edge?.weight ?? 0) - 0.35) < 1e-9)
    }

    @Test("repeated negative feedback approaches −1, not 0")
    func negativeAsymptote() async throws {
        let f = try await makeFixture(initialWeight: 0.01)
        for _ in 0 ..< 200 {
            try await f.store.reinforceEdge(
                seedID: f.seedID,
                behaviorID: f.behaviorID,
                sentiment: -1.0,
                sourceScale: 1.0
            )
        }
        let edge = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        let weight = edge?.weight ?? 0
        #expect(weight < -0.99)
        #expect(weight >= -1.0)
    }

    @Test("sourceScale=0.3 produces 30% of sourceScale=1.0 delta")
    func sourceScaleContrast() async throws {
        let full = try await makeFixture()
        try await full.store.reinforceEdge(
            seedID: full.seedID,
            behaviorID: full.behaviorID,
            sentiment: 1.0,
            sourceScale: 1.0
        )
        let fullEdge = try await full.store.findEdge(sourceID: full.seedID, targetID: full.behaviorID)
        let fullDelta = (fullEdge?.weight ?? 0) - 0.5

        let partial = try await makeFixture()
        try await partial.store.reinforceEdge(
            seedID: partial.seedID,
            behaviorID: partial.behaviorID,
            sentiment: 1.0,
            sourceScale: 0.3
        )
        let partialEdge = try await partial.store.findEdge(sourceID: partial.seedID, targetID: partial.behaviorID)
        let partialDelta = (partialEdge?.weight ?? 0) - 0.5

        #expect(abs(partialDelta - fullDelta * 0.3) < 1e-9)
    }

    @Test("zero sentiment does not create an edge")
    func zeroSentimentSkipsEdgeInsert() async throws {
        let store = try GraphStore.inMemory()
        let seed = try await store.insertNode(text: "seed", embedding: [0.0])
        let behavior = try await store.insertNode(text: "behavior", embedding: [0.0])
        try await store.reinforceEdge(
            seedID: seed.id,
            behaviorID: behavior.id,
            sentiment: 0.0,
            sourceScale: 1.0
        )
        let edge = try await store.findEdge(sourceID: seed.id, targetID: behavior.id)
        #expect(edge == nil)
    }

    @Test("first-time positive feedback creates the edge at a positive weight")
    func firstPositiveCreatesEdge() async throws {
        let store = try GraphStore.inMemory()
        let seed = try await store.insertNode(text: "seed", embedding: [0.0])
        let behavior = try await store.insertNode(text: "behavior", embedding: [0.0])
        try await store.reinforceEdge(
            seedID: seed.id,
            behaviorID: behavior.id,
            sentiment: 1.0,
            sourceScale: 1.0
        )
        let edge = try await store.findEdge(sourceID: seed.id, targetID: behavior.id)
        // w' = 0 + 0.10 · (1 − 0) = 0.10
        #expect(abs((edge?.weight ?? 0) - 0.10) < 1e-9)
    }

    @Test("first-time negative feedback creates the edge at a negative weight")
    func firstNegativeCreatesEdge() async throws {
        let store = try GraphStore.inMemory()
        let seed = try await store.insertNode(text: "seed", embedding: [0.0])
        let behavior = try await store.insertNode(text: "behavior", embedding: [0.0])
        try await store.reinforceEdge(
            seedID: seed.id,
            behaviorID: behavior.id,
            sentiment: -1.0,
            sourceScale: 1.0
        )
        let edge = try await store.findEdge(sourceID: seed.id, targetID: behavior.id)
        // w' = 0 + 0.10 · (−1 − 0) = −0.10
        #expect(abs((edge?.weight ?? 0) - -0.10) < 1e-9)
    }

    /// In the feedback-driven model, edges can be reinforced repeatedly
    /// across turns. Each reinforcement applies the update; there is no
    /// "once per act" constraint — saying "I hate Arial" twice should
    /// compound the negative signal.
    @Test("repeated reinforcement on the same edge accumulates")
    func repeatedReinforcementAccumulates() async throws {
        let f = try await makeFixture()
        try await f.store.reinforceEdge(
            seedID: f.seedID,
            behaviorID: f.behaviorID,
            sentiment: 1.0,
            sourceScale: 1.0
        )
        let afterFirst = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        let firstWeight = afterFirst?.weight ?? 0

        try await f.store.reinforceEdge(
            seedID: f.seedID,
            behaviorID: f.behaviorID,
            sentiment: 1.0,
            sourceScale: 1.0
        )
        let afterSecond = try await f.store.findEdge(sourceID: f.seedID, targetID: f.behaviorID)
        let secondWeight = afterSecond?.weight ?? 0
        #expect(secondWeight > firstWeight, "second reinforcement should push the weight further toward 1.0")
    }
}
