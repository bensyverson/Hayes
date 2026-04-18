import Accelerate
import Foundation

/// Computes the cosine similarity between two embedding vectors.
///
/// Uses Accelerate's `vDSP_dotpr` and `vDSP_svesq` for a fast, brute-force
/// implementation suitable for corpora below ~1000 vectors. Vectors must be the
/// same length; passing zero-magnitude vectors returns a `NaN` (cosine is
/// undefined at the origin).
///
/// - Parameters:
///   - a: The first vector.
///   - b: The second vector.
/// - Returns: Cosine similarity in `[-1.0, 1.0]`.
public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "cosineSimilarity requires vectors of equal length")
    var dotProduct: Float = 0.0
    var normA: Float = 0.0
    var normB: Float = 0.0
    let length = vDSP_Length(a.count)
    vDSP_dotpr(a, 1, b, 1, &dotProduct, length)
    vDSP_svesq(a, 1, &normA, length)
    vDSP_svesq(b, 1, &normB, length)
    return dotProduct / (sqrt(normA) * sqrt(normB))
}
