import HayesCore
import TextUI

/// Bottom half of the sidebar: the top 20 edges by weight in the graph.
///
/// Each row is colored by ``SentimentColor/color(forEdgeWeight:)``, giving a
/// quick visual read on how "stable" the graph's strongest associations are.
struct TopEdgesView: View {
    @EnvironmentObject var state: ChatState

    var body: some View {
        VStack {
            Text("Top edges").bold()
            ForEach(state.topEdges, id: \.self) { edge in
                Text(label(edge))
                    .foregroundColor(SentimentColor.color(forEdgeWeight: edge.weight))
            }
            Spacer()
        }
    }

    private func label(_ edge: Edge) -> String {
        let src = shortID(edge.sourceID)
        let tgt = shortID(edge.targetID)
        return String(format: "%.2f %@→%@", edge.weight, src, tgt)
    }

    private func shortID(_ id: String) -> String {
        String(id.prefix(6))
    }
}
