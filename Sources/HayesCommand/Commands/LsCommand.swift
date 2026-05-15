import ArgumentParser
import Foundation
import HayesCore

/// The `hayes ls` subcommand.
///
/// Dumps a slice of the memory graph as a list of (seed → behavior)
/// pairs, sorted by edge weight or last-reinforcement timestamp.
struct LsCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "ls",
        abstract: "List memory pairs sorted by weight or recency."
    )

    @OptionGroup var common: CommonOptions

    /// Sort order for the output.
    @Option(name: .long, help: "Sort order: weight (default) or recency.")
    var sort: SortOrder = .weight

    /// Maximum number of pairs to print.
    @Option(name: .long, help: "Maximum number of pairs to print (default 20).")
    var limit: Int = 20

    /// Emit JSON instead of plaintext.
    @Flag(name: .long, help: "Emit a JSON array instead of plaintext.")
    var json: Bool = false

    /// Sort orders exposed via `--sort`.
    enum SortOrder: String, ExpressibleByArgument, CaseIterable {
        case weight
        case recency
    }

    init() {}

    mutating func run() async throws {
        let dbURL = HayesPaths.resolve(dbArgument: common.db)
        let store = try GraphStore(path: dbURL)

        let edges: [Edge] = switch sort {
        case .weight: try await store.topEdgesByWeight(limit: limit)
        case .recency: try await store.topEdgesByRecency(limit: limit)
        }

        let nodeIDs = Array(Set(edges.flatMap { [$0.sourceID, $0.targetID] }))
        let nodes = try await store.findNodes(ids: nodeIDs)
        let lookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        let details: [PairDetail] = edges.compactMap { edge in
            guard let seed = lookup[edge.sourceID],
                  let behavior = lookup[edge.targetID]
            else { return nil }
            return PairDetail(seed: seed, behavior: behavior, edge: edge)
        }

        if json {
            try print(PairRenderer.renderListJSON(details))
        } else {
            let text = PairRenderer.renderListPlaintext(details)
            if !text.isEmpty {
                print(text)
            }
        }
    }
}
