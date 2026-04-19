import TextUI

/// A centered, colored banner rendered inside the message list.
///
/// Used for the `Moves:`, `User assessment:` and `Self-assessment:` lines
/// emitted by the memory pipeline at end of turn.
struct BannerView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            Spacer()
            Text(message.text)
                .foregroundColor(message.bannerColor ?? .white)
                .bold()
            Spacer()
        }
    }
}
