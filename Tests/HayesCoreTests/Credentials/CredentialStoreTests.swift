import Foundation
@testable import HayesCore
import Testing

@Suite("InMemoryCredentialStore")
struct CredentialStoreTests {
    @Test("stores then reads back a value")
    func storeThenRead() throws {
        let store = InMemoryCredentialStore()
        try store.store("secret", for: "k")
        #expect(try store.value(for: "k") == "secret")
    }

    @Test("overwrites an existing value")
    func overwrite() throws {
        let store = InMemoryCredentialStore()
        try store.store("first", for: "k")
        try store.store("second", for: "k")
        #expect(try store.value(for: "k") == "second")
    }

    @Test("returns nil for a missing key")
    func readMissing() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.value(for: "absent") == nil)
    }

    @Test("removes a stored value")
    func removeStored() throws {
        let store = InMemoryCredentialStore()
        try store.store("secret", for: "k")
        try store.remove(for: "k")
        #expect(try store.value(for: "k") == nil)
    }

    @Test("removing a missing key is a no-op")
    func removeMissing() {
        let store = InMemoryCredentialStore()
        #expect(throws: Never.self) { try store.remove(for: "absent") }
    }
}
