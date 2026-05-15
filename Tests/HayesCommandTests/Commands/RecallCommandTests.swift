import ArgumentParser
import Foundation
@testable import HayesCommand
import HayesCore
import Testing

@Suite("RecallCommand parsing")
struct RecallCommandParsingTests {
    @Test("requires a positional transcript path")
    func requiresTranscriptPath() {
        #expect(throws: (any Error).self) {
            _ = try RecallCommand.parse([])
        }
    }

    @Test("accepts a positional transcript path")
    func acceptsTranscriptPath() throws {
        let cmd = try RecallCommand.parse(["/tmp/transcript.jsonl"])
        #expect(cmd.transcript == "/tmp/transcript.jsonl")
    }

    @Test("defaults: window=5, dry-run=false, store-injection=true, json=false, context-extractor=afm")
    func defaults() throws {
        let cmd = try RecallCommand.parse(["/tmp/t.jsonl"])
        #expect(cmd.window == 5)
        #expect(cmd.dryRun == false)
        #expect(cmd.storeInjection == true)
        #expect(cmd.json == false)
        #expect(cmd.contextExtractor == .afm)
        #expect(cmd.sessionID == nil)
    }

    @Test("--session-id is captured")
    func sessionIDOverride() throws {
        let cmd = try RecallCommand.parse(["/tmp/t.jsonl", "--session-id", "abc-123"])
        #expect(cmd.sessionID == "abc-123")
    }

    @Test("--window is captured")
    func windowOverride() throws {
        let cmd = try RecallCommand.parse(["/tmp/t.jsonl", "--window", "12"])
        #expect(cmd.window == 12)
    }

    @Test("--dry-run flag")
    func dryRunFlag() throws {
        let cmd = try RecallCommand.parse(["/tmp/t.jsonl", "--dry-run"])
        #expect(cmd.dryRun)
    }

    @Test("--no-store-injection flag")
    func noStoreInjectionFlag() throws {
        let cmd = try RecallCommand.parse(["/tmp/t.jsonl", "--no-store-injection"])
        #expect(cmd.storeInjection == false)
    }

    @Test("--json flag")
    func jsonFlag() throws {
        let cmd = try RecallCommand.parse(["/tmp/t.jsonl", "--json"])
        #expect(cmd.json)
    }

    @Test("--context-extractor accepts afm|anthropic|none")
    func contextExtractorChoices() throws {
        for choice: MemoryBackendName in [.afm, .anthropic, .none] {
            let cmd = try RecallCommand.parse([
                "/tmp/t.jsonl", "--context-extractor", choice.rawValue,
            ])
            #expect(cmd.contextExtractor == choice)
        }
    }
}

@Suite("RecallCommand helpers")
struct RecallCommandHelpersTests {
    @Test("defaultSessionID(for:) returns the basename without extension")
    func sessionIDFromBasename() {
        let url = URL(fileURLWithPath: "/some/dir/abc-123-uuid.jsonl")
        #expect(RecallCommand.defaultSessionID(for: url) == "abc-123-uuid")
    }

    @Test("defaultSessionID(for:) handles files with no extension")
    func sessionIDNoExtension() {
        let url = URL(fileURLWithPath: "/some/dir/session")
        #expect(RecallCommand.defaultSessionID(for: url) == "session")
    }

    @Test("resolvedOptions reflects flag values")
    func resolvedOptions() throws {
        let cmd = try RecallCommand.parse([
            "/tmp/t.jsonl", "--window", "9", "--dry-run", "--no-store-injection",
        ])
        let options = cmd.resolvedOptions()
        #expect(options.windowSize == 9)
        #expect(options.dryRun == true)
        #expect(options.storeInjection == false)
    }

    @Test("renderPlaintext emits one tab-separated pair per surfaced row")
    func renderPlaintext() {
        let result = RecallResult(
            phrases: ["query phrase"],
            surfaced: [
                .init(
                    seedID: "s1", seedText: "wellness brand",
                    seedSimilarity: 0.82,
                    behaviorID: "b1", behaviorText: "use calm minimal palette",
                    edgeWeight: 0.71
                ),
            ],
            skipped: []
        )
        let text = RecallCommand.renderPlaintext(result, dryRun: false)
        // Each surfaced pair appears as a single line: seedText → behaviorText
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains("wellness brand → use calm minimal palette"))
    }

    @Test("renderPlaintext emits empty string when nothing surfaced and not dry-run")
    func renderPlaintextEmpty() {
        let result = RecallResult.empty
        let text = RecallCommand.renderPlaintext(result, dryRun: false)
        #expect(text.isEmpty)
    }

    @Test("renderPlaintext under --dry-run lists skipped pairs with reasons")
    func renderPlaintextDryRun() {
        let result = RecallResult(
            phrases: ["query phrase"],
            surfaced: [],
            skipped: [
                .init(
                    seedID: "s1", seedText: "wellness brand",
                    behaviorID: "b1", behaviorText: "use calm minimal palette",
                    reason: .alreadyInjectedThisSession
                ),
            ]
        )
        let text = RecallCommand.renderPlaintext(result, dryRun: true)
        #expect(text.contains("wellness brand → use calm minimal palette"))
        #expect(text.contains("alreadyInjectedThisSession"))
    }

    @Test("renderJSON returns a JSON object with phrases, surfaced, skipped")
    func renderJSONShape() throws {
        let result = RecallResult(
            phrases: ["a phrase"],
            surfaced: [
                .init(
                    seedID: "s1", seedText: "seed",
                    seedSimilarity: 0.5,
                    behaviorID: "b1", behaviorText: "behavior",
                    edgeWeight: 0.4
                ),
            ],
            skipped: []
        )
        let json = try RecallCommand.renderJSON(result)
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Issue.record("expected a top-level JSON object")
            return
        }
        #expect((object["phrases"] as? [String]) == ["a phrase"])
        let surfaced = object["surfaced"] as? [[String: Any]]
        #expect(surfaced?.count == 1)
        #expect(surfaced?.first?["seedText"] as? String == "seed")
        #expect((object["skipped"] as? [[String: Any]])?.isEmpty == true)
    }
}
