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

    init() {}
}
