import ArgumentParser

/// The `hayes` CLI entry point.
///
/// Subcommands land incrementally as Phase 6 of the CLI refactor
/// progresses; `recall` is wired first because it's the hot-path
/// command called from harness hooks like Claude Code's
/// `UserPromptSubmit`.
@main
struct Hayes: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "hayes",
        abstract: "Automatic memory for LLM agents.",
        version: "0.2.0",
        subcommands: [
            RecallCommand.self,
            AssessCommand.self,
            InspectCommand.self,
            LsCommand.self,
            ForgetCommand.self,
            SessionCommand.self,
        ]
    )

    init() {}
}
