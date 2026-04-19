import TextUI

/// The `hayes` executable's entry point.
///
/// Conforms to TextUI's ``App`` and owns a single ``ChatState``. The
/// `@main` attribute goes here (not on an `AsyncParsableCommand`) because
/// TextUI's default `main()` calls `RunLoop.launch(Self())` — it needs
/// to construct the app itself. CLI arguments are parsed inside
/// ``init()`` via `ChatArguments.parseOrExit()`.
@main
struct HayesChatApp: App {
    let state: ChatState

    init() {
        let args = ChatArguments.parseOrExit()
        let chatState = ChatState(args: args)
        chatState.start()
        state = chatState
    }

    var body: some View {
        VStack {
            CommandBar().foregroundColor(.yellow)
            ChatView()
        }
        .environmentObject(state)
    }

    var commands: [CommandGroup] {
        [
            CommandGroup("App") {
                Button("Quit") { Application.quit() }
                    .keyboardShortcut("q", modifiers: .control)
            },
        ]
    }
}
