import Foundation
import Operator

/// Parses Claude Code's per-session JSONL transcript files into
/// `Operator.Message` values for downstream analysis.
///
/// Claude Code records one JSON object per line; many record types describe
/// editor or harness state and are skipped here. Only `user` and `assistant`
/// records with a `message` payload are surfaced as messages. Sidechain
/// (subagent) records are skipped so the main conversation flow is preserved.
///
/// Content blocks are mapped as follows:
/// - `text` blocks on a user record are joined into a single
///   `Operator.Message` of role `.user`.
/// - `text` and `tool_use` blocks on an assistant record produce one
///   `Operator.Message` of role `.assistant` whose `toolCalls` array
///   carries each tool invocation.
/// - `tool_result` blocks on a user record each produce one
///   `Operator.Message` of role `.tool` carrying the result's
///   `tool_use_id` as `toolCallId`.
/// - `thinking` blocks have no representation on `Operator.Message` and
///   are dropped.
public struct ClaudeCodeTranscriptParser: Sendable {
    /// Creates a parser. No configuration is required.
    public init() {}

    /// Errors thrown while parsing a transcript file.
    public enum ParseError: Swift.Error, Sendable {
        /// A non-empty line could not be decoded as JSON.
        case malformedJSON(lineNumber: Int)
    }

    /// Parses the JSONL transcript at `url` and returns its messages in
    /// conversation order.
    /// - Parameter url: The path to a Claude Code JSONL transcript.
    /// - Returns: The decoded messages, in file order.
    public func parse(_ url: URL) throws -> [Operator.Message] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var output: [Operator.Message] = []
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  let record = object as? [String: Any]
            else {
                throw ParseError.malformedJSON(lineNumber: lineNumber)
            }

            guard let type = record["type"] as? String,
                  type == "user" || type == "assistant"
            else { continue }

            if let isSidechain = record["isSidechain"] as? Bool, isSidechain { continue }
            guard let message = record["message"] as? [String: Any] else { continue }

            output.append(contentsOf: messages(fromRecordMessage: message, fallbackType: type))
        }
        return output
    }

    /// Converts a single Claude Code `message` payload into zero or more
    /// `Operator.Message` values.
    /// - Parameters:
    ///   - message: The `message` object from a conversation record.
    ///   - fallbackType: The record's `type` field, used when `message.role`
    ///     is absent.
    private func messages(
        fromRecordMessage message: [String: Any],
        fallbackType: String
    ) -> [Operator.Message] {
        let roleString = (message["role"] as? String) ?? fallbackType
        let content = message["content"]

        if let string = content as? String {
            guard !string.isEmpty else { return [] }
            let role: Operator.Message.Role = roleString == "assistant" ? .assistant : .user
            return [Operator.Message(role: role, content: string)]
        }

        guard let blocks = content as? [[String: Any]] else { return [] }

        return roleString == "assistant"
            ? assistantMessages(from: blocks)
            : userMessages(from: blocks)
    }

    /// Builds a single assistant `Operator.Message` from the content blocks
    /// of an assistant record, merging text parts and lifting `tool_use`
    /// blocks into ``Operator/Message/toolCalls``.
    private func assistantMessages(from blocks: [[String: Any]]) -> [Operator.Message] {
        var textBuffer: [String] = []
        var toolCalls: [Operator.Message.ToolCallInfo] = []

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { textBuffer.append(text) }
            case "tool_use":
                if let call = toolCall(from: block) { toolCalls.append(call) }
            default:
                continue // thinking and any unknown blocks are dropped
            }
        }

        let joined = textBuffer.joined()
        let contentParts: [Operator.ContentPart] = joined.isEmpty ? [] : [.text(joined)]
        let calls = toolCalls.isEmpty ? nil : toolCalls
        guard !contentParts.isEmpty || calls != nil else { return [] }
        return [Operator.Message(role: .assistant, content: contentParts, toolCalls: calls)]
    }

    /// Builds messages for a user record's content blocks, emitting one
    /// `.tool` message per `tool_result` block plus, if any text remains,
    /// a single `.user` message.
    private func userMessages(from blocks: [[String: Any]]) -> [Operator.Message] {
        var output: [Operator.Message] = []
        var textBuffer: [String] = []

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { textBuffer.append(text) }
            case "tool_result":
                if let message = toolResultMessage(from: block) { output.append(message) }
            default:
                continue
            }
        }

        let joined = textBuffer.joined()
        if !joined.isEmpty {
            output.append(Operator.Message(role: .user, content: joined))
        }
        return output
    }

    /// Constructs a ``Operator/Message/ToolCallInfo`` from a `tool_use` block,
    /// re-serializing its `input` object as a JSON string.
    private func toolCall(from block: [String: Any]) -> Operator.Message.ToolCallInfo? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String
        else { return nil }
        let input = block["input"] ?? [String: Any]()
        let arguments: String = {
            guard let data = try? JSONSerialization.data(
                withJSONObject: input,
                options: [.sortedKeys]
            ),
                let string = String(data: data, encoding: .utf8)
            else { return "{}" }
            return string
        }()
        return Operator.Message.ToolCallInfo(id: id, name: name, arguments: arguments)
    }

    /// Builds a `.tool` message from a `tool_result` block, flattening any
    /// nested block array down to joined text.
    private func toolResultMessage(from block: [String: Any]) -> Operator.Message? {
        guard let id = block["tool_use_id"] as? String else { return nil }
        let text: String
        if let string = block["content"] as? String {
            text = string
        } else if let parts = block["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        } else {
            text = ""
        }
        return Operator.Message(role: .tool, content: text, toolCallId: id)
    }
}
