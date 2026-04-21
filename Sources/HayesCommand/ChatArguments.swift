import ArgumentParser

/// Command-line arguments for `hayes chat`.
///
/// Uses `ParsableArguments` (not `ParsableCommand`) so the `@main` entry
/// point remains the TextUI ``HayesChatApp`` conformance. Resolved via
/// `ChatArguments.parseOrExit()` inside ``HayesChatApp/init()``.
struct ChatArguments: ParsableArguments {
    /// SQLite path for the graph store. Defaults to `~/.hayes/graph.sqlite`
    /// when omitted. Leading `~` is expanded against the user's home directory.
    @Option(name: .long, help: "SQLite path for the memory graph. Defaults to ~/.hayes/graph.sqlite.")
    var db: String?

    /// Backend for the pre-generation context-extraction stage. Defaults
    /// to Apple Intelligence — swap back to Anthropic for A/B comparison.
    @Option(name: .long, help: "LLM backend for the context extractor: afm (default) or anthropic.")
    var contextBackend: MemoryBackendName = .afm

    /// Backend for the post-run analyzer stage. Independent of
    /// `--context-backend` so the two stages can be evaluated separately.
    ///
    /// Defaults to Anthropic because AFM currently emits `submit_analysis`
    /// as fenced JSON text instead of invoking the registered tool proxy —
    /// an Operator/FoundationModels binding issue, not a prompt issue.
    /// Pass `afm` to opt back in for experiments.
    @Option(name: .long, help: "LLM backend for the analyzer: anthropic (default) or afm.")
    var analyzerBackend: MemoryBackendName = .anthropic

    init() {}

    /// CLI-shaped name for a ``MemoryBackend``. Resolves to the full
    /// enum once the Anthropic API key is known.
    enum MemoryBackendName: String, ExpressibleByArgument, CaseIterable {
        /// Apple's on-device Foundation Models.
        case afm
        /// Anthropic's API.
        case anthropic
    }
}
