import Foundation

public extension GraphStore {
    /// Retrieves relevant seeds and behaviors for a set of context embeddings.
    ///
    /// Runs the seed → traverse → rank pipeline described in the Hayes prototype doc:
    ///
    /// 1. For each context embedding, score against the in-memory embedding cache with cosine.
    /// 2. Collapse to unique nodes by best similarity; keep those meeting
    ///    ``RetrievalConfig/seedThreshold``; cap at ``RetrievalConfig/topSeeds``.
    /// 3. For each seed, follow outgoing edges whose weight meets
    ///    ``RetrievalConfig/minEdgeWeight``; sum weights per target.
    /// 4. Rank target nodes by summed weight and take the top
    ///    ``RetrievalConfig/topBehaviors``.
    ///
    /// - Parameters:
    ///   - contextEmbeddings: The embedding(s) of the current context phrases.
    ///   - config: The retrieval configuration.
    /// - Returns: A ``RetrievalResult`` containing ranked seeds and behaviors.
    func retrieve(
        contextEmbeddings: [[Float]],
        config: RetrievalConfig = .default
    ) throws -> RetrievalResult {
        guard !contextEmbeddings.isEmpty else { return .empty }

        var bestSimilarity: [String: Float] = [:]
        for (nodeID, embedding) in embeddingSnapshot() {
            guard !embedding.isEmpty else { continue }
            var best: Float = -.infinity
            for query in contextEmbeddings where query.count == embedding.count {
                let sim = cosineSimilarity(query, embedding)
                if sim > best { best = sim }
            }
            if best >= config.seedThreshold {
                bestSimilarity[nodeID] = best
            }
        }

        let rankedSeedIDs = bestSimilarity
            .sorted { $0.value > $1.value }
            .prefix(config.topSeeds)
            .map(\.key)

        guard !rankedSeedIDs.isEmpty else { return .empty }

        var seedNodes: [RetrievalResult.Scored<Node>] = []
        var behaviorScores: [String: Double] = [:]

        for seedID in rankedSeedIDs {
            guard let seedNode = try findNode(id: seedID),
                  let sim = bestSimilarity[seedID] else { continue }
            seedNodes.append(RetrievalResult.Scored<Node>(value: seedNode, score: Double(sim)))
            let edges = try outgoingEdges(from: seedID)
            for edge in edges where edge.weight >= config.minEdgeWeight {
                behaviorScores[edge.targetID, default: 0.0] += edge.weight
            }
        }

        let rankedBehaviorEntries = behaviorScores
            .sorted { $0.value > $1.value }
            .prefix(config.topBehaviors)

        var behaviorNodes: [RetrievalResult.Scored<Node>] = []
        for (targetID, summedWeight) in rankedBehaviorEntries {
            if let node = try findNode(id: targetID) {
                behaviorNodes.append(RetrievalResult.Scored<Node>(value: node, score: summedWeight))
            }
        }

        return RetrievalResult(seeds: seedNodes, behaviors: behaviorNodes)
    }
}
