import Foundation
import HayesCore

/// One row of `hayes session show`: an injection joined with its seed
/// and behavior nodes for rendering.
struct SessionInjectionDetail {
    let injection: SessionInjection
    let seed: Node
    let behavior: Node
}

/// Plaintext + JSON renderers for the `hayes session` subcommand group.
enum SessionRenderer {
    /// Per-call formatter — `ISO8601DateFormatter` is non-`Sendable`.
    private static func makeTimestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// One-line-per-session summary for `hayes session list`.
    static func renderListPlaintext(_ sessions: [SessionSummary]) -> String {
        let formatter = makeTimestampFormatter()
        return sessions.map { session in
            "\(session.sessionID)\t\(formatter.string(from: session.lastSeenAt))\t\(session.injectionCount) injection\(session.injectionCount == 1 ? "" : "s")"
        }.joined(separator: "\n")
    }

    /// JSON for `hayes session list --json`.
    static func renderListJSON(_ sessions: [SessionSummary]) throws -> String {
        try encode(sessions)
    }

    /// One-line-per-injection trail for `hayes session show`.
    static func renderTrailPlaintext(_ details: [SessionInjectionDetail]) -> String {
        let formatter = makeTimestampFormatter()
        return details.map { detail in
            let timestamp = formatter.string(from: detail.injection.injectedAt)
            let matched = detail.injection.matchedText.map { " (\($0))" } ?? ""
            return "\(timestamp)\t\(detail.seed.text) → \(detail.behavior.text)\(matched)"
        }.joined(separator: "\n")
    }

    /// JSON for `hayes session show --json`.
    static func renderTrailJSON(_ details: [SessionInjectionDetail]) throws -> String {
        let payload = details.map { detail in
            TrailPayload(
                injectedAt: detail.injection.injectedAt,
                seed: NodePayload(id: detail.seed.id, text: detail.seed.text),
                behavior: NodePayload(id: detail.behavior.id, text: detail.behavior.text),
                matchedText: detail.injection.matchedText
            )
        }
        return try encode(payload)
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private struct TrailPayload: Encodable {
        let injectedAt: Date
        let seed: NodePayload
        let behavior: NodePayload
        let matchedText: String?
    }

    private struct NodePayload: Encodable {
        let id: String
        let text: String
    }
}
