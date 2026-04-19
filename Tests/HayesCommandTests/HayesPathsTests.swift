import Foundation
@testable import HayesCommand
import Testing

@Suite("HayesPaths")
struct HayesPathsTests {
    @Test("resolve(nil) returns the default database path")
    func defaultDB() {
        let url = HayesPaths.resolve(dbArgument: nil)
        #expect(url == HayesPaths.defaultDatabase)
    }

    @Test("resolve honors an explicit absolute path")
    func explicitAbsolute() {
        let url = HayesPaths.resolve(dbArgument: "/tmp/hayes-test.sqlite")
        #expect(url.path == "/tmp/hayes-test.sqlite")
    }

    @Test("resolve expands a leading tilde to the user's home directory")
    func tildeExpansion() {
        let url = HayesPaths.resolve(dbArgument: "~/hayes-test.sqlite")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(url.path == "\(home)/hayes-test.sqlite")
    }

    @Test("ensureDirectory is idempotent")
    func directoryIdempotent() throws {
        try HayesPaths.ensureDirectory()
        try HayesPaths.ensureDirectory()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: HayesPaths.root.path,
            isDirectory: &isDir
        )
        #expect(exists)
        #expect(isDir.boolValue)
    }
}
