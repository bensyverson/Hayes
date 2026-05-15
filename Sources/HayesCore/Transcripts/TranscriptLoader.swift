import Foundation
import Operator

/// Loads conversation transcripts from disk and emits `Operator.Message`
/// values regardless of the originating harness format.
///
/// `TranscriptLoader` is the single entry point used by both the CLI's
/// `recall` and `assess` subcommands and any embedded callers. Format
/// selection happens via ``Format``; when ``Format/auto`` is requested,
/// the loader infers the format from the file extension and, if needed,
/// by probing the first non-empty record.
///
/// The OpenAI Responses format is recognized as a future surface but is
/// not yet implemented; requesting it returns ``LoadError/formatNotImplemented(_:)``.
public struct TranscriptLoader: Sendable {
    /// Transcript file formats the loader knows about.
    public enum Format: String, Sendable, CaseIterable {
        /// Detect the format from the file extension or by probing the
        /// first record.
        case auto
        /// Claude Code's JSONL transcript format.
        case claudeCode
        /// OpenAI Responses API transcripts. Recognized but not yet
        /// implemented.
        case openaiResponses
    }

    /// Errors thrown by ``load(path:format:)``.
    public enum LoadError: Swift.Error, Sendable {
        /// The transcript file could not be read from disk.
        case fileNotFound(URL)
        /// Auto-detection failed; the file does not match any known format.
        case formatNotDetected(URL)
        /// The requested format is reserved but not yet implemented.
        case formatNotImplemented(Format)
    }

    /// Creates a loader. No configuration is required.
    public init() {}

    /// Loads `path` and returns its messages in conversation order.
    /// - Parameters:
    ///   - path: The transcript file URL.
    ///   - format: The format to use. Defaults to ``Format/auto``.
    /// - Returns: The decoded messages.
    public func load(path: URL, format: Format = .auto) async throws -> [Operator.Message] {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LoadError.fileNotFound(path)
        }

        let resolved = try resolveFormat(format, for: path)
        switch resolved {
        case .claudeCode:
            return try ClaudeCodeTranscriptParser().parse(path)
        case .openaiResponses:
            throw LoadError.formatNotImplemented(.openaiResponses)
        case .auto:
            throw LoadError.formatNotDetected(path) // unreachable: resolveFormat returns concrete
        }
    }

    /// Resolves an `.auto` request to a concrete format, or returns the
    /// requested format unchanged.
    private func resolveFormat(_ format: Format, for url: URL) throws -> Format {
        guard format == .auto else { return format }
        if url.pathExtension.lowercased() == "jsonl" { return .claudeCode }
        if probeIsClaudeCode(url: url) { return .claudeCode }
        throw LoadError.formatNotDetected(url)
    }

    /// Returns `true` when the first non-empty line of `url` decodes as a
    /// JSON object that carries the Claude Code transcript signature.
    private func probeIsClaudeCode(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return false }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  let record = object as? [String: Any]
            else { return false }
            return record["sessionId"] != nil
                || record["parentUuid"] != nil
                || record["isSidechain"] != nil
        }
        return false
    }
}
