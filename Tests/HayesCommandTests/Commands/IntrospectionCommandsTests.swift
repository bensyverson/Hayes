import ArgumentParser
import Foundation
@testable import HayesCommand
import HayesCore
import Testing

@Suite("InspectCommand parsing")
struct InspectCommandParsingTests {
    @Test("requires both seed-id and behavior-id positionals")
    func requiresBothIDs() {
        #expect(throws: (any Error).self) {
            _ = try InspectCommand.parse([])
        }
        #expect(throws: (any Error).self) {
            _ = try InspectCommand.parse(["seedID"])
        }
    }

    @Test("accepts two positional IDs")
    func acceptsBoth() throws {
        let cmd = try InspectCommand.parse(["seed1", "beh1"])
        #expect(cmd.seedID == "seed1")
        #expect(cmd.behaviorID == "beh1")
    }

    @Test("supports --json")
    func jsonFlag() throws {
        let cmd = try InspectCommand.parse(["seed1", "beh1", "--json"])
        #expect(cmd.json)
    }
}

@Suite("LsCommand parsing")
struct LsCommandParsingTests {
    @Test("defaults: sort=weight, limit=20, json=false")
    func defaults() throws {
        let cmd = try LsCommand.parse([])
        #expect(cmd.sort == .weight)
        #expect(cmd.limit == 20)
        #expect(cmd.json == false)
    }

    @Test("--sort recency parses")
    func sortRecency() throws {
        let cmd = try LsCommand.parse(["--sort", "recency"])
        #expect(cmd.sort == .recency)
    }

    @Test("--limit override")
    func limitOverride() throws {
        let cmd = try LsCommand.parse(["--limit", "5"])
        #expect(cmd.limit == 5)
    }

    @Test("--json flag")
    func jsonFlag() throws {
        let cmd = try LsCommand.parse(["--json"])
        #expect(cmd.json)
    }
}

@Suite("ForgetCommand parsing")
struct ForgetCommandParsingTests {
    @Test("requires both seed-id and behavior-id positionals")
    func requiresBothIDs() {
        #expect(throws: (any Error).self) {
            _ = try ForgetCommand.parse([])
        }
        #expect(throws: (any Error).self) {
            _ = try ForgetCommand.parse(["seedID"])
        }
    }

    @Test("accepts two positional IDs")
    func acceptsBoth() throws {
        let cmd = try ForgetCommand.parse(["seed1", "beh1"])
        #expect(cmd.seedID == "seed1")
        #expect(cmd.behaviorID == "beh1")
    }
}

@Suite("PairRenderer")
struct PairRendererTests {
    private func sampleDetail(provenance: EdgeProvenance? = nil) -> PairDetail {
        let seed = Node(id: "s1", text: "wellness brand", embedding: [0.1])
        let behavior = Node(id: "b1", text: "calm minimal palette", embedding: [0.1])
        let edge = Edge(
            sourceID: "s1", targetID: "b1",
            weight: 0.72,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: provenance
        )
        return PairDetail(seed: seed, behavior: behavior, edge: edge)
    }

    @Test("renderPlaintext includes node IDs, text, weight, and provenance when present")
    func renderPlaintextWithProvenance() {
        let detail = sampleDetail(provenance: EdgeProvenance(
            sourceTranscript: "abc-session",
            turnIndex: 4,
            sourceExcerpt: "design a yoga studio website"
        ))
        let text = PairRenderer.renderPlaintext(detail)
        #expect(text.contains("s1"))
        #expect(text.contains("b1"))
        #expect(text.contains("wellness brand"))
        #expect(text.contains("calm minimal palette"))
        #expect(text.contains("0.72"))
        #expect(text.contains("abc-session"))
        #expect(text.contains("turn 4"))
    }

    @Test("renderPlaintext omits provenance section when nil")
    func renderPlaintextWithoutProvenance() {
        let text = PairRenderer.renderPlaintext(sampleDetail())
        #expect(!text.contains("transcript:"))
        #expect(!text.contains("turn "))
    }

    @Test("renderJSON returns a JSON object with seed/behavior/edge keys")
    func renderJSONShape() throws {
        let detail = sampleDetail(provenance: EdgeProvenance(
            sourceTranscript: "abc-session",
            turnIndex: 4,
            sourceExcerpt: nil
        ))
        let json = try PairRenderer.renderJSON(detail)
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Issue.record("expected a top-level JSON object")
            return
        }
        guard let seed = object["seed"] as? [String: Any],
              let behavior = object["behavior"] as? [String: Any],
              let edge = object["edge"] as? [String: Any],
              let provenance = edge["provenance"] as? [String: Any]
        else {
            Issue.record("expected nested objects for seed/behavior/edge/provenance")
            return
        }
        let seedID: String? = seed["id"] as? String
        #expect(seedID == "s1")
        let behaviorID: String? = behavior["id"] as? String
        #expect(behaviorID == "b1")
        let weight: Double? = edge["weight"] as? Double
        #expect(weight == 0.72)
        let transcript: String? = provenance["sourceTranscript"] as? String
        #expect(transcript == "abc-session")
        let turnIndex: Int? = provenance["turnIndex"] as? Int
        #expect(turnIndex == 4)
    }
}
