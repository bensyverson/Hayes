/// The LLM backend powering a memory stage (``ContextExtractor`` or
/// ``AnalysisRunner``).
///
/// Hayes intentionally lets each stage pick its backend independently so
/// we can A/B privacy-preserving on-device inference against cloud
/// frontier models without coupling the two decisions.
///
/// Not ``Friendly``-conforming: the Anthropic case embeds a raw API key,
/// so we deliberately exclude `Codable` to keep credentials off disk.
public enum MemoryBackend: Sendable, Hashable {
    /// Apple's on-device Foundation Models. Requires macOS 26+ and
    /// Apple Intelligence–enabled hardware.
    case appleIntelligence
    /// Anthropic's API with the given key.
    case anthropic(apiKey: String)
}
