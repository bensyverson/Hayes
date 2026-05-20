import Foundation
import KeyManager

/// A ``CredentialStore`` backed by the macOS Keychain via `KeyManager`.
///
/// This is the production credential store. It holds only the Keychain service
/// name — a `String`, so the type stays `Sendable` even though `KeyManager`
/// itself isn't — and reaches the Keychain through `KeyManager`'s static API.
/// A `KeyManager.KeyError.notFound` is translated into `nil` on read and a
/// no-op on removal, so "no credential yet" and "already gone" are ordinary
/// successes rather than thrown errors.
public struct KeychainCredentialStore: CredentialStore {
    /// The Keychain service under which secrets are grouped.
    public let service: String

    /// Creates a store for the given Keychain service.
    /// - Parameter service: The Keychain service name. Defaults to
    ///   ``HayesCredential/service``.
    public init(service: String = HayesCredential.service) {
        self.service = service
    }

    public func value(for key: String) throws -> String? {
        do {
            return try KeyManager.value(for: key, service: service)
        } catch KeyManager.KeyError.notFound {
            return nil
        }
    }

    public func store(_ value: String, for key: String) throws {
        try KeyManager.store(key: key, value: value, service: service, shouldUpdate: true)
    }

    public func remove(for key: String) throws {
        do {
            try KeyManager.remove(key: key, service: service)
        } catch KeyManager.KeyError.notFound {
            // Removing an absent key is a no-op so removal is idempotent.
        }
    }
}
