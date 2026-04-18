import Foundation
@testable import HayesCore

/// A deterministic embedding provider for middleware tests.
///
/// Each unique phrase gets a fresh one-hot unit vector in a fixed-dimension
/// space, so cosine similarities are exactly 0.0 or 1.0 and retrieval /
/// dedup thresholds fire predictably.
///
/// Phrases that compare equal (case-insensitive, whitespace-trimmed) reuse
/// the same vector, so the dedup path can be exercised.
final class FakeEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    let dimension: Int
    private let lock = NSLock()
    private var assignments: [String: Int] = [:]

    init(dimension: Int = 64) {
        self.dimension = dimension
    }

    func embed(_ text: String) throws -> [Float] {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        lock.lock()
        let index: Int
        if let existing = assignments[key] {
            index = existing
        } else {
            index = assignments.count
            assignments[key] = index
        }
        lock.unlock()
        guard index < dimension else {
            fatalError("FakeEmbeddingProvider exhausted (dimension=\(dimension))")
        }
        var vector = [Float](repeating: 0, count: dimension)
        vector[index] = 1
        return vector
    }
}
