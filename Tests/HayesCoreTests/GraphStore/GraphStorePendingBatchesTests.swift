import Foundation
import GRDB
@testable import HayesCore
import Testing

@Suite("GraphStore pending batches")
struct GraphStorePendingBatchesTests {
    @Test("pending_batches table has the expected columns, PK, and unique transcript")
    func tableShape() throws {
        let store = try GraphStore.inMemory()
        let columns = try store.database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(pending_batches)")
        }
        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0["name"] as String, $0) })

        let batchID = try #require(byName["batch_id"])
        #expect(batchID["type"] as String == "TEXT")
        #expect(batchID["notnull"] as Int == 1)
        #expect(batchID["pk"] as Int == 1)

        let transcript = try #require(byName["transcript"])
        #expect(transcript["type"] as String == "TEXT")
        #expect(transcript["notnull"] as Int == 1)

        #expect(try #require(byName["min_turn"])["type"] as String == "INTEGER")
        #expect(try #require(byName["max_turn"])["type"] as String == "INTEGER")
        #expect(try #require(byName["submitted_at"])["type"] as String == "REAL")

        // transcript is unique
        let indexes = try store.database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list(pending_batches)")
        }
        #expect(indexes.contains { ($0["unique"] as Int) == 1 })
    }

    @Test("insert then lookup by transcript round-trips the record")
    func insertRoundTrips() async throws {
        let store = try GraphStore.inMemory()
        try await store.insertPendingBatch(batchID: "msgbatch_1", transcript: "sess-1", minTurn: 2, maxTurn: 5)

        let found = try #require(try await store.pendingBatch(forTranscript: "sess-1"))
        #expect(found.batchID == "msgbatch_1")
        #expect(found.transcript == "sess-1")
        #expect(found.minTurn == 2)
        #expect(found.maxTurn == 5)
        #expect(found.submittedAt.timeIntervalSince1970 > 0)
    }

    @Test("pendingBatch(forTranscript:) returns nil for an unknown transcript")
    func lookupUnknownIsNil() async throws {
        let store = try GraphStore.inMemory()
        #expect(try await store.pendingBatch(forTranscript: "nope") == nil)
    }

    @Test("a transcript can have at most one in-flight batch")
    func transcriptIsUnique() async throws {
        let store = try GraphStore.inMemory()
        try await store.insertPendingBatch(batchID: "msgbatch_1", transcript: "sess-1", minTurn: 0, maxTurn: 1)
        await #expect(throws: (any Error).self) {
            try await store.insertPendingBatch(batchID: "msgbatch_2", transcript: "sess-1", minTurn: 2, maxTurn: 3)
        }
    }

    @Test("pendingBatches returns every in-flight batch")
    func listAll() async throws {
        let store = try GraphStore.inMemory()
        try await store.insertPendingBatch(batchID: "b1", transcript: "sess-1", minTurn: 0, maxTurn: 1)
        try await store.insertPendingBatch(batchID: "b2", transcript: "sess-2", minTurn: 0, maxTurn: 2)

        let all = try await store.pendingBatches()
        #expect(Set(all.map(\.batchID)) == ["b1", "b2"])
    }

    @Test("deletePendingBatch removes the collected batch")
    func deleteRemoves() async throws {
        let store = try GraphStore.inMemory()
        try await store.insertPendingBatch(batchID: "b1", transcript: "sess-1", minTurn: 0, maxTurn: 1)
        try await store.deletePendingBatch(batchID: "b1")

        #expect(try await store.pendingBatch(forTranscript: "sess-1") == nil)
        #expect(try await store.pendingBatches().isEmpty)
    }
}
