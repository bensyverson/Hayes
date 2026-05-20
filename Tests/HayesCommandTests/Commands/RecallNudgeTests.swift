import Foundation
@testable import HayesCommand
import Testing

@Suite("Recall missing-key nudge")
struct RecallNudgeTests {
    @Test("nudges when warning is on and no key resolves")
    func nudgesWhenMissing() throws {
        let nudge = RecallCommand.missingAnthropicKeyNudge(warn: true, resolvedKey: nil)
        let text = try #require(nudge)
        #expect(text.contains("hayes auth set"))
    }

    @Test("silent when a key is available")
    func silentWhenKeyPresent() {
        #expect(RecallCommand.missingAnthropicKeyNudge(warn: true, resolvedKey: "sk-test") == nil)
    }

    @Test("silent when warning is disabled")
    func silentWhenDisabled() {
        #expect(RecallCommand.missingAnthropicKeyNudge(warn: false, resolvedKey: nil) == nil)
    }

    @Test("silent when disabled even if a key is present")
    func silentWhenDisabledWithKey() {
        #expect(RecallCommand.missingAnthropicKeyNudge(warn: false, resolvedKey: "sk-test") == nil)
    }
}
