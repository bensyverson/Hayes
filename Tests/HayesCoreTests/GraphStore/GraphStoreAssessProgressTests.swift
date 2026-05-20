import Foundation
import GRDB
@testable import HayesCore
import Testing

@Suite("GraphStore assess progress")
struct GraphStoreAssessProgressTests {
    @Test("assess_progress table has the expected columns and PK")
    func tableShape() throws {
        let store = try GraphStore.inMemory()
        let columns = try store.database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(assess_progress)")
        }
        let byName = Dictionary(uniqueKeysWithValues: columns.map { row in
            (row["name"] as String, row)
        })

        let identity = try #require(byName["identity"])
        #expect(identity["type"] as String == "TEXT")
        #expect(identity["notnull"] as Int == 1)
        #expect(identity["pk"] as Int == 1)

        let maxTurn = try #require(byName["max_turn_index"])
        #expect(maxTurn["type"] as String == "INTEGER")
        #expect(maxTurn["notnull"] as Int == 1)

        let updated = try #require(byName["updated_at"])
        #expect(updated["type"] as String == "REAL")
        #expect(updated["notnull"] as Int == 1)
    }

    @Test("assessProgress returns nil for an unknown identity")
    func progressUnknownIsNil() async throws {
        let store = try GraphStore.inMemory()
        #expect(try await store.assessProgress(for: "never-seen") == nil)
    }

    @Test("advanceAssessProgress then assessProgress round-trips the stored index")
    func advanceRoundTrips() async throws {
        let store = try GraphStore.inMemory()
        try await store.advanceAssessProgress(identity: "sess-1", to: 4)
        #expect(try await store.assessProgress(for: "sess-1") == 4)
    }

    @Test("advanceAssessProgress is monotonic — a lower index never lowers progress")
    func advanceIsMonotonic() async throws {
        let store = try GraphStore.inMemory()
        try await store.advanceAssessProgress(identity: "sess-1", to: 5)
        try await store.advanceAssessProgress(identity: "sess-1", to: 2)
        #expect(try await store.assessProgress(for: "sess-1") == 5)
    }

    @Test("advanceAssessProgress moves forward to a higher index")
    func advanceMovesForward() async throws {
        let store = try GraphStore.inMemory()
        try await store.advanceAssessProgress(identity: "sess-1", to: 2)
        try await store.advanceAssessProgress(identity: "sess-1", to: 7)
        #expect(try await store.assessProgress(for: "sess-1") == 7)
    }

    @Test("progress is scoped per identity")
    func progressScopedPerIdentity() async throws {
        let store = try GraphStore.inMemory()
        try await store.advanceAssessProgress(identity: "sess-A", to: 3)
        #expect(try await store.assessProgress(for: "sess-A") == 3)
        #expect(try await store.assessProgress(for: "sess-B") == nil)
    }
}
