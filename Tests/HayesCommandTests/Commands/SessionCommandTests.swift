import ArgumentParser
@testable import HayesCommand
import HayesCore
import Testing

@Suite("SessionCommand parsing")
struct SessionCommandParsingTests {
    @Test("session list parses with no extra args")
    func listParses() throws {
        let cmd = try SessionCommand.List.parse([])
        #expect(cmd.json == false)
    }

    @Test("session list --json")
    func listJSON() throws {
        let cmd = try SessionCommand.List.parse(["--json"])
        #expect(cmd.json)
    }

    @Test("session show requires a positional session-id")
    func showRequiresID() {
        #expect(throws: (any Error).self) {
            _ = try SessionCommand.Show.parse([])
        }
    }

    @Test("session show captures positional session-id")
    func showCapturesID() throws {
        let cmd = try SessionCommand.Show.parse(["abc-uuid"])
        #expect(cmd.sessionID == "abc-uuid")
    }

    @Test("session reset requires a positional session-id")
    func resetRequiresID() {
        #expect(throws: (any Error).self) {
            _ = try SessionCommand.Reset.parse([])
        }
    }

    @Test("session reset captures positional session-id")
    func resetCapturesID() throws {
        let cmd = try SessionCommand.Reset.parse(["abc-uuid"])
        #expect(cmd.sessionID == "abc-uuid")
    }
}
