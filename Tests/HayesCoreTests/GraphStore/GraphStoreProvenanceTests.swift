import Foundation
import GRDB
@testable import HayesCore
import Testing

@Suite("GraphStore provenance threading")
struct GraphStoreProvenanceTests {
    @Test("insertEdge with provenance persists all three columns")
    func insertEdgeWritesProvenance() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])

        _ = try await store.insertEdge(
            sourceID: a.id,
            targetID: b.id,
            weight: 0.5,
            provenance: EdgeProvenance(
                sourceTranscript: "session-1",
                turnIndex: 3,
                sourceExcerpt: "the user said something"
            )
        )

        let row = try await readProvenance(in: store, source: a.id, target: b.id)
        #expect(row.sourceTranscript == "session-1")
        #expect(row.turnIndex == 3)
        #expect(row.sourceExcerpt == "the user said something")
    }

    @Test("insertEdge without provenance leaves the columns NULL")
    func insertEdgeOmittedProvenance() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])

        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.5)

        let row = try await readProvenance(in: store, source: a.id, target: b.id)
        #expect(row.sourceTranscript == nil)
        #expect(row.turnIndex == nil)
        #expect(row.sourceExcerpt == nil)
    }

    @Test("updateEdgeWeight with provenance overwrites the stored values")
    func updateEdgeWritesProvenance() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(
            sourceID: a.id,
            targetID: b.id,
            weight: 0.5,
            provenance: EdgeProvenance(
                sourceTranscript: "old",
                turnIndex: 1,
                sourceExcerpt: "stale"
            )
        )

        try await store.updateEdgeWeight(
            sourceID: a.id,
            targetID: b.id,
            weight: 0.7,
            provenance: EdgeProvenance(
                sourceTranscript: "fresh",
                turnIndex: 9,
                sourceExcerpt: "latest"
            )
        )

        let row = try await readProvenance(in: store, source: a.id, target: b.id)
        #expect(row.sourceTranscript == "fresh")
        #expect(row.turnIndex == 9)
        #expect(row.sourceExcerpt == "latest")
    }

    @Test("updateEdgeWeight without provenance leaves existing provenance intact")
    func updateEdgeOmittedProvenanceKeepsExisting() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(
            sourceID: a.id,
            targetID: b.id,
            weight: 0.5,
            provenance: EdgeProvenance(
                sourceTranscript: "keep",
                turnIndex: 4,
                sourceExcerpt: "still here"
            )
        )

        try await store.updateEdgeWeight(sourceID: a.id, targetID: b.id, weight: 0.6)

        let row = try await readProvenance(in: store, source: a.id, target: b.id)
        #expect(row.sourceTranscript == "keep")
        #expect(row.turnIndex == 4)
        #expect(row.sourceExcerpt == "still here")
    }

    @Test("reinforceEdge threads provenance through the insert path")
    func reinforceEdgeInsertPath() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])

        try await store.reinforceEdge(
            seedID: a.id,
            behaviorID: b.id,
            sentiment: 1.0,
            sourceScale: 1.0,
            provenance: EdgeProvenance(
                sourceTranscript: "sess",
                turnIndex: 2,
                sourceExcerpt: "user feedback"
            )
        )

        let row = try await readProvenance(in: store, source: a.id, target: b.id)
        #expect(row.sourceTranscript == "sess")
        #expect(row.turnIndex == 2)
        #expect(row.sourceExcerpt == "user feedback")
    }

    @Test("reinforceEdge threads provenance through the update path")
    func reinforceEdgeUpdatePath() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])
        _ = try await store.insertEdge(sourceID: a.id, targetID: b.id, weight: 0.3)

        try await store.reinforceEdge(
            seedID: a.id,
            behaviorID: b.id,
            sentiment: 1.0,
            sourceScale: 1.0,
            provenance: EdgeProvenance(
                sourceTranscript: "later",
                turnIndex: 12,
                sourceExcerpt: "thanks"
            )
        )

        let row = try await readProvenance(in: store, source: a.id, target: b.id)
        #expect(row.sourceTranscript == "later")
        #expect(row.turnIndex == 12)
        #expect(row.sourceExcerpt == "thanks")
    }

    @Test("a provenance value with only turn_index records that and nulls identity")
    func turnOnlyProvenance() async throws {
        let store = try GraphStore.inMemory()
        let a = try await store.insertNode(text: "a", embedding: [0.0])
        let b = try await store.insertNode(text: "b", embedding: [0.0])

        _ = try await store.insertEdge(
            sourceID: a.id,
            targetID: b.id,
            weight: 0.4,
            provenance: EdgeProvenance(sourceTranscript: nil, turnIndex: 5, sourceExcerpt: nil)
        )

        let row = try await readProvenance(in: store, source: a.id, target: b.id)
        #expect(row.sourceTranscript == nil)
        #expect(row.turnIndex == 5)
        #expect(row.sourceExcerpt == nil)
    }

    // MARK: - Helpers

    private struct ProvenanceRow {
        let sourceTranscript: String?
        let turnIndex: Int?
        let sourceExcerpt: String?
    }

    private func readProvenance(
        in store: GraphStore,
        source: String,
        target: String
    ) async throws -> ProvenanceRow {
        let row = try await store.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT source_transcript, turn_index, source_excerpt
                FROM edges WHERE source_id = ? AND target_id = ?
                """,
                arguments: [source, target]
            )
        }
        let unwrapped = try #require(row)
        return ProvenanceRow(
            sourceTranscript: unwrapped["source_transcript"] as String?,
            turnIndex: unwrapped["turn_index"] as Int?,
            sourceExcerpt: unwrapped["source_excerpt"] as String?
        )
    }
}
