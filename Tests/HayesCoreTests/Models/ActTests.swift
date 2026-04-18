import Foundation
@testable import HayesCore
import Testing

@Suite("Act / ActStatus")
struct ActTests {
    @Test("Act Codable round-trip preserves fields")
    func actCodableRoundTrip() throws {
        let act = Act(
            id: "act001",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            seedIDs: ["s1", "s2"],
            behaviorIDs: ["b1"],
            status: .pending
        )
        let data = try JSONEncoder().encode(act)
        let decoded = try JSONDecoder().decode(Act.self, from: data)
        #expect(decoded == act)
    }

    @Test("ActStatus raw values are stable")
    func actStatusRawValues() {
        #expect(ActStatus.pending.rawValue == "pending")
        #expect(ActStatus.accepted.rawValue == "accepted")
        #expect(ActStatus.revised.rawValue == "revised")
        #expect(ActStatus.rejected.rawValue == "rejected")
    }

    @Test("ActStatus Codable round-trip")
    func actStatusCodable() throws {
        for status: ActStatus in [.pending, .accepted, .revised, .rejected] {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(ActStatus.self, from: data)
            #expect(decoded == status)
        }
    }
}
