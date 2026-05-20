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

    /// The in-flight user prompt, when the harness can supply it before it
    /// lands in the transcript. Claude Code's `UserPromptSubmit` hook fires
    /// before the new prompt is written to the transcript, so passing it
    /// here lets recall reflect the current turn instead of lagging by one
    /// (and surfaces memories on the very first turn). Ignored when empty.
    @Option(name: .long, help: "Current user prompt to treat as the latest message (e.g. from a UserPromptSubmit hook).")
    var prompt: String?

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

    /// When set, recall prepends a one-line nudge to its plaintext output if
    /// no Anthropic API key can be resolved — surfacing, through recall's
    /// injection channel, that `assess` can't authenticate. Opt-in so it only
    /// fires where Anthropic is expected (the plugin passes it); standalone
    /// `hayes recall` stays silent. Ignored with `--json`.
    @Flag(name: .customLong("warn-missing-anthropic-key"), help: "Warn (via plaintext output) when no Anthropic key is available for assess.")
    var warnMissingAnthropicKey: Bool = false

    /// Anthropic API key for the context-extractor when
    /// ``contextExtractor`` is ``MemoryBackendName/anthropic``. Falls
    /// back to the `ANTHROPIC_API_KEY` environment variable.
    @Option(name: .customLong("anthropic-api-key"), help: "Anthropic API key. Falls back to ANTHROPIC_API_KEY.")
    var anthropicAPIKey: String?

    init() {}

    mutating func run() async throws {
        let body = try await recalledOutput()

        // --json is for machine callers, so it stays pure: no plaintext nudge.
        if json {
            if let body, !body.isEmpty {
                print(body)
            }
            return
        }

        // The nudge resolves the key only when opted in, so an unflagged or
        // AFM-only run never reads the Keychain here.
        let nudge: String? = try warnMissingAnthropicKey
            ? RecallCommand.missingAnthropicKeyNudge(
                warn: true,
                resolvedKey: AnthropicCredentialResolver.resolve(flag: anthropicAPIKey)
            )
            : nil

        let parts = [nudge, body].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            print(parts.joined(separator: "\n\n"))
        }
    }

    /// Runs the recall pipeline and returns the rendered output (JSON or the
    /// framed plaintext block), or `nil` when there's nothing to recall from.
    private func recalledOutput() async throws -> String? {
        let transcriptURL = URL(fileURLWithPath: transcript)

        // UserPromptSubmit fires before Claude Code writes the new prompt to
        // the transcript, so on the first turn of a fresh session the file
        // doesn't exist yet. When the harness passes the prompt via --prompt
        // we can still recall from it; otherwise that's "no history," not an
        // error — return nothing so the hook produces empty output.
        let transcriptExists = FileManager.default.fileExists(atPath: transcriptURL.path)
        guard transcriptExists || prompt?.isEmpty == false else {
            return nil
        }

        let session = sessionID ?? RecallCommand.defaultSessionID(for: transcriptURL)

        let loader = TranscriptLoader()
        let loaded = transcriptExists
            ? try await loader.load(path: transcriptURL, format: format, sessionID: sessionID)
            : []
        let messages = RecallCommand.combinedMessages(loaded: loaded, prompt: prompt)
        guard !messages.isEmpty else { return nil }

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
            return try RecallCommand.renderJSON(result)
        }
        let text = RecallCommand.renderPlaintext(result, dryRun: dryRun)
        return text.isEmpty ? nil : text
    }

    // MARK: - Helpers

    /// Returns the transcript filename stem. For Claude Code JSONL
    /// transcripts that's the harness-native session UUID; for other
    /// formats it's a stable, conversation-scoped string.
    static func defaultSessionID(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Returns `loaded` with `prompt` appended as a trailing `.user`
    /// message, so an in-flight prompt the harness supplied out-of-band
    /// becomes the retrieval anchor. A `nil`/empty prompt — or one already
    /// equal to the last user message (a harness that persists first) —
    /// leaves the list unchanged.
    static func combinedMessages(loaded: [Operator.Message], prompt: String?) -> [Operator.Message] {
        guard let prompt, !prompt.isEmpty else { return loaded }
        let lastUserText = loaded.last(where: { $0.role == .user && $0.toolCallId == nil })?.textContent
        guard lastUserText != prompt else { return loaded }
        return loaded + [Operator.Message(role: .user, content: prompt)]
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

    /// The one-line nudge surfaced when memory distillation can't
    /// authenticate. Recall is the only hook event with an injection channel,
    /// so it carries the warning on behalf of `assess` (whose Stop/SessionStart
    /// hooks can't inject). Returns `nil` unless warning is enabled *and* no
    /// key resolves, so it only fires where Anthropic is actually expected.
    /// - Parameters:
    ///   - warn: Whether the caller opted into the warning (the plugin does).
    ///   - resolvedKey: The Anthropic key the resolver found, if any.
    /// - Returns: The nudge text, or `nil` when no warning is warranted.
    static func missingAnthropicKeyNudge(warn: Bool, resolvedKey: String?) -> String? {
        guard warn, resolvedKey == nil else {
            return nil
        }
        return "[Hayes] Memory distillation (assess) is disabled: no Anthropic API key found. Run `hayes auth set` to enable it."
    }

    private func makeExtractor() throws -> ContextExtractor? {
        switch contextExtractor {
        case .none:
            return nil
        case .afm:
            // AFM ignores the key; resolving here would needlessly read the
            // Keychain (and could prompt) for an on-device-only run.
            let backend = try contextExtractor.resolveBackend(anthropicAPIKey: nil)
            return ContextExtractor(llm: backend.makeLLMClient())
        case .anthropic:
            let key = try AnthropicCredentialResolver.resolve(flag: anthropicAPIKey)
            let backend = try contextExtractor.resolveBackend(anthropicAPIKey: key)
            return ContextExtractor(llm: backend.makeLLMClient())
        }
    }
}
