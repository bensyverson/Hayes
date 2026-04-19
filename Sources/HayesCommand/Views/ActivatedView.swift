import HayesCore
import TextUI

/// Top half of the sidebar: seeds and behaviors surfaced for the current turn.
struct ActivatedView: View {
    @EnvironmentObject var state: ChatState

    var body: some View {
        VStack {
            Text("Activated this turn").bold()
            Text("Seeds").dim()
            ForEach(state.activatedSeeds, id: \.value.id) { entry in
                Text(label(entry))
            }
            Text("Behaviors").dim()
            ForEach(state.activatedBehaviors, id: \.value.id) { entry in
                Text(label(entry))
            }
            Spacer()
        }
    }

    private func label(_ entry: RetrievalResult.Scored<Node>) -> String {
        String(format: "%.2f  %@", entry.score, entry.value.text)
    }
}
