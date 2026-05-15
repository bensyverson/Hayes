import ArgumentParser
@testable import HayesCommand
import HayesCore
import Testing

@Suite("MemoryBackendName")
struct MemoryBackendNameTests {
    @Test("parses afm, anthropic, none")
    func parsesAll() {
        #expect(MemoryBackendName(argument: "afm") == .afm)
        #expect(MemoryBackendName(argument: "anthropic") == .anthropic)
        #expect(MemoryBackendName(argument: "none") == MemoryBackendName.none)
    }

    @Test("rejects unknown values")
    func rejectsUnknown() {
        #expect(MemoryBackendName(argument: "openai") == nil)
    }

    @Test("resolve(.afm) returns .appleIntelligence")
    func resolveAFM() throws {
        let backend = try MemoryBackendName.afm.resolveBackend(anthropicAPIKey: nil)
        #expect(backend == .appleIntelligence)
    }

    @Test("resolve(.anthropic, key) returns .anthropic(key)")
    func resolveAnthropicWithKey() throws {
        let backend = try MemoryBackendName.anthropic.resolveBackend(anthropicAPIKey: "sk-test")
        #expect(backend == .anthropic(apiKey: "sk-test"))
    }

    @Test("resolve(.anthropic, nil) throws missingAnthropicAPIKey")
    func resolveAnthropicMissingKey() {
        #expect(throws: MemoryBackendName.ResolveError.missingAnthropicAPIKey) {
            _ = try MemoryBackendName.anthropic.resolveBackend(anthropicAPIKey: nil)
        }
    }

    @Test("resolve(.none) throws cannotResolveNone")
    func resolveNone() {
        #expect(throws: MemoryBackendName.ResolveError.cannotResolveNone) {
            _ = try MemoryBackendName.none.resolveBackend(anthropicAPIKey: "sk-test")
        }
    }
}
