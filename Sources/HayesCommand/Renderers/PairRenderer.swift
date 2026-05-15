import Foundation
import HayesCore

/// Plaintext + JSON renderers shared across the introspection /
/// maintenance commands (`hayes inspect`, `ls`, `forget`).
///
/// All methods are pure: they only format the data their callers pass
/// in. No graph-store access; no I/O.
enum PairRenderer {
    /// Builds an ISO-8601 formatter — constructed per call because
    /// `ISO8601DateFormatter` is a mutable class and not `Sendable`,
    /// which would make a `static let` cache a strict-concurrency
    /// error. The CLI's render path is not hot enough for the cost
    /// to matter.
    private static func makeTimestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// Multi-line summary of a single ``PairDetail`` — used by
    /// `hayes inspect` and `hayes forget`.
    static func renderPlaintext(_ detail: PairDetail) -> String {
        var lines: [String] = [
            "\(detail.seed.id) → \(detail.behavior.id)",
            "seed: \(detail.seed.text)",
            "behavior: \(detail.behavior.text)",
            "weight: \(formatWeight(detail.edge.weight))",
            "updated: \(makeTimestampFormatter().string(from: detail.edge.updatedAt))",
        ]
        if let provenance = detail.edge.provenance {
            if let transcript = provenance.sourceTranscript {
                var line = "transcript: \(transcript)"
                if let turn = provenance.turnIndex {
                    line += "  turn \(turn)"
                }
                lines.append(line)
            } else if let turn = provenance.turnIndex {
                lines.append("turn \(turn)")
            }
            if let excerpt = provenance.sourceExcerpt {
                lines.append("excerpt: \(excerpt)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One-line-per-pair summary for `hayes ls`.
    static func renderListPlaintext(_ details: [PairDetail]) -> String {
        details.map { detail in
            let weight = formatWeight(detail.edge.weight)
            let timestamp = makeTimestampFormatter().string(from: detail.edge.updatedAt)
            let transcript = detail.edge.provenance?.sourceTranscript
            let provenance = transcript.map { " (\($0))" } ?? ""
            return "\(weight)\t\(timestamp)\t\(detail.seed.text) → \(detail.behavior.text)\(provenance)"
        }.joined(separator: "\n")
    }

    /// JSON object for a single ``PairDetail``.
    static func renderJSON(_ detail: PairDetail) throws -> String {
        let payload = JSONPayload(
            seed: NodePayload(id: detail.seed.id, text: detail.seed.text),
            behavior: NodePayload(id: detail.behavior.id, text: detail.behavior.text),
            edge: EdgePayload(
                weight: detail.edge.weight,
                updatedAt: detail.edge.updatedAt,
                provenance: detail.edge.provenance
            )
        )
        return try encode(payload)
    }

    /// JSON array for a list of pairs (`hayes ls --json`).
    static func renderListJSON(_ details: [PairDetail]) throws -> String {
        let array = details.map { detail in
            JSONPayload(
                seed: NodePayload(id: detail.seed.id, text: detail.seed.text),
                behavior: NodePayload(id: detail.behavior.id, text: detail.behavior.text),
                edge: EdgePayload(
                    weight: detail.edge.weight,
                    updatedAt: detail.edge.updatedAt,
                    provenance: detail.edge.provenance
                )
            )
        }
        return try encode(array)
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func formatWeight(_ weight: Double) -> String {
        String(format: "%.2f", weight)
    }

    private struct JSONPayload: Encodable {
        let seed: NodePayload
        let behavior: NodePayload
        let edge: EdgePayload
    }

    private struct NodePayload: Encodable {
        let id: String
        let text: String
    }

    private struct EdgePayload: Encodable {
        let weight: Double
        let updatedAt: Date
        let provenance: EdgeProvenance?
    }
}
