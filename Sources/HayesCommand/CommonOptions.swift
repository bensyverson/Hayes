import ArgumentParser

/// The flag(s) every `hayes` subcommand shares.
///
/// `ParsableArguments` (not `ParsableCommand`) so each subcommand
/// composes the same flag surface without re-declaring the wording.
struct CommonOptions: ParsableArguments {
    /// SQLite path for the graph store. Defaults to `~/.hayes/graph.sqlite`
    /// when omitted. Leading `~` is expanded against the user's home directory.
    @Option(name: .long, help: "SQLite path for the memory graph. Defaults to ~/.hayes/graph.sqlite.")
    var db: String?

    init() {}
}
