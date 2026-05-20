import Foundation
import GRDB
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

    @Test("explicit opencode format with a session id dispatches to the OpenCode parser")
    func explicitOpenCode() async throws {
        let db = try writeOpenCodeSession(sessionID: "s1", text: "hello")
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }

        let messages = try await TranscriptLoader().load(path: db, format: .opencode, sessionID: "s1")
        #expect(messages.count == 1)
        #expect(messages[0].role == .user)
        #expect(messages[0].textContent == "hello")
    }

    @Test("auto-detects OpenCode from an opencode.db path")
    func autoDetectsOpenCode() async throws {
        let db = try writeOpenCodeSession(sessionID: "s1", text: "hello")
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }

        let messages = try await TranscriptLoader().load(path: db, format: .auto, sessionID: "s1")
        #expect(messages.count == 1)
        #expect(messages[0].textContent == "hello")
    }

    @Test("opencode without a session id throws sessionIDRequired")
    func opencodeRequiresSessionID() async throws {
        let db = try writeOpenCodeSession(sessionID: "s1", text: "hello")
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }

        do {
            _ = try await TranscriptLoader().load(path: db, format: .opencode, sessionID: nil)
            Issue.record("expected .sessionIDRequired to throw")
        } catch let error as TranscriptLoader.LoadError {
            guard case .sessionIDRequired(.opencode) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
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

    /// Builds a minimal single-message OpenCode `opencode.db` inside a fresh
    /// temp directory and returns the database file URL (named `opencode.db`
    /// so auto-detection can recognize it).
    private func writeOpenCodeSession(sessionID: String, text: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hayes-loader-oc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("opencode.db")
        let queue = try DatabaseQueue(path: db.path)
        try queue.write { database in
            try database.execute(sql: """
            CREATE TABLE message (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
            )
            """)
            try database.execute(sql: """
            CREATE TABLE part (
              id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
            )
            """)
            try database.execute(
                sql: "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, 1, 1, ?)",
                arguments: ["msg_1", sessionID, #"{"role":"user"}"#]
            )
            try database.execute(
                sql: "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, 1, 1, ?)",
                arguments: ["prt_1", "msg_1", sessionID, #"{"type":"text","text":"\#(text)"}"#]
            )
        }
        return db
    }
}
