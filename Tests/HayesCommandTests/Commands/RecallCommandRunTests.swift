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
}
