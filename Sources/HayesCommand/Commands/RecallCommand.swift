import ArgumentParser
import Foundation
import HayesCore
import Operator

/// The `hayes recall` subcommand.
///
/// Loads a transcript, runs ``HayesCore/RecallService`` against the
/// graph store, and emits surfaced (seed, behavior) pairs to stdout for
/// consumption by a harness hook (e.g. Claude Code's
/// `UserPromptSubmit`). Plaintext output is framed under a
/// `[Memories:]` block so the agent reads it as recalled context
/// rather than as part of the user's prompt; pass `--json` for a
/// machine-readable payload.
struct RecallCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "recall",
        abstract: "Surface relevant memory pairs for an in-flight conversation."
    )

    /// Path to the conversation transcript that grounds this recall pass.
    /// Format is auto-detected from the file extension.
    @Argument(help: "Path to the conversation transcript that grounds this recall pass.")
    var transcript: String

    @OptionGroup var common: CommonOptions

    /// Session identifier used for dedup against `session_injections`.
    /// Defaults to the transcript filename without its extension — for a
    /// Claude Code JSONL transcript that's the harness-native session
    /// UUID.
    @Option(name: .customLong("session-id"), help: "Session identifier. Defaults to the transcript filename stem.")
    var sessionID: String?

    /// Transcript format. ``TranscriptLoader/Format/auto`` (the default)
    /// infers the format from a Claude Code JSONL file; pass
    /// ``TranscriptLoader/Format/opencode`` with `--session-id` to read an
    /// OpenCode storage directory instead.
    @Option(name: .long, help: "Transcript format: auto (default), claudeCode, or opencode.")
    var format: TranscriptLoader.Format = .auto

    /// Backend to use for the optional ``HayesCore/ContextExtractor``
    /// pre-stage. ``MemoryBackendName/none`` disables the extractor
    /// entirely; recall then uses the last user message verbatim as the
    /// retrieval query.
    @Option(name: .customLong("context-extractor"), help: "LLM for the context-extractor pre-stage: afm (default), anthropic, or none.")
    var contextExtractor: MemoryBackendName = .afm

    /// Number of trailing transcript messages to consider when forming
    /// the retrieval window.
    @Option(name: .long, help: "Trailing transcript messages to consider (default 5).")
    var window: Int = 5

    /// When set, retrieval runs but no `session_injections` rows are
    /// written and pairs already injected this session surface as
    /// skipped pairs with their reason.
    @Flag(name: .customLong("dry-run"), help: "Explain mode: run retrieval but write nothing; list skipped pairs.")
    var dryRun: Bool = false

    /// `--no-store-injection` flips the default (`true`) to disable
    /// injection persistence. Useful for embedded callers that want
    /// retrieval semantics without the dedup side effect.
    @Flag(
        name: .customLong("store-injection"),
        inversion: .prefixedNo,
        exclusivity: .exclusive,
        help: "Persist surfaced pairs to session_injections (default true)."
    )
    var storeInjection: Bool = true

    /// Emit JSON instead of plaintext.
    @Flag(name: .long, help: "Emit JSON instead of the framed plaintext block.")
    var json: Bool = false

    /// Anthropic API key for the context-extractor when
    /// ``contextExtractor`` is ``MemoryBackendName/anthropic``. Falls
    /// back to the `ANTHROPIC_API_KEY` environment variable.
    @Option(name: .customLong("anthropic-api-key"), help: "Anthropic API key. Falls back to ANTHROPIC_API_KEY.")
    var anthropicAPIKey: String?

    init() {}

    mutating func run() async throws {
        let transcriptURL = URL(fileURLWithPath: transcript)

        // UserPromptSubmit fires before Claude Code writes the new prompt to
        // the transcript, so on the first turn of a fresh session the file
        // doesn't exist yet. That's "no history," not an error — bail
        // quietly so the hook produces empty output rather than a failure.
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            return
        }

        let session = sessionID ?? RecallCommand.defaultSessionID(for: transcriptURL)

        let loader = TranscriptLoader()
        let messages = try await loader.load(path: transcriptURL, format: format, sessionID: sessionID)

        let dbURL = HayesPaths.resolve(dbArgument: common.db)
        let store = try GraphStore(path: dbURL)
        let embeddings = try NLEmbeddingProvider()
        let extractor = try makeExtractor()

        let service = RecallService(
            store: store,
            embeddings: embeddings,
            extractor: extractor
        )

        let result = try await service.recall(
            messages: messages,
            sessionID: session,
            options: resolvedOptions()
        )

        if json {
            try print(RecallCommand.renderJSON(result))
        } else {
            let text = RecallCommand.renderPlaintext(result, dryRun: dryRun)
            if !text.isEmpty {
                print(text)
            }
        }
    }

    // MARK: - Helpers

    /// Returns the transcript filename stem. For Claude Code JSONL
    /// transcripts that's the harness-native session UUID; for other
    /// formats it's a stable, conversation-scoped string.
    static func defaultSessionID(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Maps the parsed flag surface to the ``HayesCore/RecallOptions``
    /// the service expects.
    func resolvedOptions() -> RecallOptions {
        RecallOptions(
            windowSize: window,
            dryRun: dryRun,
            storeInjection: storeInjection
        )
    }

    /// Plaintext renderer.
    ///
    /// Surfaced pairs are framed under a `[Memories:]` block so that
    /// when the output is appended verbatim to a user prompt (as
    /// `UserPromptSubmit` does), the agent reads them as recalled
    /// context rather than as part of the user's request. Each block
    /// is preceded by a blank-line separator. Under `--dry-run`, a
    /// second `[Skipped:]` block lists retrieved-but-filtered pairs
    /// with their reason. An entirely empty result renders as `""`.
    static func renderPlaintext(_ result: RecallResult, dryRun: Bool) -> String {
        var blocks: [String] = []
        if !result.surfaced.isEmpty {
            let lines = result.surfaced.map { "- \($0.seedText) → \($0.behaviorText)" }
            blocks.append("[Memories:]\n" + lines.joined(separator: "\n"))
        }
        if dryRun, !result.skipped.isEmpty {
            let lines = result.skipped.map {
                "- \($0.seedText) → \($0.behaviorText) (\($0.reason.rawValue))"
            }
            blocks.append("[Skipped:]\n" + lines.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else { return "" }
        return "\n\n" + blocks.joined(separator: "\n\n")
    }

    /// JSON renderer.
    static func renderJSON(_ result: RecallResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeExtractor() throws -> ContextExtractor? {
        switch contextExtractor {
        case .none:
            return nil
        case .afm, .anthropic:
            let key = anthropicAPIKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            let backend = try contextExtractor.resolveBackend(anthropicAPIKey: key)
            return ContextExtractor(llm: backend.makeLLMClient())
        }
    }
}
