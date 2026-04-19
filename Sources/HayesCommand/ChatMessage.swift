import Foundation
import TextUI

/// The role this message plays in the conversation UI.
enum MessageRole: Hashable {
    /// A user turn.
    case user
    /// A streamed agent response.
    case agent
    /// Extended thinking chunks, hidden unless debug is on later.
    case thinking
    /// A tool invocation emitted by the agent.
    case toolCall
    /// A tool output returned to the agent.
    case toolOutput
    /// A system notice (for example, an error or the stop reason).
    case system
    /// A centered banner emitted by the memory pipeline.
    case banner
}

/// A single line item in the chat transcript.
///
/// Drives both the main message-list view and the memory banners emitted
/// by ``MemoryMiddleware`` at end-of-turn.
struct ChatMessage: Identifiable {
    /// A stable identifier used by ``ForEach``.
    let id: UUID
    /// The role this message plays.
    let role: MessageRole
    /// The displayed text. Mutable to support streaming append.
    var text: String
    /// For ``MessageRole/toolCall`` / ``MessageRole/toolOutput``: the tool name.
    var toolName: String?
    /// The raw arguments the agent sent for a tool call.
    var toolArguments: String?
    /// The text form of a tool's output, if any.
    var toolOutput: String?
    /// For ``MessageRole/banner``: the foreground color to render in.
    var bannerColor: Style.Color?
}
