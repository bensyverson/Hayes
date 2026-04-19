import TextUI

/// Renders a single ``ChatMessage`` in the transcript.
///
/// User and agent messages become bordered bubbles; tool events become
/// centered dim labels; memory banners dispatch into ``BannerView``.
struct MessageView: View {
    let message: ChatMessage

    // swiftformat:disable:next redundantViewBuilder
    @ViewBuilder var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer()
                Text(message.text)
                    .padding(horizontal: 1)
                    .border(.rounded)
                    .foregroundColor(.cyan)
            }
        case .agent:
            HStack {
                Text(message.text)
                    .padding(horizontal: 1)
                    .border(.rounded)
                Spacer()
            }
        case .thinking:
            HStack {
                Text(message.text).dim().italic()
                Spacer()
            }
        case .toolCall:
            HStack {
                Spacer()
                Text("[\(message.toolName ?? "tool")]").dim()
                Spacer()
            }
        case .toolOutput:
            HStack {
                Spacer()
                Text(message.text).dim().italic()
                Spacer()
            }
        case .system:
            HStack {
                Text(message.text).foregroundColor(.red)
                Spacer()
            }
        case .banner:
            BannerView(message: message)
        }
    }
}
