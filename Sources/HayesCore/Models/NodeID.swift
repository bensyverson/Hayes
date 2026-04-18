import Foundation

/// Generator for short, random node identifiers.
///
/// Node IDs are 6-character strings drawn uniformly from a 62-character alphabet
/// (`a-z`, `A-Z`, `0-9`). Collisions are statistically negligible at the scale
/// we operate at, but ``GraphStore`` retries on primary-key conflicts.
public enum NodeID {
    /// The 62-character alphabet used to generate node identifiers.
    public static let alphabet: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    private static let alphabetChars: [Character] = Array(alphabet)

    /// Generates a new random 6-character node identifier.
    /// - Returns: A fresh random identifier drawn from ``alphabet``.
    public static func make() -> String {
        String((0 ..< 6).map { _ in alphabetChars.randomElement()! })
    }
}
