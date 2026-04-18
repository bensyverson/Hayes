@testable import HayesCore
import Testing

@Suite("cosineSimilarity")
struct CosineSimilarityTests {
    private let tolerance: Float = 1e-6

    @Test("identical unit vectors return 1.0")
    func identical() {
        let v: [Float] = [1, 0]
        let sim = cosineSimilarity(v, v)
        #expect(abs(sim - 1.0) < tolerance)
    }

    @Test("orthogonal vectors return 0.0")
    func orthogonal() {
        let sim = cosineSimilarity([1, 0], [0, 1])
        #expect(abs(sim - 0.0) < tolerance)
    }

    @Test("parallel non-unit vectors return 1.0")
    func parallel() {
        let sim = cosineSimilarity([1, 1], [2, 2])
        #expect(abs(sim - 1.0) < tolerance)
    }

    @Test("opposite direction vectors return -1.0")
    func opposite() {
        let sim = cosineSimilarity([1, 0], [-1, 0])
        #expect(abs(sim - -1.0) < tolerance)
    }

    @Test("cosineSimilarity(v, v) is 1.0 for arbitrary non-zero v")
    func selfSimilarity() {
        let v: [Float] = [0.3, -0.7, 0.1, 2.5, -1.2]
        let sim = cosineSimilarity(v, v)
        #expect(abs(sim - 1.0) < tolerance)
    }

    @Test("45-degree angle returns sqrt(2)/2")
    func fortyFiveDegrees() {
        let sim = cosineSimilarity([1, 0], [1, 1])
        let expected: Float = 0.707_106_77
        #expect(abs(sim - expected) < 1e-6)
    }
}
