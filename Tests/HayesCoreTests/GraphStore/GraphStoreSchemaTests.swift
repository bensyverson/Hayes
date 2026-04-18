import Foundation
@testable import HayesCore
import Testing

@Suite("GraphStore schema")
struct GraphStoreSchemaTests {
    @Test("inMemory() succeeds and yields an empty graph")
    func inMemorySucceeds() async throws {
        let store = try GraphStore.inMemory()
        let nodes = try await store.allNodes()
        #expect(nodes.isEmpty)
    }

    @Test("schema survives close/reopen for a file-backed store")
    func fileReopen() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hayes-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = try GraphStore(path: url)
            _ = try await store.insertNode(text: "hello", embedding: [0.1, 0.2])
        }

        let reopened = try GraphStore(path: url)
        let nodes = try await reopened.allNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.text == "hello")
    }
}
