import Foundation
@testable import HayesCore
import Testing

@Suite("Edge")
struct EdgeTests {
    @Test("Codable round-trip preserves fields")
    func codableRoundTrip() throws {
        let edge = Edge(
            sourceID: "src001",
            targetID: "tgt001",
            weight: 0.42,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(Edge.self, from: data)
        #expect(decoded == edge)
    }
}
