import Foundation
@testable import HayesCore
import Testing

@Suite("SubmitAnalysis")
struct SubmitAnalysisTests {
    @Test("handler stores the typed input on the box")
    func handlerStoresResult() async {
        let box = AnalysisResultBox()
        let input = AnalysisInput(lessons: [
            AnalysisInput.Lesson(
                seed: "yoga website",
                behavior: "Georgia serif typeface",
                sentiment: -0.8,
                source: .user
            ),
        ])

        await SubmitAnalysis.apply(input, to: box)

        let stored = await box.result
        #expect(stored?.lessons == [
            Lesson(
                seed: "yoga website",
                behavior: "Georgia serif typeface",
                sentiment: -0.8,
                source: .user
            ),
        ])
    }

    @Test("box starts empty before any apply call")
    func boxStartsEmpty() async {
        let box = AnalysisResultBox()
        let stored = await box.result
        #expect(stored == nil)
    }

    @Test("second apply overwrites the first")
    func applyOverwrites() async {
        let box = AnalysisResultBox()
        let first = AnalysisInput(lessons: [
            AnalysisInput.Lesson(seed: "s", behavior: "b1", sentiment: 0.1, source: .user),
        ])
        let second = AnalysisInput(lessons: [
            AnalysisInput.Lesson(seed: "s", behavior: "b2", sentiment: 0.9, source: .selfAssessment),
        ])

        await SubmitAnalysis.apply(first, to: box)
        await SubmitAnalysis.apply(second, to: box)

        let stored = await box.result
        #expect(stored?.lessons == [
            Lesson(seed: "s", behavior: "b2", sentiment: 0.9, source: .selfAssessment),
        ])
    }

    @Test("Operable exposes a single submit_analysis tool")
    func operableExposesTool() {
        let op = SubmitAnalysis(box: AnalysisResultBox())
        #expect(op.toolGroup.tools.count == 1)
        #expect(op.toolGroup.tools.first?.definition.function.name == "submit_analysis")
    }
}
