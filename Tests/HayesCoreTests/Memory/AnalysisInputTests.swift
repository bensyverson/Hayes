import Foundation
@testable import HayesCore
import Testing

@Suite("AnalysisInput")
struct AnalysisInputTests {
    @Test("converts both source cases to AnalysisResult")
    func convertsBothSources() {
        let input = AnalysisInput(lessons: [
            AnalysisInput.Lesson(
                seed: "wellness brand website",
                behavior: "clamp() responsive typography",
                sentiment: 0.7,
                source: .user
            ),
            AnalysisInput.Lesson(
                seed: "wellness brand website",
                behavior: "warmer color palette",
                sentiment: -0.3,
                source: .selfAssessment
            ),
        ])

        let result = input.toAnalysisResult()

        #expect(result.lessons == [
            Lesson(
                seed: "wellness brand website",
                behavior: "clamp() responsive typography",
                sentiment: 0.7,
                source: .user
            ),
            Lesson(
                seed: "wellness brand website",
                behavior: "warmer color palette",
                sentiment: -0.3,
                source: .selfAssessment
            ),
        ])
    }

    @Test("empty input produces empty AnalysisResult")
    func empty() {
        let input = AnalysisInput(lessons: [])
        #expect(input.toAnalysisResult().lessons.isEmpty)
    }

    @Test("preserves seed / behavior / sentiment fields verbatim")
    func preservesScalarFields() {
        let input = AnalysisInput(lessons: [
            AnalysisInput.Lesson(
                seed: "Yoga website",
                behavior: "Georgia serif typeface",
                sentiment: -0.8,
                source: .user
            ),
        ])

        let lesson = input.toAnalysisResult().lessons[0]

        #expect(lesson.seed == "Yoga website")
        #expect(lesson.behavior == "Georgia serif typeface")
        #expect(lesson.sentiment == -0.8)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let input = AnalysisInput(lessons: [
            AnalysisInput.Lesson(
                seed: "yoga",
                behavior: "Georgia",
                sentiment: -0.8,
                source: .user
            ),
            AnalysisInput.Lesson(
                seed: "yoga",
                behavior: "Trebuchet MS",
                sentiment: 0.9,
                source: .selfAssessment
            ),
        ])

        let encoded = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(AnalysisInput.self, from: encoded)

        #expect(decoded == input)
    }
}
