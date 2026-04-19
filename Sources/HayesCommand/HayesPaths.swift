import Foundation

/// Filesystem layout for the `hayes` CLI.
///
/// All Hayes user data lives under `~/.hayes/`. ``HayesPaths`` centralises
/// the paths the CLI reads and writes so tests and the shipping binary stay
/// in sync.
enum HayesPaths {
    /// The root directory for all Hayes user data (`~/.hayes/`).
    static let root: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".hayes", isDirectory: true)

    /// The default SQLite graph store, `~/.hayes/graph.sqlite`.
    static let defaultDatabase: URL = root.appendingPathComponent("graph.sqlite")

    /// The most recently rendered canvas image, `~/.hayes/canvas.png`.
    static let canvasImage: URL = root.appendingPathComponent("canvas.png")

    /// The JSONL debug log of memory-stage LLM calls,
    /// `~/.hayes/memory.log`. Only written when `DEBUG` is set.
    static let memoryLog: URL = root.appendingPathComponent("memory.log")

    /// Creates ``root`` if it does not already exist. Idempotent.
    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    /// Resolves the `--db` CLI argument into a concrete URL.
    ///
    /// - Parameter dbArgument: The raw argument value, or `nil` for the default.
    /// - Returns: ``defaultDatabase`` when `dbArgument` is nil / empty, otherwise
    ///   the argument with leading `~` expanded to the user's home.
    static func resolve(dbArgument: String?) -> URL {
        guard let raw = dbArgument, !raw.isEmpty else { return defaultDatabase }
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}
