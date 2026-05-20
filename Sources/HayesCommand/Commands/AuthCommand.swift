import ArgumentParser
import Foundation
import HayesCore

/// `hayes auth` — manage the Anthropic API key in the macOS Keychain.
///
/// The subcommands are deliberately thin: secret acquisition (a hidden
/// terminal prompt or a piped stdin line) lives here, while the storage,
/// clearing, and status logic lives in ``AuthService`` so it can be unit
/// tested without the real Keychain. The key is never accepted as a command
/// argument — that would leak it into shell history and the process list.
struct AuthCommand: ParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "auth",
        abstract: "Store and inspect the Anthropic API key in the macOS Keychain.",
        subcommands: [Set.self, Status.self, Clear.self]
    )

    init() {}

    /// `hayes auth set` — store the key, prompting on the terminal by default.
    struct Set: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "set",
            abstract: "Store the Anthropic API key (prompts on the terminal; the key is never echoed)."
        )

        /// Read the key as a single line from stdin instead of prompting,
        /// for scripted setup (e.g. piping from another password manager).
        @Flag(name: .customLong("from-stdin"), help: "Read the key from stdin instead of prompting.")
        var fromStdin: Bool = false

        init() {}

        func run() throws {
            let secret: String = fromStdin
                ? (readLine(strippingNewline: true) ?? "")
                : AuthCommand.promptHidden("Anthropic API key: ")
            try AuthService.store(secret: secret, in: KeychainCredentialStore())
            print("Stored the Anthropic API key in the Keychain (service \(HayesCredential.service)).")
        }
    }

    /// `hayes auth status` — report where the key resolves from, no secret.
    struct Status: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "status",
            abstract: "Show whether an Anthropic API key is available and which source would be used."
        )

        init() {}

        func run() throws {
            let report = try AuthService.statusReport(
                environment: ProcessInfo.processInfo.environment,
                store: KeychainCredentialStore()
            )
            print(AuthService.render(report))
        }
    }

    /// `hayes auth clear` — remove the stored key (idempotent).
    struct Clear: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "clear",
            abstract: "Remove the stored Anthropic API key from the Keychain."
        )

        init() {}

        func run() throws {
            try AuthService.clear(in: KeychainCredentialStore())
            print("Cleared the Anthropic API key from the Keychain (service \(HayesCredential.service)).")
        }
    }

    /// Prompts on the controlling terminal with echo disabled and returns the
    /// entered line (newline stripped). This is the untested I/O shell; the
    /// logic it feeds lives in ``AuthService``.
    /// - Parameter prompt: The text to display before reading.
    /// - Returns: The entered secret, or an empty string on EOF.
    static func promptHidden(_ prompt: String) -> String {
        FileHandle.standardError.write(Data(prompt.utf8))

        var original = termios()
        let isTTY = tcgetattr(STDIN_FILENO, &original) == 0
        if isTTY {
            var quiet = original
            quiet.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)
        }
        defer {
            if isTTY {
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
                FileHandle.standardError.write(Data("\n".utf8))
            }
        }

        return readLine(strippingNewline: true) ?? ""
    }
}
