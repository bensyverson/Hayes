import Foundation
import HayesCore

/// Store-injected logic behind the `auth` subcommands, separated from the
/// TTY/stdin I/O so it can be unit-tested against an in-memory
/// ``CredentialStore`` instead of the real macOS Keychain.
enum AuthService {
    /// Errors surfaced by ``store(secret:in:)``.
    enum AuthError: Error, Equatable, LocalizedError {
        /// No usable key was supplied (empty or whitespace-only input).
        case emptySecret

        var errorDescription: String? {
            switch self {
            case .emptySecret:
                "No API key was provided."
            }
        }
    }

    /// A snapshot of where the Anthropic key is available, for `auth status`.
    /// It carries only booleans — never the secret itself.
    struct StatusReport: Equatable {
        /// Which source `recall`/`assess` would resolve the key from. Mirrors
        /// the resolver's precedence minus the flag (which `status` has no
        /// equivalent of): environment over keychain.
        enum Source: String, Equatable {
            case environment
            case keychain
            case none
        }

        /// Whether `ANTHROPIC_API_KEY` is set to a non-empty value.
        let environmentHasKey: Bool
        /// Whether a non-empty key is stored in the Keychain.
        let keychainHasKey: Bool

        /// The source resolution would use, by precedence.
        var resolvedSource: Source {
            if environmentHasKey { return .environment }
            if keychainHasKey { return .keychain }
            return .none
        }
    }

    /// Trims and stores `secret` under the Anthropic key, rejecting empties.
    /// - Parameters:
    ///   - secret: The raw key as acquired from the terminal or stdin.
    ///   - store: The credential store to write to.
    /// - Throws: ``AuthError/emptySecret`` when the trimmed input is empty;
    ///   rethrows a store write failure.
    static func store(secret: String, in store: CredentialStore) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AuthError.emptySecret
        }
        try store.store(trimmed, for: HayesCredential.anthropicAPIKey)
    }

    /// Removes the stored Anthropic key. Idempotent: clearing an absent key
    /// succeeds.
    /// - Parameter store: The credential store to clear.
    /// - Throws: Rethrows a store deletion failure.
    static func clear(in store: CredentialStore) throws {
        try store.remove(for: HayesCredential.anthropicAPIKey)
    }

    /// Reports key availability without revealing the secret.
    /// - Parameters:
    ///   - environment: The environment to read `ANTHROPIC_API_KEY` from.
    ///   - store: The credential store to inspect.
    /// - Returns: A ``StatusReport`` describing which sources hold a key.
    /// - Throws: Rethrows a store lookup failure.
    static func statusReport(environment: [String: String], store: CredentialStore) throws -> StatusReport {
        let environmentHasKey = environment["ANTHROPIC_API_KEY"]?.isEmpty == false
        let stored = try store.value(for: HayesCredential.anthropicAPIKey)
        return StatusReport(environmentHasKey: environmentHasKey, keychainHasKey: stored?.isEmpty == false)
    }

    /// Renders a ``StatusReport`` as human-readable lines for the terminal.
    /// - Parameter report: The report to render.
    /// - Returns: A multi-line summary that never contains the secret.
    static func render(_ report: StatusReport) -> String {
        let resolved = switch report.resolvedSource {
        case .environment: "ANTHROPIC_API_KEY environment variable"
        case .keychain: "Keychain (\(HayesCredential.service))"
        case .none: "(none) — run `hayes auth set`"
        }
        return """
        Anthropic API key:
          Keychain (\(HayesCredential.service)): \(report.keychainHasKey ? "set" : "not set")
          ANTHROPIC_API_KEY environment variable: \(report.environmentHasKey ? "set" : "not set")
          Resolved from: \(resolved)
        """
    }
}
