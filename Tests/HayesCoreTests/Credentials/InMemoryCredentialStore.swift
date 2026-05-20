import Foundation
@testable import HayesCore
import Synchronization

/// An in-memory ``CredentialStore`` double for exercising credential logic
/// without touching the real macOS Keychain. Backed by a `Mutex` so it stays
/// `Sendable` like the protocol it conforms to.
final class InMemoryCredentialStore: CredentialStore {
    private let storage: Mutex<[String: String]> = .init([:])

    init() {}

    func value(for key: String) throws -> String? {
        storage.withLock { $0[key] }
    }

    func store(_ value: String, for key: String) throws {
        storage.withLock { $0[key] = value }
    }

    func remove(for key: String) throws {
        storage.withLock { $0[key] = nil }
    }
}
