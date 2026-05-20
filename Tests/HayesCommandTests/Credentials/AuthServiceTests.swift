import Foundation
@testable import HayesCommand
import HayesCore
import Testing

@Suite("AuthService")
struct AuthServiceTests {
    @Test("store persists the trimmed secret")
    func storePersists() throws {
        let store = InMemoryCredentialStore()
        try AuthService.store(secret: "  sk-test  ", in: store)
        #expect(try store.value(for: HayesCredential.anthropicAPIKey) == "sk-test")
    }

    @Test("store rejects an empty or whitespace-only secret")
    func storeRejectsEmpty() {
        let store = InMemoryCredentialStore()
        #expect(throws: AuthService.AuthError.emptySecret) {
            try AuthService.store(secret: "   \n", in: store)
        }
    }

    @Test("clear removes a stored key")
    func clearRemoves() throws {
        let store = InMemoryCredentialStore()
        try store.store("sk-test", for: HayesCredential.anthropicAPIKey)
        try AuthService.clear(in: store)
        #expect(try store.value(for: HayesCredential.anthropicAPIKey) == nil)
    }

    @Test("clear is idempotent when nothing is stored")
    func clearIdempotent() {
        let store = InMemoryCredentialStore()
        #expect(throws: Never.self) { try AuthService.clear(in: store) }
    }

    @Test("status resolves to environment when the env var is set")
    func statusEnvironment() throws {
        let store = InMemoryCredentialStore()
        try store.store("sk-stored", for: HayesCredential.anthropicAPIKey)
        let report = try AuthService.statusReport(
            environment: ["ANTHROPIC_API_KEY": "sk-env"],
            store: store
        )
        #expect(report.environmentHasKey)
        #expect(report.keychainHasKey)
        #expect(report.resolvedSource == .environment)
    }

    @Test("status resolves to keychain when only the keychain has a key")
    func statusKeychain() throws {
        let store = InMemoryCredentialStore()
        try store.store("sk-stored", for: HayesCredential.anthropicAPIKey)
        let report = try AuthService.statusReport(environment: [:], store: store)
        #expect(!report.environmentHasKey)
        #expect(report.resolvedSource == .keychain)
    }

    @Test("status resolves to none, treating an empty env var as unset")
    func statusNone() throws {
        let store = InMemoryCredentialStore()
        let report = try AuthService.statusReport(
            environment: ["ANTHROPIC_API_KEY": ""],
            store: store
        )
        #expect(report.resolvedSource == .none)
    }

    @Test("status report renders without revealing the secret")
    func statusRenderNoSecret() throws {
        let store = InMemoryCredentialStore()
        try store.store("sk-super-secret", for: HayesCredential.anthropicAPIKey)
        let report = try AuthService.statusReport(environment: [:], store: store)
        let rendered = AuthService.render(report)
        #expect(!rendered.contains("sk-super-secret"))
        #expect(rendered.contains("Keychain"))
    }
}
