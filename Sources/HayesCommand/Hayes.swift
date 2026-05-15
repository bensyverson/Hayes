import ArgumentParser

/// The `hayes` CLI entry point.
///
/// Phase 5 lands an empty subcommand surface; Phase 6 fills in
/// `recall`, `assess`, `inspect`, `ls`, `forget`, and `session`. Until
/// then this stub keeps the executable target buildable.
@main
struct Hayes: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "hayes",
        abstract: "Automatic memory for LLM agents.",
        version: "0.1.0-pre"
    )

    func run() async throws {
        print("hayes CLI — subcommands land in Phase 6.")
    }
}
