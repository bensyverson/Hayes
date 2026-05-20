import Foundation
import HayesCore

/// Resolves the Anthropic API key for the `recall` and `assess` commands.
///
/// Precedence, highest first: an explicit `--anthropic-api-key` flag, then the
/// `ANTHROPIC_API_KEY` environment variable, then the credential store (the
/// macOS Keychain in production). The first non-empty source wins; the result
/// is `nil` only when none supply a key.
///
/// The load-bearing property is the *last* source: because the Keychain alone
/// suffices, a user who runs `hayes auth set` never has to export the
/// environment variable, so Claude Code never inherits the key and bills
/// against it. The environment stays available as an override rather than a
/// requirement.
enum AnthropicCredentialResolver {
    /// Resolves the key from explicit sources.
    /// - Parameters:
    ///   - flag: The value of `--anthropic-api-key`, if supplied.
    ///   - environment: The environment to read `ANTHROPIC_API_KEY` from.
    ///   - store: The credential store consulted last.
    /// - Returns: The first non-empty key by precedence, or `nil`.
    /// - Throws: Rethrows a failure from `store` (a lookup fault, never a
    ///   merely-absent key).
    static func resolve(
        flag: String?,
        environment: [String: String],
        store: CredentialStore
    ) throws -> String? {
        if let flag, !flag.isEmpty {
            return flag
        }
        if let fromEnvironment = environment["ANTHROPIC_API_KEY"], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        if let fromStore = try store.value(for: HayesCredential.anthropicAPIKey), !fromStore.isEmpty {
            return fromStore
        }
        return nil
    }

    /// Convenience that resolves against the live process environment and the
    /// macOS Keychain. A thin wrapper over
    /// ``resolve(flag:environment:store:)`` for command call sites; the
    /// precedence logic itself is tested through that pure entry point.
    /// - Parameter flag: The value of `--anthropic-api-key`, if supplied.
    /// - Returns: The resolved key, or `nil`.
    /// - Throws: Rethrows a Keychain lookup fault.
    static func resolve(flag: String?) throws -> String? {
        try resolve(
            flag: flag,
            environment: ProcessInfo.processInfo.environment,
            store: KeychainCredentialStore()
        )
    }
}
