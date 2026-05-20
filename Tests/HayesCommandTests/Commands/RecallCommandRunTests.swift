import Foundation
@testable import HayesCommand
import Testing

@Suite("RecallCommand run path")
struct RecallCommandRunTests {
    @Test("missing transcript file is tolerated (first-turn-of-session case)")
    func missingTranscriptIsTolerated() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hayes-recall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("graph.sqlite").path
        let nonExistent = tmpDir.appendingPathComponent("missing-session.jsonl").path

        var cmd = try RecallCommand.parse([
            nonExistent,
            "--db", dbPath,
            "--context-extractor", "none",
        ])
        try await cmd.run()
    }

    @Test("missing transcript with --prompt recalls from the prompt (turn-1 case)")
    func missingTranscriptWithPromptRuns() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hayes-recall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("graph.sqlite").path
        let nonExistent = tmpDir.appendingPathComponent("missing-session.jsonl").path

        // The transcript doesn't exist yet (fresh session), but the harness
        // supplied the in-flight prompt — recall should run the full pipeline
        // from it rather than bailing.
        var cmd = try RecallCommand.parse([
            nonExistent,
            "--db", dbPath,
            "--context-extractor", "none",
            "--prompt", "what changed in the build?",
        ])
        try await cmd.run()
    }
}
