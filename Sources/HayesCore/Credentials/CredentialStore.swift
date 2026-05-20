/// A minimal read/write store for named secrets such as API keys.
///
/// `CredentialStore` is the seam that lets credential resolution be exercised
/// without touching the real macOS Keychain: production code uses
/// ``KeychainCredentialStore``, while tests use an in-memory double. The
/// methods are synchronous and throwing to match the underlying Keychain API.
/// A missing key is modeled as `nil` on read (and a no-op on removal) rather
/// than an error, so "no credential yet" is an ordinary outcome.
public protocol CredentialStore: Sendable {
    /// Returns the stored secret for `key`, or `nil` when none is stored.
    /// - Parameter key: The account name the secret was stored under.
    /// - Returns: The stored secret, or `nil` when the key is absent.
    /// - Throws: An error only when the lookup itself fails — never merely
    ///   because the key is absent.
    func value(for key: String) throws -> String?

    /// Stores `value` for `key`, overwriting any existing secret.
    /// - Parameters:
    ///   - value: The secret to persist.
    ///   - key: The account name to store it under.
    /// - Throws: An error when the write fails.
    func store(_ value: String, for key: String) throws

    /// Removes any secret stored for `key`.
    ///
    /// Removing a key that isn't present succeeds silently, so callers can
    /// treat removal as idempotent.
    /// - Parameter key: The account name to clear.
    /// - Throws: An error when the deletion fails for a reason other than the
    ///   key being absent.
    func remove(for key: String) throws
}
