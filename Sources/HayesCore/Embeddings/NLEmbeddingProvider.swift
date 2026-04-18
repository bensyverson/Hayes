import Foundation
import NaturalLanguage

/// An ``EmbeddingProvider`` backed by Apple's `NLEmbedding` English sentence model.
///
/// Produces 512-dimensional vectors locally, no network required. If the English
/// sentence embedding is unavailable on the current OS configuration, the
/// initializer throws ``UnavailableError``.
///
/// `NLEmbeddingProvider` is a `final class` marked `@unchecked Sendable`. Its only
/// stored state is the immutable `NLEmbedding` model, which Apple documents as
/// safe for concurrent reads.
public final class NLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    /// Raised when the underlying `NLEmbedding` model is not available.
    public struct UnavailableError: Error, Sendable {
        /// Creates a new error.
        public init() {}
    }

    /// Raised when a specific phrase cannot be embedded.
    public struct EmbeddingFailedError: Error, Sendable {
        /// The phrase that could not be embedded.
        public let text: String
        /// Creates a new error.
        /// - Parameter text: The phrase that could not be embedded.
        public init(text: String) {
            self.text = text
        }
    }

    private let embedding: NLEmbedding

    /// The vector dimensionality (typically 512 for `NLEmbedding.sentenceEmbedding(for: .english)`).
    public let dimension: Int

    /// Creates a new provider backed by the English sentence embedding model.
    /// - Throws: ``UnavailableError`` if the model is not available.
    public init() throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw NLEmbeddingProvider.UnavailableError()
        }
        self.embedding = embedding
        dimension = embedding.dimension
    }

    /// Embeds `text` into a fixed-length vector.
    /// - Parameter text: The input phrase.
    /// - Returns: A vector of length ``dimension``.
    /// - Throws: ``EmbeddingFailedError`` if the underlying model returns no vector.
    public func embed(_ text: String) throws -> [Float] {
        guard let vector = embedding.vector(for: text) else {
            throw NLEmbeddingProvider.EmbeddingFailedError(text: text)
        }
        return vector.map { Float($0) }
    }
}
