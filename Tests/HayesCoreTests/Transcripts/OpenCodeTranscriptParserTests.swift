import Foundation
import GRDB
@testable import HayesCore
import Operator
import Testing

@Suite("OpenCodeTranscriptParser")
struct OpenCodeTranscriptParserTests {
    @Test("a missing database file is reported as unreadable")
    func missingDatabase() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hayes-oc-missing-\(UUID().uuidString).db")
        #expect(throws: OpenCodeTranscriptParser.ParseError.self) {
            _ = try OpenCodeTranscriptParser().parse(databasePath: url, sessionID: "s1")
        }
    }

    @Test("an unknown session yields no messages")
    func unknownSession() throws {
        let db = try makeDatabase(messages: [], parts: [])
        defer { cleanup(db) }
        let messages = try OpenCodeTranscriptParser().parse(databasePath: db, sessionID: "nope")
        #expect(messages.isEmpty)
    }

    @Test("user text part becomes one user message")
    func userText() throws {
        let db = try makeDatabase(
            messages: [Msg(id: "msg_001", session: "s1", created: 1, role: "user")],
            parts: [Prt(id: "prt_001", message: "msg_001", session: "s1", created: 1,
                        data: #"{"type":"text","text":"hello there"}"#)]
        )
        defer { cleanup(db) }
        let messages = try OpenCodeTranscriptParser().parse(databasePath: db, sessionID: "s1")
        #expect(messages.count == 1)
        #expect(messages.first?.role == .user)
        #expect(messages.first?.textContent == "hello there")
    }

    @Test("assistant text-only part becomes one assistant message")
    func assistantText() throws {
        let db = try makeDatabase(
            messages: [Msg(id: "msg_001", session: "s1", created: 1, role: "assistant")],
            parts: [Prt(id: "prt_001", message: "msg_001", session: "s1", created: 1,
                        data: #"{"type":"text","text":"sure"}"#)]
        )
        defer { cleanup(db) }
        let messages = try OpenCodeTranscriptParser().parse(databasePath: db, sessionID: "s1")
        #expect(messages.count == 1)
        #expect(messages.first?.role == .assistant)
        #expect(messages.first?.textContent == "sure")
        #expect(messages.first?.toolCalls == nil)
    }

    @Test("multiple text parts join in time/id order")
    func multipleTextParts() throws {
        let db = try makeDatabase(
            messages: [Msg(id: "msg_001", session: "s1", created: 1, role: "user")],
            parts: [
                Prt(id: "prt_002", message: "msg_001", session: "s1", created: 2,
                    data: #"{"type":"text","text":"two"}"#),
                Prt(id: "prt_001", message: "msg_001", session: "s1", created: 1,
                    data: #"{"type":"text","text":"one "}"#),
            ]
        )
        defer { cleanup(db) }
        let messages = try OpenCodeTranscriptParser().parse(databasePath: db, sessionID: "s1")
        #expect(messages.count == 1)
        #expect(messages.first?.textContent == "one two")
    }

    @Test("assistant tool part lifts into toolCalls and emits a following .tool message")
    func assistantToolPart() throws {
        let db = try makeDatabase(
            messages: [Msg(id: "msg_002", session: "s1", created: 2, role: "assistant")],
            parts: [
                Prt(id: "prt_010", message: "msg_002", session: "s1", created: 1,
                    data: #"{"type":"text","text":"running"}"#),
                Prt(id: "prt_011", message: "msg_002", session: "s1", created: 2,
                    data: #"{"type":"tool","callID":"call_xyz","tool":"bash","state":{"status":"completed","input":{"command":"ls","flag":"-a"},"output":"file1\nfile2"}}"#),
            ]
        )
        defer { cleanup(db) }
        let messages = try OpenCodeTranscriptParser().parse(databasePath: db, sessionID: "s1")
        #expect(messages.count == 2)

        let assistant = try #require(messages.first)
        #expect(assistant.role == .assistant)
        #expect(assistant.textContent == "running")
        let calls = try #require(assistant.toolCalls)
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_xyz")
        #expect(calls[0].name == "bash")
        let args = try #require(decodedJSON(calls[0].arguments) as? [String: Any])
        #expect(args["command"] as? String == "ls")
        #expect(args["flag"] as? String == "-a")

        let tool = messages[1]
        #expect(tool.role == .tool)
        #expect(tool.toolCallId == "call_xyz")
        #expect(tool.textContent == "file1\nfile2")
    }

    @Test("a tool part with no completed output emits no .tool message")
    func toolPartWithoutOutput() throws {
        let db = try makeDatabase(
            messages: [Msg(id: "msg_002", session: "s1", created: 2, role: "assistant")],
            parts: [Prt(id: "prt_011", message: "msg_002", session: "s1", created: 1,
                        data: #"{"type":"tool","callID":"call_pending","tool":"bash","state":{"status":"pending","input":{"command":"ls"}}}"#)]
        )
        defer { cleanup(db) }
        let messages = try OpenCodeTranscriptParser().parse(databasePath: db, sessionID: "s1")
        #expect(messages.count == 1)
        #expect(messages.first?.role == .assistant)
        #expect(messages.first?.toolCalls?.first?.id == "call_pending")
    }

    @Test("non-text, non-tool parts are dropped silently")
    func otherPartsDropped() throws {
        let db = try makeDatabase(
            messages: [Msg(id: "msg_001", session: "s1", created: 1, role: "assistant")],
            parts: [
                Prt(id: "prt_001", message: "msg_001", session: "s1", created: 1,
                    data: #"{"type":"reasoning","text":"hmm"}"#),
                Prt(id: "prt_002", message: "msg_001", session: "s1", created: 2,
                    data: #"{"type":"step-finish"}"#),
                Prt(id: "prt_003", message: "msg_001", session: "s1", created: 3,
                    data: #"{"type":"text","text":"answer"}"#),
            ]
        )
        defer { cleanup(db) }
        let messages = try OpenCodeTranscriptParser().parse(databasePath: db, sessionID: "s1")
        #expect(messages.count == 1)
        #expect(messages.first?.textContent == "answer")
    }

    @Test("messages are ordered by time_created")
    func conversationOrder() throws {
        let db = try makeDatabase(
            messages: [
                Msg(id: "msg_b", session: "s1", created: 2, role: "assistant"),
                Msg(id: "msg_a", session: "s1", created: 1, role: "user"),
                Msg(id: "msg_c", session: "s1", created: 3, role: "user"),
            ],
            parts: [
                Prt(id: "prt_1", message: "msg_a", session: "s1", created: 1, data: #"{"type":"text","text":"first"}"#),
                Prt(id: "prt_2", message: "msg_b", session: "s1", created: 2, data: #"{"type":"text","text":"second"}"#),
                Prt(id: "prt_3", message: "msg_c", session: "s1", created: 3, data: #"{"type":"text","text":"third"}"#),
            ]
        )
        defer { cleanup(db) }
        let messages = try OpenCodeTranscriptParser().parse(databasePath: db, sessionID: "s1")
        #expect(messages.count == 3)
        #expect(messages[0].textContent == "first")
        #expect(messages[0].role == .user)
        #expect(messages[1].textContent == "second")
        #expect(messages[1].role == .assistant)
        #expect(messages[2].textContent == "third")
        #expect(messages[2].role == .user)
    }

    @Test("only the requested session is loaded")
    func sessionIsolation() throws {
        let db = try makeDatabase(
            messages: [
                Msg(id: "msg_1", session: "s1", created: 1, role: "user"),
                Msg(id: "msg_9", session: "s2", created: 1, role: "user"),
            ],
            parts: [
                Prt(id: "prt_1", message: "msg_1", session: "s1", created: 1, data: #"{"type":"text","text":"mine"}"#),
                Prt(id: "prt_9", message: "msg_9", session: "s2", created: 1, data: #"{"type":"text","text":"other"}"#),
            ]
        )
        defer { cleanup(db) }
        let messages = try OpenCodeTranscriptParser().parse(databasePath: db, sessionID: "s1")
        #expect(messages.count == 1)
        #expect(messages.first?.textContent == "mine")
    }

    // MARK: - Fixtures

    private struct Msg {
        let id: String
        let session: String
        let created: Int
        let role: String
    }

    private struct Prt {
        let id: String
        let message: String
        let session: String
        let created: Int
        let data: String
    }

    /// Builds a temporary SQLite database with OpenCode's `message` and
    /// `part` schema and the given rows.
    private func makeDatabase(messages: [Msg], parts: [Prt]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hayes-oc-\(UUID().uuidString).db")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE message (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE part (
              id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
            )
            """)
            for message in messages {
                try db.execute(
                    sql: "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
                    arguments: [message.id, message.session, message.created, message.created, #"{"role":"\#(message.role)"}"#]
                )
            }
            for part in parts {
                try db.execute(
                    sql: "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [part.id, part.message, part.session, part.created, part.created, part.data]
                )
            }
        }
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func decodedJSON(_ s: String) -> Any? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
