import ArgumentParser
import Foundation
import HayesCore

/// The `hayes session` subcommand group.
///
/// Wraps the session-injection table — the per-conversation record of
/// "what did Hayes surface this session." When users debug odd
/// injections, `hayes session show` is the trail they reach for.
struct SessionCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "session",
        abstract: "Inspect or reset per-session injection state.",
        subcommands: [List.self, Show.self, Reset.self]
    )

    init() {}

    /// `hayes session list` — enumerate known sessions.
    struct List: AsyncParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "list",
            abstract: "List known sessions, most-recent first."
        )

        @OptionGroup var common: CommonOptions

        /// Emit JSON instead of plaintext.
        @Flag(name: .long, help: "Emit JSON instead of plaintext.")
        var json: Bool = false

        init() {}

        mutating func run() async throws {
            let store = try GraphStore(path: HayesPaths.resolve(dbArgument: common.db))
            let sessions = try await store.listSessions()
            if json {
                try print(SessionRenderer.renderListJSON(sessions))
            } else {
                let text = SessionRenderer.renderListPlaintext(sessions)
                if !text.isEmpty {
                    print(text)
                }
            }
        }
    }

    /// `hayes session show <id>` — list the injection trail for one session.
    struct Show: AsyncParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "show",
            abstract: "Show the injection trail for one session."
        )

        /// The session identifier whose trail to print.
        @Argument(help: "Session identifier.")
        var sessionID: String

        @OptionGroup var common: CommonOptions

        /// Emit JSON instead of plaintext.
        @Flag(name: .long, help: "Emit JSON instead of plaintext.")
        var json: Bool = false

        init() {}

        mutating func run() async throws {
            let store = try GraphStore(path: HayesPaths.resolve(dbArgument: common.db))
            let injections = try await store.injectionsInSession(sessionID)
            let nodeIDs = Array(Set(injections.flatMap { [$0.sourceID, $0.targetID] }))
            let nodes = try await store.findNodes(ids: nodeIDs)
            let lookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

            let details: [SessionInjectionDetail] = injections.compactMap { injection in
                guard let seed = lookup[injection.sourceID],
                      let behavior = lookup[injection.targetID]
                else { return nil }
                return SessionInjectionDetail(
                    injection: injection,
                    seed: seed,
                    behavior: behavior
                )
            }

            if json {
                try print(SessionRenderer.renderTrailJSON(details))
            } else {
                let text = SessionRenderer.renderTrailPlaintext(details)
                if !text.isEmpty {
                    print(text)
                }
            }
        }
    }

    /// `hayes session reset <id>` — clear the injection trail for one session.
    struct Reset: AsyncParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "reset",
            abstract: "Clear the injection trail for one session."
        )

        /// The session identifier to reset.
        @Argument(help: "Session identifier.")
        var sessionID: String

        @OptionGroup var common: CommonOptions

        init() {}

        mutating func run() async throws {
            let store = try GraphStore(path: HayesPaths.resolve(dbArgument: common.db))
            try await store.resetSession(sessionID)
            print("Cleared injection trail for session \(sessionID).")
        }
    }
}
