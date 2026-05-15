import ArgumentParser
@testable import HayesCommand
import Testing

@Suite("CommonOptions")
struct CommonOptionsTests {
    @Test("default --db is nil (resolved to the default path later)")
    func defaultDB() throws {
        let args = try CommonOptions.parse([])
        #expect(args.db == nil)
    }

    @Test("explicit --db is captured verbatim")
    func explicitDB() throws {
        let args = try CommonOptions.parse(["--db", "/tmp/foo.sqlite"])
        #expect(args.db == "/tmp/foo.sqlite")
    }

    @Test("backend flags default to afm extractor and anthropic analyzer")
    func backendDefaults() throws {
        let args = try CommonOptions.parse([])
        #expect(args.contextBackend == .afm)
        #expect(args.analyzerBackend == .anthropic)
    }

    @Test("backend flags accept overrides")
    func backendOverrides() throws {
        let args = try CommonOptions.parse([
            "--context-backend", "anthropic",
            "--analyzer-backend", "afm",
        ])
        #expect(args.contextBackend == .anthropic)
        #expect(args.analyzerBackend == .afm)
    }
}
