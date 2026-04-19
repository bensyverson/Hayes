import Foundation
@testable import HayesCore
import Testing

@Suite("LoggingLLMClient")
struct LoggingLLMClientTests {
    private static func tempURL() -> URL {
        let name = "hayes-logging-\(UUID().uuidString).log"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private static func readLines(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @Test("successful calls are appended as JSONL with the stage label")
    func successIsAppended() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let inner = MockLLM(responses: ["response-one", "response-two"])
        let writer = LoggingLLMClient.LogWriter(url: url)
        let extractor = LoggingLLMClient(wrapping: inner, stage: "extractor", writer: writer)
        let analyzer = LoggingLLMClient(wrapping: inner, stage: "analyzer", writer: writer)

        _ = try await extractor.complete(systemPrompt: "sys-1", userMessage: "user-1")
        _ = try await analyzer.complete(systemPrompt: "sys-2", userMessage: "user-2")

        let lines = try Self.readLines(url)
        #expect(lines.count == 2)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(LoggingLLMClient.LogEntry.self, from: Data(lines[0].utf8))
        let second = try decoder.decode(LoggingLLMClient.LogEntry.self, from: Data(lines[1].utf8))

        #expect(first.stage == "extractor")
        #expect(first.systemPrompt == "sys-1")
        #expect(first.userMessage == "user-1")
        #expect(first.response == "response-one")
        #expect(first.error == nil)

        #expect(second.stage == "analyzer")
        #expect(second.response == "response-two")
    }

    @Test("thrown errors are logged with the error field and rethrown")
    func errorIsLoggedAndRethrown() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let inner = MockLLM(results: [.failure(MockLLM.ScriptedError())])
        let writer = LoggingLLMClient.LogWriter(url: url)
        let client = LoggingLLMClient(wrapping: inner, stage: "extractor", writer: writer)

        await #expect(throws: MockLLM.ScriptedError.self) {
            _ = try await client.complete(systemPrompt: "sys", userMessage: "user")
        }

        let lines = try Self.readLines(url)
        #expect(lines.count == 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(LoggingLLMClient.LogEntry.self, from: Data(lines[0].utf8))
        #expect(entry.response == nil)
        #expect(entry.error != nil)
    }
}
