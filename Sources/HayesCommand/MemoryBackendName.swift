import ArgumentParser
import Foundation
import HayesCore

/// CLI-shaped name for a memory-stage backend, including the `none`
/// disable-this-stage sentinel used by ``RecallCommand/contextExtractor``.
///
/// `MemoryBackendName` is a thin user-facing wrapper for ``HayesCore/MemoryBackend``;
/// the actual ``HayesCore/MemoryBackend`` enum carries the Anthropic API
/// key and is constructed by ``resolveBackend(anthropicAPIKey:)`` once the
/// key is known.
enum MemoryBackendName: String, ExpressibleByArgument, CaseIterable {
    /// Apple's on-device Foundation Models.
    case afm
    /// Anthropic's API.
    case anthropic
    /// Disable this stage entirely. Only meaningful where the stage is
    /// optional (e.g. ``RecallCommand/contextExtractor``).
    case none

    /// Errors thrown by ``resolveBackend(anthropicAPIKey:)``.
    enum ResolveError: Error, Equatable, LocalizedError {
        /// ``anthropic`` was selected but no API key was supplied via
        /// flag or environment.
        case missingAnthropicAPIKey
        /// ``none`` cannot be resolved to a backend — the caller must
        /// branch on `.none` before invoking ``resolveBackend``.
        case cannotResolveNone

        var errorDescription: String? {
            switch self {
            case .missingAnthropicAPIKey:
                "Anthropic backend selected but ANTHROPIC_API_KEY is unset and --anthropic-api-key was not supplied."
            case .cannotResolveNone:
                "MemoryBackendName.none cannot be resolved to a concrete backend."
            }
        }
    }

    /// Resolves this name to a concrete ``HayesCore/MemoryBackend``.
    /// - Parameter anthropicAPIKey: The API key to use when this name is
    ///   ``anthropic``. May come from the `--anthropic-api-key` flag or
    ///   the `ANTHROPIC_API_KEY` environment variable.
    /// - Returns: The matching ``HayesCore/MemoryBackend``.
    /// - Throws: ``ResolveError/missingAnthropicAPIKey`` when
    ///   ``anthropic`` is selected without a key,
    ///   ``ResolveError/cannotResolveNone`` when called on ``none``.
    func resolveBackend(anthropicAPIKey: String?) throws -> MemoryBackend {
        switch self {
        case .afm:
            return .appleIntelligence
        case .anthropic:
            guard let key = anthropicAPIKey, !key.isEmpty else {
                throw ResolveError.missingAnthropicAPIKey
            }
            return .anthropic(apiKey: key)
        case .none:
            throw ResolveError.cannotResolveNone
        }
    }
}
