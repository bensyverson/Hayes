import TextUI

/// The top-level chat layout: main pane on the left, sidebar on the right.
///
/// The sidebar is fixed at 40 columns wide. At terminal widths below ~120
/// columns the main pane becomes cramped; users should resize to at least
/// that width.
struct ChatView: View {
    var body: some View {
        HStack {
            MainPaneView()
            Divider.vertical
            SidebarView()
                .frame(width: 40)
        }
    }
}
