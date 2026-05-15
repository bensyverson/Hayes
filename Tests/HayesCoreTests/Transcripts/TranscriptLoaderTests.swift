import Foundation
@testable import HayesCore
import Operator
import Testing

@Suite("TranscriptLoader")
struct TranscriptLoaderTests {
    @Test("explicit claudeCode format dispatches to the JSONL parser")
    func explicitClaudeCode() async throws {
        let url = try writeFixture(name: "explicit-cc.jsonl", contents: ccJSONL)
        defer { try? FileManager.default.removeItem(at: url) }

        let messages = try await TranscriptLoader().load(path: url, format: .claudeCode)
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].textContent == "hello")
        #expect(messages[1].role == .assistant)
        #expect(messages[1].textContent == "hi")
    }

    @Test("auto-detects Claude Code from a .jsonl extension")
    func autoDetectsFromExtension() async throws {
        let url = try writeFixture(name: "auto-by-ext.jsonl", contents: ccJSONL)
        defer { try? FileManager.default.removeItem(at: url) }

        let messages = try await TranscriptLoader().load(path: url, format: .auto)
        #expect(messages.count == 2)
    }

    @Test("auto-detects Claude Code by probing first record when extension is ambiguous")
    func autoDetectsByProbe() async throws {
        let url = try writeFixture(name: "auto-by-probe.txt", contents: ccJSONL)
        defer { try? FileManager.default.removeItem(at: url) }

        let messages = try await TranscriptLoader().load(path: url, format: .auto)
        #expect(messages.count == 2)
    }

    @Test("auto-detection fails with a clear error when no signal matches")
    func autoDetectionFailure() async throws {
        let url = try writeFixture(name: "garbage.txt", contents: "not json at all\n")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: TranscriptLoader.LoadError.self) {
            _ = try await TranscriptLoader().load(path: url, format: .auto)
        }
    }

    @Test("openaiResponses returns a not-implemented error")
    func openaiResponsesNotImplemented() async throws {
        let url = try writeFixture(name: "any.json", contents: "{}\n")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await TranscriptLoader().load(path: url, format: .openaiResponses)
            Issue.record("expected .formatNotImplemented to throw")
        } catch let error as TranscriptLoader.LoadError {
            guard case .formatNotImplemented(.openaiResponses) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        }
    }

    @Test("missing file surfaces a file-not-found error")
    func missingFile() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).jsonl")
        await #expect(throws: TranscriptLoader.LoadError.self) {
            _ = try await TranscriptLoader().load(path: url, format: .auto)
        }
    }

    // MARK: - Helpers

    private var ccJSONL: String {
        #"""
        {"type":"user","message":{"role":"user","content":"hello"},"sessionId":"s1","uuid":"u1"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]},"sessionId":"s1","uuid":"a1"}
        """#
    }

    private func writeFixture(name: String, contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hayes-loader-\(UUID().uuidString)-\(name)")
        try contents.data(using: .utf8)?.write(to: url)
        return url
    }
}
