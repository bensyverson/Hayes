import Foundation
@testable import HayesCore
import Testing

@Suite("RetrievalConfig")
struct RetrievalConfigTests {
    @Test("default values match the decisions log")
    func defaults() {
        let config = RetrievalConfig.default
        #expect(config.seedThreshold == 0.6)
        #expect(config.dedupThreshold == 0.85)
        #expect(config.topSeeds == 5)
        #expect(config.topBehaviors == 5)
        #expect(config.minEdgeWeight == 0.1)
        #expect(config.posDelta == 0.05)
        #expect(config.negDecay == 0.10)
        #expect(config.userFeedbackScale == 1.0)
        #expect(config.selfAssessmentScale == 0.3)
        #expect(config.recentActsWindow == 50)
    }

    @Test("Codable round-trip preserves fields")
    func codableRoundTrip() throws {
        let config = RetrievalConfig.default
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(RetrievalConfig.self, from: data)
        #expect(decoded == config)
    }
}
