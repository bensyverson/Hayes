import ArgumentParser
import Foundation
import HayesCore
import Operator

/// The `hayes assess` subcommand.
///
/// Runs ``HayesCore/AssessService`` over one or more completed
/// transcripts, distilling lessons and reinforcing edges in the graph
/// store. Designed to run offline — typically from a `Stop` hook or a
/// nightly cron over an archive of past sessions.
struct AssessCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "assess",
        abstract: "Distill memory pairs from one or more completed transcripts."
    )

    /// One or more transcript paths. Shell-expanded globs work because
    /// the shell, not the command, performs expansion.
    @Argument(help: "One or more transcript paths (shell globs OK).")
    var transcripts: [String]

    @OptionGroup var common: CommonOptions

    /// Override the per-transcript identity. Only meaningful when a
    /// single transcript is supplied; ignored when batch-processing.
    /// Defaults to the transcript filename stem (= CC session UUID for
    /// Claude Code JSONL transcripts).
    @Option(name: .customLong("session-id"), help: "Override transcript identity. Single-transcript only.")
    var sessionID: String?

    /// Transcript format. ``TranscriptLoader/Format/auto`` (the default)
    /// infers the format from a Claude Code JSONL file; pass
    /// ``TranscriptLoader/Format/opencode`` with `--session-id` to read an
    /// OpenCode storage directory instead.
    @Option(name: .long, help: "Transcript format: auto (default), claudeCode, or opencode.")
    var format: TranscriptLoader.Format = .auto

    /// Lesson-extraction strategy.
    @Option(name: .long, help: "parallel (default) or one-shot.")
    var strategy: StrategyChoice = .parallel

    /// Parallel mode's in-flight analyze call cap. Ignored when
    /// ``strategy`` is ``StrategyChoice/oneShot``.
    @Option(name: .long, help: "Parallel mode concurrency cap (default 4, ignored for one-shot).")
    var concurrency: Int = 4

    /// Backend for the analyzer stage.
    @Option(name: .long, help: "Analyzer backend: anthropic (default) or afm.")
    var analyzer: MemoryBackendName = .anthropic

    /// Optional explicit model identifier for the Anthropic analyzer.
    /// Ignored when ``analyzer`` is ``MemoryBackendName/afm``.
    @Option(name: .long, help: "Explicit Anthropic model name (e.g. claude-haiku-4-5). Ignored on AFM.")
    var model: String?

    /// `--no-store-source` flips the default (`true`) so that
    /// `edges.source_transcript` and `edges.source_excerpt` are left
    /// NULL. `turn_index` is still recorded.
    @Flag(
        name: .customLong("store-source"),
        inversion: .prefixedNo,
        exclusivity: .exclusive,
        help: "Persist transcript identity + excerpt on each edge (default true)."
    )
    var storeSource: Bool = true

    /// Forces a full reprocess, ignoring stored assess progress. By
    /// default `hayes assess` only analyzes turns newer than the last
    /// recorded progress for the transcript identity.
    @Flag(name: .customLong("reassess"), help: "Reprocess every turn, ignoring stored assess progress.")
    var reassess: Bool = false

    /// Runs the batch assess path instead of the live synchronous one: a
    /// single reconcile pass that collects any ready batches and submits
    /// each transcript's backlog to the Anthropic Message Batches API
    /// (~50% cheaper, ~1-turn delay). Anthropic backend only. The live-only
    /// knobs (`--strategy`, `--reassess`, `--no-store-source`) don't apply.
    @Flag(name: .customLong("batch"), help: "Reconcile via the Anthropic Message Batches API (anthropic only).")
    var batch: Bool = false

    /// Anthropic API key for the analyzer when ``analyzer`` is
    /// ``MemoryBackendName/anthropic``. Falls back to
    /// `ANTHROPIC_API_KEY`.
    @Option(name: .customLong("anthropic-api-key"), help: "Anthropic API key. Falls back to ANTHROPIC_API_KEY.")
    var anthropicAPIKey: String?

    /// Strategy options exposed via `--strategy`.
    enum StrategyChoice: String, ExpressibleByArgument, CaseIterable {
        case parallel
        case oneShot = "one-shot"
    }

    init() {}

    func validate() throws {
        if analyzer == .none {
            throw ValidationError("--analyzer none is not supported; assess requires an LLM backend (afm or anthropic).")
        }
        if transcripts.count > 1, sessionID != nil {
            throw ValidationError("--session-id can only be used with a single transcript.")
        }
        if batch, analyzer != .anthropic {
            throw ValidationError("--batch requires --analyzer anthropic (the batch path is Anthropic-only).")
        }
    }

    mutating func run() async throws {
        let dbURL = HayesPaths.resolve(dbArgument: common.db)
        let store = try GraphStore(path: dbURL)
        let embeddings = try NLEmbeddingProvider()

        // AFM ignores the key; only the Anthropic path consults the resolver
        // (and therefore the Keychain), so an AFM run never triggers a prompt.
        let key: String? = try analyzer == .anthropic
            ? AnthropicCredentialResolver.resolve(flag: anthropicAPIKey)
            : nil
        let backend = try analyzer.resolveBackend(anthropicAPIKey: key)
        let runner = AnalysisRunner(backend: backend, model: model)
        let loader = TranscriptLoader()

        if batch {
            guard case let .anthropic(apiKey) = backend else {
                throw ValidationError("--batch requires the anthropic backend.")
            }
            try await runBatch(
                store: store,
                embeddings: embeddings,
                runner: runner,
                backend: backend,
                apiKey: apiKey,
                loader: loader
            )
            return
        }

        let service = AssessService(
            store: store,
            embeddings: embeddings,
            analyzer: runner,
            backend: backend
        )

        let options = resolvedOptions()
        var totalLessons = 0

        for path in transcripts {
            let url = URL(fileURLWithPath: path)
            let identity = sessionID ?? AssessCommand.defaultTranscriptIdentity(for: url)
            let messages = try await loader.load(path: url, format: format, sessionID: sessionID)
            let result = try await service.assess(
                messages: messages,
                transcriptIdentity: identity,
                options: options
            )
            totalLessons += result.lessons.count
            print("\(path)\t\(result.lessons.count) lessons")
        }

        print("Total: \(totalLessons) lessons across \(transcripts.count) transcript(s).")
    }

    /// Runs one batch reconcile pass: collect any ready batches globally,
    /// then submit each transcript's backlog. Anthropic-only.
    private func runBatch(
        store: GraphStore,
        embeddings: NLEmbeddingProvider,
        runner: AnalysisRunner,
        backend: MemoryBackend,
        apiKey: String,
        loader: TranscriptLoader
    ) async throws {
        let assess = AssessService(
            store: store,
            embeddings: embeddings,
            analyzer: runner,
            backend: backend
        )
        let client = AnthropicBatchClient(apiKey: apiKey)
        let reconciler = BatchReconciler(
            store: store,
            assess: assess,
            analyzer: runner,
            batchClient: client
        )

        // Collect ready batches first, independent of the transcripts — a
        // fresh session (e.g. a SessionStart trigger) may have no readable
        // transcript yet, but prior batches should still be picked up.
        try await reconciler.collect()

        var submitted = 0
        for path in transcripts {
            let url = URL(fileURLWithPath: path)
            let identity = sessionID ?? AssessCommand.defaultTranscriptIdentity(for: url)
            do {
                let messages = try await loader.load(path: url, format: format, sessionID: sessionID)
                try await reconciler.submit(transcript: identity, messages: messages)
                submitted += 1
            } catch {
                // Tolerate an unreadable transcript so collection still completes.
                FileHandle.standardError.write(Data("hayes: skipped \(path): \(error)\n".utf8))
            }
        }

        print("Batch reconcile complete: collected ready batches; submitted backlog for \(submitted) of \(transcripts.count) transcript(s).")
    }

    // MARK: - Helpers

    /// Returns the transcript filename stem. For Claude Code JSONL
    /// transcripts that's the harness-native session UUID, so a CC
    /// transcript reprocessed by `hayes assess` writes its edges with
    /// the same identifier the live `UserPromptSubmit` hook sees.
    static func defaultTranscriptIdentity(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Maps the parsed strategy + concurrency flags to the
    /// ``HayesCore/AssessOptions/Strategy`` value the service expects.
    static func resolveStrategy(
        _ choice: StrategyChoice,
        concurrency: Int
    ) -> AssessOptions.Strategy {
        switch choice {
        case .parallel: .parallel(concurrency: max(1, concurrency))
        case .oneShot: .oneShot
        }
    }

    /// Maps the parsed flag surface to the ``HayesCore/AssessOptions``
    /// the service expects.
    func resolvedOptions() -> AssessOptions {
        AssessOptions(
            strategy: AssessCommand.resolveStrategy(strategy, concurrency: concurrency),
            storeSource: storeSource,
            reassess: reassess
        )
    }
}
