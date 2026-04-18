@testable import HayesCore
import Testing

@Suite("NLEmbeddingProvider")
struct NLEmbeddingProviderTests {
    let provider: NLEmbeddingProvider

    init() throws {
        provider = try NLEmbeddingProvider()
    }

    @Test("dimension is consistent across calls")
    func dimensionConsistent() throws {
        let a = try provider.embed("yoga studio")
        let b = try provider.embed("wellness brand")
        #expect(a.count == provider.dimension)
        #expect(b.count == provider.dimension)
        #expect(a.count == b.count)
    }

    @Test("embedding the same phrase twice is deterministic")
    func deterministic() throws {
        let a = try provider.embed("yoga studio")
        let b = try provider.embed("yoga studio")
        #expect(a == b)
    }

    @Test("semantically related phrases score higher than unrelated ones")
    func semanticOrdering() throws {
        let yoga = try provider.embed("yoga studio")
        let wellness = try provider.embed("wellness brand")
        let diesel = try provider.embed("diesel engine repair")
        let related = cosineSimilarity(yoga, wellness)
        let unrelated = cosineSimilarity(yoga, diesel)
        #expect(related > unrelated)
    }
}
