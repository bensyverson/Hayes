import Foundation
import HayesCore
import TextUI

extension ChatState {
    /// Handles an event drained from `MemoryMiddleware.events`.
    ///
    /// Runs on the main actor. Splits events into three destinations:
    /// - ``memoryInjected`` → sidebar (activated seeds / behaviors).
    /// - ``movesExtracted`` / ``userFeedback`` / ``selfAssessment`` → the
    ///   chat transcript, as centered colored banners.
    /// - ``actCreated`` → trigger a top-edges refetch so the sidebar
    ///   reflects reinforcement from this turn.
    func apply(_ event: MiddlewareEvent) {
        switch event {
        case let .memoryInjected(seeds, behaviors):
            activatedSeeds = seeds
            activatedBehaviors = behaviors

        case let .movesExtracted(texts):
            guard !texts.isEmpty else { return }
            append(banner: "Moves: \(texts.joined(separator: ", "))", color: .cyan)

        case let .userFeedback(list):
            guard !list.isEmpty else { return }
            let body = list.map(Self.format).joined(separator: ", ")
            append(banner: "User assessment: \(body)", color: SentimentColor.color(for: list))

        case let .selfAssessment(list):
            guard !list.isEmpty else { return }
            let body = list.map(Self.format).joined(separator: ", ")
            append(banner: "Self-assessment: \(body)", color: SentimentColor.color(for: list))

        case .actCreated:
            refreshTopEdges()
        }
    }

    private func append(banner text: String, color: Style.Color) {
        messages.append(ChatMessage(
            id: UUID(),
            role: .banner,
            text: text,
            bannerColor: color
        ))
    }

    private static func format(_ entry: ActFeedback) -> String {
        String(format: "%@:%+.1f", entry.actID, entry.sentiment)
    }
}
