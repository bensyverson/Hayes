import Foundation
import TextUI

/// The input bar at the bottom of the main pane: a text field + send button.
struct InputBarView: View {
    @EnvironmentObject var state: ChatState

    var body: some View {
        HStack {
            TextField("Message", text: state.inputText) { [state] newValue in
                state.inputText = newValue
            }
            .onSubmit { [state] in
                submit(state)
            }
            .border()

            Text(" ")
            Button("Send") { [state] in
                submit(state)
            }
            .disabled(state.isStreaming)
            .buttonStyle(.bordered)
        }
    }
}

@MainActor
private func submit(_ state: ChatState) {
    guard !state.isStreaming else { return }
    let text = state.inputText
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    Task { @MainActor in
        await state.send(text)
    }
}
