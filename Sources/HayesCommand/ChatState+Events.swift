import Foundation
import HayesCore
import TextUI

extension ChatState {
    /// Handles an event drained from `MemoryMiddleware.events`.
    ///
    /// Runs on the main actor. Splits events into two destinations:
    /// - ``memoryInjected`` → sidebar (activated seeds / behaviors).
    /// - ``edgeReinforced`` → chat transcript as a centered colored
    ///   banner, plus a top-edges refresh so the sidebar reflects
    ///   reinforcement from this turn.
    func apply(_ event: MiddlewareEvent) {
        switch event {
        case let .memoryInjected(seeds, behaviors):
            activatedSeeds = seeds
            activatedBehaviors = behaviors

        case let .edgeReinforced(payload):
            append(
                banner: Self.format(payload),
                color: SentimentColor.color(forSentiment: payload.sentiment)
            )
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

    private static func format(_ edge: MiddlewareEvent.ReinforcedEdge) -> String {
        let source = switch edge.source {
        case .user: "user"
        case .selfAssessment: "self"
        }
        return String(
            format: "learned (%@): %@ → %@ (%+.1f)",
            source,
            edge.seed,
            edge.behavior,
            edge.sentiment
        )
    }
}
