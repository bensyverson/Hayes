import ArgumentParser
import Foundation
import HayesCore

/// The `hayes inspect` subcommand.
///
/// Looks up a single seed → behavior edge and prints its endpoints,
/// weight, timestamp, and provenance.
struct InspectCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "inspect",
        abstract: "Show a pair's text, weight, and provenance."
    )

    /// The seed (context) node identifier.
    @Argument(help: "Seed (context) node identifier.")
    var seedID: String

    /// The behavior node identifier.
    @Argument(help: "Behavior node identifier.")
    var behaviorID: String

    @OptionGroup var common: CommonOptions

    /// Emit JSON instead of plaintext.
    @Flag(name: .long, help: "Emit JSON instead of plaintext.")
    var json: Bool = false

    /// Errors thrown by ``InspectCommand``.
    enum InspectError: Error, LocalizedError {
        /// The requested edge does not exist.
        case edgeNotFound(sourceID: String, targetID: String)
        /// One of the endpoint nodes does not exist.
        case nodeNotFound(id: String)

        var errorDescription: String? {
            switch self {
            case let .edgeNotFound(sourceID, targetID):
                "No edge found from \(sourceID) to \(targetID)."
            case let .nodeNotFound(id):
                "Node \(id) not found (the edge references a missing endpoint)."
            }
        }
    }

    init() {}

    mutating func run() async throws {
        let dbURL = HayesPaths.resolve(dbArgument: common.db)
        let store = try GraphStore(path: dbURL)

        guard let edge = try await store.findEdge(sourceID: seedID, targetID: behaviorID) else {
            throw InspectError.edgeNotFound(sourceID: seedID, targetID: behaviorID)
        }
        guard let seed = try await store.findNode(id: seedID) else {
            throw InspectError.nodeNotFound(id: seedID)
        }
        guard let behavior = try await store.findNode(id: behaviorID) else {
            throw InspectError.nodeNotFound(id: behaviorID)
        }

        let detail = PairDetail(seed: seed, behavior: behavior, edge: edge)
        if json {
            try print(PairRenderer.renderJSON(detail))
        } else {
            print(PairRenderer.renderPlaintext(detail))
        }
    }
}
