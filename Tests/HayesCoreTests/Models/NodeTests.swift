import Foundation
@testable import HayesCore
import Testing

@Suite("Node")
struct NodeTests {
    @Test("Codable round-trip preserves fields")
    func codableRoundTrip() throws {
        let node = Node(id: "abc123", text: "yoga studio", embedding: [0.1, 0.2, 0.3])
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(Node.self, from: data)
        #expect(decoded == node)
    }

    @Test("Equatable reflects field equality")
    func equality() {
        let a = Node(id: "abc123", text: "yoga studio", embedding: [0.1, 0.2])
        let b = Node(id: "abc123", text: "yoga studio", embedding: [0.1, 0.2])
        let c = Node(id: "abc123", text: "different", embedding: [0.1, 0.2])
        #expect(a == b)
        #expect(a != c)
    }
}
