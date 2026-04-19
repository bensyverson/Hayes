import TextUI

/// Scrollable transcript of chat messages.
///
/// Anchored to the bottom so new messages scroll into view; the user can
/// still scroll up to inspect older content.
struct MessageListView: View {
    @EnvironmentObject var state: ChatState

    var body: some View {
        ScrollView {
            ForEach(state.messages) { message in
                MessageView(message: message)
            }
        }
        .defaultScrollAnchor(.bottom)
    }
}
