import TextUI

/// Right column of the chat UI: activated nodes on top, top edges below.
struct SidebarView: View {
    var body: some View {
        VStack {
            ActivatedView()
            Divider.horizontal
            TopEdgesView()
        }
    }
}
