@testable import HayesCommand
import Testing

@Suite("HayesSystemPrompt")
struct HayesSystemPromptTests {
    @Test("prompt is non-empty")
    func nonEmpty() {
        #expect(!HayesSystemPrompt.text.isEmpty)
    }

    @Test("prompt avoids tokens that would cue the agent to recall prior work")
    func noMemoryTokens() {
        let lowered = HayesSystemPrompt.text.lowercased()
        #expect(!lowered.contains("memory"))
        #expect(!lowered.contains("recall"))
        #expect(!lowered.contains("from_past_experience"))
    }
}
