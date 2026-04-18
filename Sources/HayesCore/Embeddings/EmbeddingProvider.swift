/// A source of text embeddings.
///
/// Hayes uses an `EmbeddingProvider` to turn phrases into fixed-length vectors.
/// The default implementation is ``NLEmbeddingProvider``, which wraps Apple's
/// `NLEmbedding` with the English sentence model.
public protocol EmbeddingProvider: Sendable {
    /// The dimensionality of vectors this provider produces.
    var dimension: Int { get }

    /// Embeds `text` into a fixed-length vector.
    /// - Parameter text: The input phrase.
    /// - Returns: A vector of length ``dimension``.
    /// - Throws: If the text cannot be embedded.
    func embed(_ text: String) throws -> [Float]
}
