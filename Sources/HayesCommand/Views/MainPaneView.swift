import TextUI

/// The left column of the chat UI: optional warning, transcript, input bar.
struct MainPaneView: View {
    @EnvironmentObject var state: ChatState

    var body: some View {
        VStack {
            if let warning = state.providerWarning {
                Text(warning).foregroundColor(.red)
                Divider.horizontal
            }
            MessageListView()
            Divider.horizontal
            InputBarView()
        }
    }
}
