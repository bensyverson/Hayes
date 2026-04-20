import Foundation
@testable import HayesCore
import Testing

@Suite("Lesson")
struct LessonTests {
    @Test("Lesson Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let lesson = Lesson(
            seed: "typography for wellness brands",
            behavior: "Georgia serif typeface",
            sentiment: -0.7,
            source: .user
        )
        let data = try JSONEncoder().encode(lesson)
        let decoded = try JSONDecoder().decode(Lesson.self, from: data)
        #expect(decoded == lesson)
    }

    @Test("Lesson JSON shape matches the analyzer contract")
    func analyzerJSONShape() throws {
        let json = """
        {
          "seed": "electrolyte drink website",
          "behavior": "Arial body copy",
          "sentiment": -0.8,
          "source": "user"
        }
        """
        let decoded = try JSONDecoder().decode(Lesson.self, from: Data(json.utf8))
        #expect(decoded.seed == "electrolyte drink website")
        #expect(decoded.behavior == "Arial body copy")
        #expect(decoded.sentiment == -0.8)
        #expect(decoded.source == .user)
    }

    @Test("self_assessment source decodes from snake_case JSON")
    func selfAssessmentSource() throws {
        let json = """
        {"seed": "s", "behavior": "b", "sentiment": 0.4, "source": "self_assessment"}
        """
        let decoded = try JSONDecoder().decode(Lesson.self, from: Data(json.utf8))
        #expect(decoded.source == .selfAssessment)
    }

    @Test("unknown source string raises a decoding error")
    func unknownSourceRejected() {
        let json = """
        {"seed": "s", "behavior": "b", "sentiment": 0.1, "source": "peer"}
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Lesson.self, from: Data(json.utf8))
        }
    }

    @Test("encoded source uses snake_case for self_assessment")
    func encodesSnakeCaseSource() throws {
        let lesson = Lesson(seed: "s", behavior: "b", sentiment: 0.2, source: .selfAssessment)
        let data = try JSONEncoder().encode(lesson)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"self_assessment\""))
    }

    @Test("Lesson.Source raw values are stable")
    func sourceRawValues() {
        #expect(Lesson.Source.user.rawValue == "user")
        #expect(Lesson.Source.selfAssessment.rawValue == "self_assessment")
    }
}
