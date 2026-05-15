import Foundation
@testable import HayesCore
import Operator
import Testing

@Suite("ClaudeCodeTranscriptParser")
struct ClaudeCodeTranscriptParserTests {
    @Test("empty file yields no messages")
    func emptyFile() throws {
        let messages = try parse(jsonl: "")
        #expect(messages.isEmpty)
    }

    @Test("non-conversation records are skipped")
    func nonConversationRecordsSkipped() throws {
        let jsonl = """
        {"type":"permission-mode","permissionMode":"auto","sessionId":"s1"}
        {"type":"file-history-snapshot","messageId":"m1","snapshot":{}}
        {"type":"summary","summary":"x"}
        """
        let messages = try parse(jsonl: jsonl)
        #expect(messages.isEmpty)
    }

    @Test("user record with string content emits one user message")
    func userStringContent() throws {
        let jsonl = #"""
        {"type":"user","message":{"role":"user","content":"hello there"},"sessionId":"s1","uuid":"u1"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 1)
        #expect(messages.first?.role == .user)
        #expect(messages.first?.textContent == "hello there")
    }

    @Test("user record with text block array emits one user message")
    func userTextBlockArray() throws {
        let jsonl = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"uuid":"u1"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 1)
        #expect(messages.first?.role == .user)
        #expect(messages.first?.textContent == "hi")
    }

    @Test("user record with multiple text blocks joins their text")
    func userMultipleTextBlocks() throws {
        let jsonl = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"one "},{"type":"text","text":"two"}]},"uuid":"u1"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 1)
        #expect(messages.first?.textContent == "one two")
    }

    @Test("assistant text-only record emits one assistant message")
    func assistantTextOnly() throws {
        let jsonl = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"sure"}]},"uuid":"a1"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 1)
        #expect(messages.first?.role == .assistant)
        #expect(messages.first?.textContent == "sure")
        #expect(messages.first?.toolCalls == nil)
    }

    @Test("assistant tool_use blocks become ToolCallInfo entries")
    func assistantWithToolUse() throws {
        let jsonl = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"running"},{"type":"tool_use","id":"toolu_abc","name":"Bash","input":{"command":"ls","description":"List"}}]},"uuid":"a1"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 1)
        let msg = try #require(messages.first)
        #expect(msg.role == .assistant)
        #expect(msg.textContent == "running")
        let calls = try #require(msg.toolCalls)
        #expect(calls.count == 1)
        #expect(calls[0].id == "toolu_abc")
        #expect(calls[0].name == "Bash")
        let args = try #require(decodedJSON(calls[0].arguments) as? [String: Any])
        #expect(args["command"] as? String == "ls")
        #expect(args["description"] as? String == "List")
    }

    @Test("user tool_result block becomes a .tool message with toolCallId")
    func toolResultBecomesToolMessage() throws {
        let jsonl = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"output text"}]},"uuid":"u2"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 1)
        let msg = try #require(messages.first)
        #expect(msg.role == .tool)
        #expect(msg.toolCallId == "toolu_abc")
        #expect(msg.textContent == "output text")
    }

    @Test("tool_result with block-array content is flattened to text")
    func toolResultWithBlockArrayContent() throws {
        let jsonl = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_xyz","content":[{"type":"text","text":"first "},{"type":"text","text":"second"}]}]},"uuid":"u3"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 1)
        #expect(messages.first?.role == .tool)
        #expect(messages.first?.textContent == "first second")
    }

    @Test("error tool_result is still emitted; error flag is not used to suppress")
    func errorToolResultEmitted() throws {
        let jsonl = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_err","content":"boom","is_error":true}]},"uuid":"u4"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 1)
        #expect(messages.first?.toolCallId == "toolu_err")
        #expect(messages.first?.textContent == "boom")
    }

    @Test("thinking blocks are dropped silently")
    func thinkingBlocksDropped() throws {
        let jsonl = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"sig"},{"type":"text","text":"answer"}]},"uuid":"a1"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 1)
        #expect(messages.first?.textContent == "answer")
    }

    @Test("sidechain records are skipped")
    func sidechainSkipped() throws {
        let jsonl = #"""
        {"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent"},"uuid":"u1"}
        {"type":"user","isSidechain":false,"message":{"role":"user","content":"main"},"uuid":"u2"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 1)
        #expect(messages.first?.textContent == "main")
    }

    @Test("multiple records preserve conversation order")
    func conversationOrder() throws {
        let jsonl = #"""
        {"type":"user","message":{"role":"user","content":"first"},"uuid":"u1"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"second"}]},"uuid":"a1"}
        {"type":"user","message":{"role":"user","content":"third"},"uuid":"u2"}
        """#
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 3)
        #expect(messages[0].textContent == "first")
        #expect(messages[0].role == .user)
        #expect(messages[1].textContent == "second")
        #expect(messages[1].role == .assistant)
        #expect(messages[2].textContent == "third")
        #expect(messages[2].role == .user)
    }

    @Test("blank lines in the file are tolerated")
    func blankLinesTolerated() throws {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"a"},"uuid":"u1"}

        {"type":"user","message":{"role":"user","content":"b"},"uuid":"u2"}
        """
        let messages = try parse(jsonl: jsonl)
        #expect(messages.count == 2)
    }

    @Test("malformed JSON line throws an error")
    func malformedLineThrows() throws {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"ok"},"uuid":"u1"}
        not-json-here
        """
        let url = try writeFixture(jsonl)
        defer { try? FileManager.default.removeItem(at: url) }
        let parser = ClaudeCodeTranscriptParser()
        #expect(throws: ClaudeCodeTranscriptParser.ParseError.self) {
            _ = try parser.parse(url)
        }
    }

    // MARK: - Helpers

    private func parse(jsonl: String) throws -> [Operator.Message] {
        let url = try writeFixture(jsonl)
        defer { try? FileManager.default.removeItem(at: url) }
        return try ClaudeCodeTranscriptParser().parse(url)
    }

    private func writeFixture(_ jsonl: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hayes-cc-\(UUID().uuidString).jsonl")
        try jsonl.data(using: .utf8)?.write(to: url)
        return url
    }

    private func decodedJSON(_ s: String) -> Any? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
