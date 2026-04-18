import Foundation
@testable import HayesCore
import Testing

@Suite("GraphStore retrieval")
struct GraphStoreRetrievalTests {
    let provider: NLEmbeddingProvider

    init() throws {
        provider = try NLEmbeddingProvider()
    }

    @Test("empty seeds yield an empty result")
    func noSeedsAboveThreshold() async throws {
        let store = try GraphStore.inMemory()
        let query = try provider.embed("yoga studio")
        let result = try await store.retrieve(contextEmbeddings: [query])
        #expect(result.seeds.isEmpty)
        #expect(result.behaviors.isEmpty)
    }

    @Test("retrieves related seeds and summed behaviors above threshold")
    func retrievesSeedsAndBehaviors() async throws {
        let store = try GraphStore.inMemory()

        let yoga = try await store.insertNode(
            text: "yoga studio",
            embedding: provider.embed("yoga studio")
        )
        _ = try await store.insertNode(
            text: "diesel engine",
            embedding: provider.embed("diesel engine")
        )
        let warm = try await store.insertNode(
            text: "warm palette",
            embedding: provider.embed("warm palette")
        )
        let centered = try await store.insertNode(
            text: "centered narrow layout",
            embedding: provider.embed("centered narrow layout")
        )
        _ = try await store.insertEdge(sourceID: yoga.id, targetID: warm.id, weight: 0.6)
        _ = try await store.insertEdge(sourceID: yoga.id, targetID: centered.id, weight: 0.4)

        let query = try provider.embed("yoga")
        var config = RetrievalConfig.default
        config.seedThreshold = 0.3
        let result = try await store.retrieve(contextEmbeddings: [query], config: config)
        #expect(result.seeds.contains { $0.value.id == yoga.id })
        let behaviorIDs = Set(result.behaviors.map(\.value.id))
        #expect(behaviorIDs.contains(warm.id))
        #expect(behaviorIDs.contains(centered.id))

        // warm has a higher incoming weight than centered
        guard result.behaviors.count >= 2 else {
            Issue.record("expected at least 2 behaviors")
            return
        }
        let warmScore = result.behaviors.first(where: { $0.value.id == warm.id })?.score ?? 0
        let centeredScore = result.behaviors.first(where: { $0.value.id == centered.id })?.score ?? 0
        #expect(warmScore > centeredScore)
    }

    @Test("minEdgeWeight filters weak edges")
    func minEdgeWeightFilter() async throws {
        let store = try GraphStore.inMemory()
        let yoga = try await store.insertNode(
            text: "yoga studio",
            embedding: provider.embed("yoga studio")
        )
        let weakTarget = try await store.insertNode(
            text: "weak target",
            embedding: provider.embed("weak target")
        )
        let strongTarget = try await store.insertNode(
            text: "strong target",
            embedding: provider.embed("strong target")
        )
        _ = try await store.insertEdge(sourceID: yoga.id, targetID: weakTarget.id, weight: 0.05)
        _ = try await store.insertEdge(sourceID: yoga.id, targetID: strongTarget.id, weight: 0.8)

        var config = RetrievalConfig.default
        config.seedThreshold = 0.3
        let result = try await store.retrieve(
            contextEmbeddings: [provider.embed("yoga studio")],
            config: config
        )
        let ids = Set(result.behaviors.map(\.value.id))
        #expect(ids.contains(strongTarget.id))
        #expect(!ids.contains(weakTarget.id))
    }

    @Test("topBehaviors cap is honored")
    func topBehaviorsCap() async throws {
        let store = try GraphStore.inMemory()
        let seed = try await store.insertNode(
            text: "yoga studio",
            embedding: provider.embed("yoga studio")
        )
        for i in 0 ..< 10 {
            let target = try await store.insertNode(
                text: "target-\(i)",
                embedding: provider.embed("target-\(i)")
            )
            _ = try await store.insertEdge(
                sourceID: seed.id,
                targetID: target.id,
                weight: Double(i) / 10.0 + 0.1
            )
        }
        var config = RetrievalConfig.default
        config.topBehaviors = 3
        config.seedThreshold = 0.3
        let result = try await store.retrieve(
            contextEmbeddings: [provider.embed("yoga studio")],
            config: config
        )
        #expect(result.behaviors.count == 3)
    }

    @Test("topSeeds cap is honored")
    func topSeedsCap() async throws {
        let store = try GraphStore.inMemory()
        // Insert many similar nodes
        for i in 0 ..< 10 {
            _ = try await store.insertNode(
                text: "yoga studio \(i)",
                embedding: provider.embed("yoga studio \(i)")
            )
        }
        var config = RetrievalConfig.default
        config.topSeeds = 3
        config.seedThreshold = 0.1
        let result = try await store.retrieve(
            contextEmbeddings: [provider.embed("yoga studio")],
            config: config
        )
        #expect(result.seeds.count <= 3)
    }
}
