import ArgumentParser
import Foundation
import HayesCore

/// The `hayes forget` subcommand.
///
/// Surgically deletes a single seed → behavior edge. Endpoint nodes
/// are left intact so they remain available to retrieval and to other
/// edges that may reference them.
struct ForgetCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "forget",
        abstract: "Delete a single memory pair by seed/behavior IDs."
    )

    /// The seed (context) node identifier.
    @Argument(help: "Seed (context) node identifier.")
    var seedID: String

    /// The behavior node identifier.
    @Argument(help: "Behavior node identifier.")
    var behaviorID: String

    @OptionGroup var common: CommonOptions

    init() {}

    mutating func run() async throws {
        let dbURL = HayesPaths.resolve(dbArgument: common.db)
        let store = try GraphStore(path: dbURL)
        try await store.deleteEdge(sourceID: seedID, targetID: behaviorID)
        print("Deleted \(seedID) → \(behaviorID).")
    }
}
