@testable import HayesCore
import Testing

@Suite("MemoryPrompts.analysis")
struct MemoryPromptsTests {
    /// The new contract: a single `lessons` array is the only output the
    /// analyzer produces. No separate moves/user_feedback/self_assessment
    /// split — each lesson carries its own seed + behavior + sentiment +
    /// source.
    @Test("prompt describes a single `lessons` output shape")
    func singleLessonsShape() {
        let prompt = MemoryPrompts.analysis
        // `lessons` is now the submit_analysis tool argument name rather
        // than a wrapping JSON key, so match the bare identifier; the
        // nested fields still appear quoted in the worked examples.
        #expect(prompt.contains("lessons"))
        #expect(prompt.contains("\"seed\""))
        #expect(prompt.contains("\"behavior\""))
        #expect(prompt.contains("\"sentiment\""))
        #expect(prompt.contains("\"source\""))
    }

    /// Callers of the previous three-field shape must not find the old
    /// keys in the new prompt — that would confuse the parser and the
    /// model both.
    @Test("prompt no longer mentions the retired three-field schema")
    func noLegacyFields() {
        let prompt = MemoryPrompts.analysis
        #expect(!prompt.contains("user_feedback"))
        #expect(!prompt.contains("self_assessment\":"))
        #expect(!prompt.contains("\"moves\""))
        #expect(!prompt.contains("act_id"))
        #expect(!prompt.contains("recent_acts"))
    }

    /// The Arial failure case from live logs: the agent used Arial but
    /// never logged it as a move; the user later said "I hate Arial"
    /// and the analyzer emitted nothing. The new prompt must show that
    /// retroactive capture of the implicit behavior is the expected
    /// pattern, not an edge case.
    @Test("prompt carries a retroactive-capture worked example")
    func retroactiveExamplePresent() {
        let prompt = MemoryPrompts.analysis
        #expect(prompt.lowercased().contains("example"))
        // The Arial scenario is the canonical illustration — check its
        // shape appears rather than pinning exact prose.
        #expect(prompt.contains("Arial"))
        #expect(prompt.contains("sentiment"))
    }

    /// Both user and agent-thinking sources must be demonstrated.
    @Test("prompt demonstrates both user and self_assessment sources")
    func bothSourcesCovered() {
        let prompt = MemoryPrompts.analysis
        #expect(prompt.contains("\"user\""))
        #expect(prompt.contains("\"self_assessment\""))
    }

    /// Emptiness must be framed as the exception. In the old prompt
    /// "empty array if no such attribution" biased Haiku toward `[]`.
    @Test("empty-lessons case is framed as the exception, not the default")
    func emptinessFramedAsException() {
        let prompt = MemoryPrompts.analysis.lowercased()
        #expect(
            prompt.contains("only if")
                || prompt.contains("only when")
                || prompt.contains("rare")
        )
    }

    /// The seed is a functional-context phrase, not a copy of the
    /// user's literal words. Keep this guidance in the prompt so
    /// analyzers don't emit seeds like "i hate arial".
    @Test("prompt instructs seeds to describe the context, not the user's words")
    func seedIsContextual() {
        let prompt = MemoryPrompts.analysis.lowercased()
        #expect(prompt.contains("context") || prompt.contains("kind of work"))
    }
}
