import Foundation
import GRDB
import Operator

/// Parses OpenCode's SQLite session store into `Operator.Message` values
/// for downstream analysis.
///
/// Current OpenCode (storage migration v2 and later) keeps conversations in
/// a single SQLite database (by default `~/.local/share/opencode/opencode.db`,
/// under `$OPENCODE_DATA_DIR`). Two tables matter:
///
/// - `message(id, session_id, time_created, data)` — one row per message;
///   `data` is JSON carrying at least `role` (`user` or `assistant`).
/// - `part(id, message_id, session_id, time_created, data)` — one row per
///   content part; `data` is JSON discriminated by `type`.
///
/// The database is opened read-only — Hayes never writes to OpenCode's
/// store. Messages are returned in conversation order (`time_created`, then
/// `id`); parts within a message preserve the same ordering.
///
/// Parts are mapped as follows, mirroring ``ClaudeCodeTranscriptParser``:
/// - `text` parts are joined into the message's text content.
/// - `tool` parts on an assistant message are lifted into the message's
///   `toolCalls` (`callID` → id, `tool` → name,
///   `state.input` → JSON arguments); a completed tool part additionally
///   emits a following `.tool` message carrying `state.output` keyed by
///   `callID`.
/// - All other part types (`reasoning`, `file`, `step-start`, `step-finish`,
///   `patch`, …) have no representation on `Operator.Message` and are
///   dropped.
public struct OpenCodeTranscriptParser: Sendable {
    /// Creates a parser. No configuration is required.
    public init() {}

    /// Errors thrown while parsing an OpenCode database.
    public enum ParseError: Swift.Error, Sendable {
        /// The SQLite database could not be opened for reading.
        case databaseUnreadable(URL)
    }

    /// Parses the session identified by `sessionID` from the OpenCode SQLite
    /// database at `databasePath`, returning its messages in conversation
    /// order. An unknown session id yields an empty array.
    /// - Parameters:
    ///   - databasePath: Path to OpenCode's `opencode.db`.
    ///   - sessionID: The OpenCode session identifier to load.
    /// - Returns: The decoded messages, in conversation order.
    public func parse(databasePath: URL, sessionID: String) throws -> [Operator.Message] {
        // Guard existence first: a read-write fallback open (see
        // openForReading) would otherwise *create* an empty database, which
        // must never happen inside OpenCode's data directory.
        guard FileManager.default.fileExists(atPath: databasePath.path) else {
            throw ParseError.databaseUnreadable(databasePath)
        }

        let messageRows: [Row]
        let partRows: [Row]
        do {
            let dbQueue = try Self.openForReading(at: databasePath)
            (messageRows, partRows) = try dbQueue.read { db in
                let messages = try Row.fetchAll(
                    db,
                    sql: "SELECT id, data FROM message WHERE session_id = ? ORDER BY time_created, id",
                    arguments: [sessionID]
                )
                let parts = try Row.fetchAll(
                    db,
                    sql: "SELECT message_id, data FROM part WHERE session_id = ? ORDER BY time_created, id",
                    arguments: [sessionID]
                )
                return (messages, parts)
            }
        } catch {
            throw ParseError.databaseUnreadable(databasePath)
        }

        // Group parts by message id, preserving the query's ordering.
        var partsByMessage: [String: [[String: Any]]] = [:]
        for row in partRows {
            guard let messageID: String = row["message_id"],
                  let dataString: String = row["data"],
                  let part = decodeObject(dataString)
            else { continue }
            partsByMessage[messageID, default: []].append(part)
        }

        var output: [Operator.Message] = []
        for row in messageRows {
            guard let id: String = row["id"],
                  let dataString: String = row["data"],
                  let data = decodeObject(dataString),
                  let role = data["role"] as? String
            else { continue }
            output.append(contentsOf: messages(forRole: role, parts: partsByMessage[id] ?? []))
        }
        return output
    }

    /// Opens the database for reading.
    ///
    /// A read-only connection is preferred, but SQLite cannot open a
    /// WAL-mode database read-only (it needs to create the `-shm` file, which
    /// `SQLITE_OPEN_READONLY` forbids) — and OpenCode's database is in WAL
    /// mode. So we fall back to a normal connection, which reads the latest
    /// committed snapshot correctly. The parser only ever issues `SELECT`s,
    /// so OpenCode's data is never modified.
    private static func openForReading(at path: URL) throws -> DatabaseQueue {
        var readOnly = Configuration()
        readOnly.readonly = true
        if let queue = try? DatabaseQueue(path: path.path, configuration: readOnly) {
            return queue
        }
        return try DatabaseQueue(path: path.path)
    }

    /// Decodes a JSON `data` column into a dictionary, or `nil` if it is not
    /// a JSON object.
    private func decodeObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }

    // MARK: - Mapping

    /// Maps a message's parts into zero or more `Operator.Message` values
    /// according to its role.
    private func messages(forRole role: String, parts: [[String: Any]]) -> [Operator.Message] {
        role == "assistant"
            ? assistantMessages(from: parts)
            : userMessages(from: parts)
    }

    /// Builds a user message from its parts: text parts are joined into a
    /// single `.user` message; non-text parts are ignored.
    private func userMessages(from parts: [[String: Any]]) -> [Operator.Message] {
        let joined = parts
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !joined.isEmpty else { return [] }
        return [Operator.Message(role: .user, content: joined)]
    }

    /// Builds messages for an assistant turn: one `.assistant` message
    /// merging text and lifting `tool` parts into
    /// ``Operator/Message/toolCalls``, followed by one `.tool` message per
    /// completed tool part carrying its `state.output`.
    private func assistantMessages(from parts: [[String: Any]]) -> [Operator.Message] {
        var textBuffer: [String] = []
        var toolCalls: [Operator.Message.ToolCallInfo] = []
        var toolResults: [Operator.Message] = []

        for part in parts {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String { textBuffer.append(text) }
            case "tool":
                if let call = toolCall(from: part) { toolCalls.append(call) }
                if let result = toolResultMessage(from: part) { toolResults.append(result) }
            default:
                continue // reasoning, file, step-start/-finish, patch, and unknown parts are dropped
            }
        }

        var output: [Operator.Message] = []
        let joined = textBuffer.joined()
        let contentParts: [Operator.ContentPart] = joined.isEmpty ? [] : [.text(joined)]
        let calls = toolCalls.isEmpty ? nil : toolCalls
        if !contentParts.isEmpty || calls != nil {
            output.append(Operator.Message(role: .assistant, content: contentParts, toolCalls: calls))
        }
        output.append(contentsOf: toolResults)
        return output
    }

    /// Constructs a ``Operator/Message/ToolCallInfo`` from a `tool` part,
    /// re-serializing `state.input` as a stable JSON string.
    private func toolCall(from part: [String: Any]) -> Operator.Message.ToolCallInfo? {
        guard let id = part["callID"] as? String,
              let name = part["tool"] as? String
        else { return nil }
        let input = (part["state"] as? [String: Any])?["input"] ?? [String: Any]()
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

    /// Builds a `.tool` message from a `tool` part that carries a completed
    /// `state.output`, keyed by the part's `callID`. Returns `nil` for tool
    /// parts that have not yet produced output.
    private func toolResultMessage(from part: [String: Any]) -> Operator.Message? {
        guard let id = part["callID"] as? String,
              let output = (part["state"] as? [String: Any])?["output"] as? String
        else { return nil }
        return Operator.Message(role: .tool, content: output, toolCallId: id)
    }
}
