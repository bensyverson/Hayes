import Foundation
import Operator

extension ChatState {
    /// Sends a user message through the operative and streams the agent's
    /// response into ``messages``.
    ///
    /// Consumes the `OperationStream` produced by `operative.run(_:)`,
    /// dispatching each event into the transcript. Memory-pipeline banners
    /// are handled separately via ``apply(_:)`` — they arrive on the
    /// middleware event stream, which fires inside the middleware's
    /// `afterRun` hook that the Operator runtime awaits before completing
    /// the run.
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        inputText = ""

        guard let operative else {
            messages.append(ChatMessage(
                id: UUID(),
                role: .system,
                text: "No operative configured — see the warning above."
            ))
            return
        }

        isStreaming = true
        defer { isStreaming = false }

        messages.append(ChatMessage(id: UUID(), role: .user, text: trimmed))

        let stream: OperationStream = if let convo = lastConversation {
            operative.run(trimmed, continuing: convo)
        } else {
            operative.run(trimmed)
        }

        var currentAgentID: UUID?

        for await op in stream {
            switch op {
            case let .text(chunk):
                if let id = currentAgentID,
                   let idx = messages.firstIndex(where: { $0.id == id })
                {
                    messages[idx].text += chunk
                } else {
                    let message = ChatMessage(id: UUID(), role: .agent, text: chunk)
                    currentAgentID = message.id
                    messages.append(message)
                }

            case let .thinking(chunk):
                if let last = messages.last, last.role == .thinking {
                    messages[messages.count - 1].text += chunk
                } else {
                    messages.append(ChatMessage(
                        id: UUID(),
                        role: .thinking,
                        text: chunk
                    ))
                }

            case let .toolsRequested(requests):
                currentAgentID = nil
                for request in requests {
                    messages.append(ChatMessage(
                        id: UUID(),
                        role: .toolCall,
                        text: request.name,
                        toolName: request.name,
                        toolArguments: request.arguments
                    ))
                }

            case let .toolCompleted(request, output):
                let text: String = if request.name == "view_canvas" {
                    "[canvas rendered → \(HayesPaths.canvasImage.path)]"
                } else {
                    output.textContent ?? "[media content]"
                }
                messages.append(ChatMessage(
                    id: UUID(),
                    role: .toolOutput,
                    text: text,
                    toolName: request.name,
                    toolOutput: text
                ))

            case let .toolFailed(request, error):
                messages.append(ChatMessage(
                    id: UUID(),
                    role: .toolOutput,
                    text: "Error: \(error.message)",
                    toolName: request.name
                ))

            case .turnStarted:
                currentAgentID = nil

            case let .completed(result):
                lastConversation = result.conversation

            case let .stopped(reason):
                messages.append(ChatMessage(
                    id: UUID(),
                    role: .system,
                    text: "Stopped: \(reason)"
                ))

            default:
                break
            }
        }
    }
}
