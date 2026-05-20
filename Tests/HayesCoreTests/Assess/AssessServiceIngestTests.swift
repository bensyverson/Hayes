import Foundation
import GRDB
@testable import HayesCore
import Operator
import Testing

/// Covers the shared ``AssessService/ingest`` seam that both the live
/// assess path and the batch collector use to reinforce analyzed turns.
@Suite("AssessService.ingest")
struct AssessServiceIngestTests {
    @Test("ingest reinforces each lesson with provenance and advances progress")
    func reinforcesAndAdvances() async throws {
        let store = try GraphStore.inMemory()
        let service = AssessService(
            store: store,
            embeddings: FakeEmbeddingProvider(dimension: 64),
            analyzer: MockAnalyzer(results: []),
            backend: .anthropic(apiKey: "k")
        )

        let turns: [AssessService.AnalyzedTurn] = [
            AssessService.AnalyzedTurn(
                turnIndex: 3,
                lessons: [Lesson(seed: "yoga site", behavior: "calm palette", sentiment: 0.8, source: .user)],
                excerpt: nil
            ),
        ]
        let persisted = try await service.ingest(
            turns: turns,
            provenanceIdentity: "sess-1",
            progressIdentity: "sess-1",
            advanceProgressTo: 3
        )

        #expect(persisted.count == 1)
        #expect(persisted.first?.turnIndex == 3)
        #expect(try await store.assessProgress(for: "sess-1") == 3)

        let row = try await store.database.read { db in
            try Row.fetchOne(db, sql: "SELECT source_transcript, turn_index, source_excerpt FROM edges LIMIT 1")
        }
        let unwrapped = try #require(row)
        #expect(unwrapped["source_transcript"] as String? == "sess-1")
        #expect(unwrapped["turn_index"] as Int? == 3)
        #expect(unwrapped["source_excerpt"] as String? == nil)
    }

    @Test("ingest advances progress even when a turn produced no lessons")
    func advancesPastEmptyTurn() async throws {
        let store = try GraphStore.inMemory()
        let service = AssessService(
            store: store,
            embeddings: FakeEmbeddingProvider(dimension: 64),
            analyzer: MockAnalyzer(results: []),
            backend: .anthropic(apiKey: "k")
        )

        let persisted = try await service.ingest(
            turns: [AssessService.AnalyzedTurn(turnIndex: 2, lessons: [], excerpt: nil)],
            provenanceIdentity: "sess-1",
            progressIdentity: "sess-1",
            advanceProgressTo: 2
        )
        #expect(persisted.isEmpty)
        #expect(try await store.assessProgress(for: "sess-1") == 2)
    }

    @Test("ingest with nil progress identity reinforces but records no progress")
    func nilProgressIdentitySkipsAdvance() async throws {
        let store = try GraphStore.inMemory()
        let service = AssessService(
            store: store,
            embeddings: FakeEmbeddingProvider(dimension: 64),
            analyzer: MockAnalyzer(results: []),
            backend: .anthropic(apiKey: "k")
        )
        _ = try await service.ingest(
            turns: [AssessService.AnalyzedTurn(
                turnIndex: 0,
                lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.5, source: .user)],
                excerpt: nil
            )],
            provenanceIdentity: nil,
            progressIdentity: nil,
            advanceProgressTo: nil
        )
        #expect(try await store.assessProgress(for: "sess-1") == nil)
        let count = try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges") ?? -1
        }
        #expect(count == 1)
    }
}
