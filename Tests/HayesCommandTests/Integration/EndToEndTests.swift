import Foundation
import HayesCommand
@testable import HayesCore
import Operator
import Testing

/// End-to-end wiring test for the CLI service layer.
///
/// The CLI subcommands themselves are thin shells around the
/// `HayesCore` services (``AssessService``, ``RecallService``,
/// ``GraphStore``), so this test exercises that composition directly:
/// load a real CC JSONL transcript through ``TranscriptLoader``, drive
/// `AssessService` with a canned ``Analyzing`` (so we don't need a
/// real LLM in CI), then run `RecallService` over a follow-up
/// transcript and verify the dedup + provenance round-trip the
/// introspection commands rely on.
@Suite("End-to-end CLI service composition")
struct EndToEndTests {
    @Test("assess + recall + dedup + provenance round-trip")
    func assessRecallDedup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hayes-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let assessTranscript = directory.appendingPathComponent("assess-session.jsonl")
        try Self.writeJSONL([
            #"{"type":"user","message":{"role":"user","content":"design a website for a wellness brand"},"sessionId":"assess-session","uuid":"u1"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]},"sessionId":"assess-session","uuid":"a1"}"#,
        ], to: assessTranscript)

        let recallTranscript = directory.appendingPathComponent("recall-session.jsonl")
        try Self.writeJSONL([
            #"{"type":"user","message":{"role":"user","content":"design a website for a wellness brand"},"sessionId":"recall-session","uuid":"u2"}"#,
        ], to: recallTranscript)

        let dbURL = directory.appendingPathComponent("graph.sqlite")
        let store = try GraphStore(path: dbURL)
        let embeddings = try NLEmbeddingProvider()
        let loader = TranscriptLoader()

        // Lower the edge-weight floor so a single canned reinforcement
        // clears retrieval — defaults aim at a populated graph, not a
        // single-edge fixture.
        let config = RetrievalConfig(minEdgeWeight: 0.01)

        // Run assess with a canned analyzer so the test doesn't need a
        // real LLM. The canned lesson is keyed off the seed/behavior text
        // we'll later expect to surface in recall.
        let canned = CannedAnalyzer(lessons: [
            Lesson(
                seed: "wellness brand website",
                behavior: "use a calm minimal palette",
                sentiment: 0.8,
                source: .user
            ),
        ])
        let assessService = AssessService(
            store: store,
            embeddings: embeddings,
            analyzer: canned,
            backend: .appleIntelligence,
            config: config
        )
        let assessMessages = try await loader.load(path: assessTranscript)
        let transcriptIdentity = assessTranscript.deletingPathExtension().lastPathComponent
        let assessResult = try await assessService.assess(
            messages: assessMessages,
            transcriptIdentity: transcriptIdentity,
            options: AssessOptions(strategy: .parallel(concurrency: 1), storeSource: true)
        )
        #expect(assessResult.lessons.count == 1)
        let seedID = try #require(assessResult.lessons.first?.seedID)
        let behaviorID = try #require(assessResult.lessons.first?.behaviorID)

        // Provenance must have made it onto the edge so `hayes inspect`
        // can render it.
        let edgeAfterAssess = try await store.findEdge(sourceID: seedID, targetID: behaviorID)
        #expect(edgeAfterAssess?.provenance?.sourceTranscript == transcriptIdentity)

        // Recall (no extractor) against a follow-up transcript should
        // surface the assessed pair.
        let recallService = RecallService(
            store: store,
            embeddings: embeddings,
            extractor: nil,
            config: config
        )
        let recallMessages = try await loader.load(path: recallTranscript)
        let recallSessionID = recallTranscript.deletingPathExtension().lastPathComponent

        let firstPass = try await recallService.recall(
            messages: recallMessages,
            sessionID: recallSessionID
        )
        #expect(firstPass.surfaced.count == 1)
        #expect(firstPass.surfaced.first?.seedID == seedID)
        #expect(firstPass.surfaced.first?.behaviorID == behaviorID)

        // Re-running in the same session must dedup (no new surfaced pairs).
        let secondPass = try await recallService.recall(
            messages: recallMessages,
            sessionID: recallSessionID
        )
        #expect(secondPass.surfaced.isEmpty)

        // session show should record the injection trail.
        let trail = try await store.injectionsInSession(recallSessionID)
        #expect(trail.count == 1)
        #expect(trail.first?.sourceID == seedID)
        #expect(trail.first?.targetID == behaviorID)
    }

    /// Writes one JSON object per line to `url`.
    private static func writeJSONL(_ lines: [String], to url: URL) throws {
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Canned `Analyzing` implementation that returns a fixed list of
/// lessons for every call. Used by the end-to-end test in place of an
/// `AnalysisRunner` so CI doesn't depend on a real LLM backend.
private struct CannedAnalyzer: Analyzing {
    let lessons: [Lesson]

    func analyze(
        messages _: [Operator.Message],
        thinking _: String
    ) async throws -> AnalysisResult {
        AnalysisResult(lessons: lessons)
    }
}
