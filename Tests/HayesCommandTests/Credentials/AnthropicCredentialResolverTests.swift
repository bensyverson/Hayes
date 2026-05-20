import Foundation
@testable import HayesCommand
import HayesCore
import Testing

@Suite("AnthropicCredentialResolver")
struct AnthropicCredentialResolverTests {
    @Test("flag wins over env and store")
    func flagWins() throws {
        let store = InMemoryCredentialStore()
        try store.store("storekey", for: HayesCredential.anthropicAPIKey)
        let key = try AnthropicCredentialResolver.resolve(
            flag: "flagkey",
            environment: ["ANTHROPIC_API_KEY": "envkey"],
            store: store
        )
        #expect(key == "flagkey")
    }

    @Test("env wins over store when no flag")
    func envWins() throws {
        let store = InMemoryCredentialStore()
        try store.store("storekey", for: HayesCredential.anthropicAPIKey)
        let key = try AnthropicCredentialResolver.resolve(
            flag: nil,
            environment: ["ANTHROPIC_API_KEY": "envkey"],
            store: store
        )
        #expect(key == "envkey")
    }

    @Test("store is used when no flag or env")
    func storeUsed() throws {
        let store = InMemoryCredentialStore()
        try store.store("storekey", for: HayesCredential.anthropicAPIKey)
        let key = try AnthropicCredentialResolver.resolve(
            flag: nil,
            environment: [:],
            store: store
        )
        #expect(key == "storekey")
    }

    @Test("returns nil when no source supplies a key")
    func allEmpty() throws {
        let store = InMemoryCredentialStore()
        let key = try AnthropicCredentialResolver.resolve(
            flag: nil,
            environment: [:],
            store: store
        )
        #expect(key == nil)
    }

    @Test("empty flag falls through to env")
    func emptyFlagFallsThrough() throws {
        let store = InMemoryCredentialStore()
        let key = try AnthropicCredentialResolver.resolve(
            flag: "",
            environment: ["ANTHROPIC_API_KEY": "envkey"],
            store: store
        )
        #expect(key == "envkey")
    }

    @Test("empty env falls through to store")
    func emptyEnvFallsThrough() throws {
        let store = InMemoryCredentialStore()
        try store.store("storekey", for: HayesCredential.anthropicAPIKey)
        let key = try AnthropicCredentialResolver.resolve(
            flag: nil,
            environment: ["ANTHROPIC_API_KEY": ""],
            store: store
        )
        #expect(key == "storekey")
    }
}
