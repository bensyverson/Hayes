import HayesCore
import TextUI

/// Bottom half of the sidebar: the top 20 edges by weight in the graph.
///
/// Each row renders as `0.85 source text → target text`, clipped to the
/// sidebar's 40-column budget so long phrases don't wrap. Colored by
/// ``SentimentColor/color(forEdgeWeight:)`` — positive rows in one hue,
/// neutral in another, negative in a third — for a quick read on which
/// pairings the graph has reinforced.
struct TopEdgesView: View {
    /// Character budget allotted to each node phrase. Tuned against the
    /// 40-column sidebar: weight `"+1.00 "` is 6 chars, `" → "` is 3
    /// chars, leaving `31` for both names — 15 each with one byte of
    /// slack. Shorter phrases render in full; longer ones get a
    /// trailing ellipsis.
    private static let nameBudget = 15

    @EnvironmentObject var state: ChatState

    var body: some View {
        VStack {
            Text("Top edges").bold()
            ForEach(state.topEdges, id: \.self) { edge in
                Text(label(edge))
                    .foregroundColor(SentimentColor.color(forEdgeWeight: edge.weight))
                    .frame(width: 40, alignment: .leading)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private func label(_ edge: Edge) -> String {
        let src = resolve(edge.sourceID)
        let tgt = resolve(edge.targetID)
        return String(format: "%+.2f %@ → %@", edge.weight, src, tgt)
    }

    private func resolve(_ id: String) -> String {
        let name = state.edgeNodeNames[id] ?? String(id.prefix(6))
        return Self.truncate(name, to: Self.nameBudget)
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(max(limit - 1, 0))
        return "\(prefix)…"
    }
}
