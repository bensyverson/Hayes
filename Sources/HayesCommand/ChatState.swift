import Foundation
import HayesCore
import Operator
import TextUI

/// Shared reactive state for the `hayes chat` UI.
///
/// All `@Observed` properties trigger a re-render of the TextUI tree on
/// mutation. Non-reactive stored properties are configuration wired in
/// during ``start()``.
@MainActor
final class ChatState {
    // MARK: - Reactive state

    /// The chat transcript — user turns, agent streams, tool events, banners.
    @Observed var messages: [ChatMessage] = []

    /// Seeds retrieved for the current turn (displayed in the sidebar).
    @Observed var activatedSeeds: [RetrievalResult.Scored<Node>] = []

    /// Behaviors retrieved for the current turn (displayed in the sidebar).
    @Observed var activatedBehaviors: [RetrievalResult.Scored<Node>] = []

    /// Top edges by weight across the entire graph (displayed in the sidebar).
    @Observed var topEdges: [Edge] = []

    /// Node ID → display text for every node referenced by a row in
    /// ``topEdges``. Kept in sync by ``refreshTopEdges()`` so the
    /// sidebar can render edge endpoints by their phrase instead of
    /// an opaque short ID.
    @Observed var edgeNodeNames: [String: String] = [:]

    /// Whether an agent run is currently streaming.
    @Observed var isStreaming: Bool = false

    /// A startup / configuration warning to display above the transcript.
    @Observed var providerWarning: String?

    // MARK: - Non-reactive

    /// The TextField's working buffer. Handled by the field's internal
    /// `EditState`; wrapping it in `@Observed` would trigger redundant
    /// re-renders on every keystroke.
    var inputText: String = ""

    /// The configured operative, once ``start()`` succeeds.
    var operative: Operative?

    /// The memory middleware attached to ``operative``.
    var memoryMiddleware: MemoryMiddleware?

    /// The graph store backing the middleware.
    var store: GraphStore?

    /// The canvas coordinator shared with the tool surface.
    var coordinator: CanvasCoordinator?

    /// The in-progress conversation, reused across user turns.
    var lastConversation: Conversation?

    /// The parsed CLI arguments.
    let args: ChatArguments

    /// The task draining `MemoryMiddleware.events`.
    var eventTask: Task<Void, Never>?

    /// Creates a new state instance.
    /// - Parameter args: The parsed CLI arguments.
    init(args: ChatArguments) {
        self.args = args
    }
}
