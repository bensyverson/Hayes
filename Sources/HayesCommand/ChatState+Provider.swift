import Foundation

extension ChatState {
    /// Resolves the Anthropic API key from the environment.
    ///
    /// Returns `nil` when `ANTHROPIC_API_KEY` is unset; ``start()`` surfaces
    /// a ``providerWarning`` in that case so the UI stays usable.
    static func resolveAnthropicKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["ANTHROPIC_API_KEY"], !key.isEmpty else { return nil }
        return key
    }
}
