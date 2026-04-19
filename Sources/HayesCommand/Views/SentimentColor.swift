import HayesCore
import TextUI

/// Maps sentiment and edge-weight scalars to terminal colors.
///
/// Lives in the CLI target rather than `HayesCore` because the mapping
/// targets a terminal palette — pure library code should not depend on
/// `TextUI`.
enum SentimentColor {
    /// Color for a single sentiment value in `[-1, 1]`.
    ///
    /// Thresholds:
    /// - `>= 0.3` → bright green (strong positive)
    /// - `>= 0` → green (mild positive)
    /// - `> -0.3` → red (mild negative)
    /// - else → bright red (strong negative)
    static func color(for sentiment: Double) -> Style.Color {
        if sentiment >= 0.3 { return .brightGreen }
        if sentiment >= 0 { return .green }
        if sentiment > -0.3 { return .red }
        return .brightRed
    }

    /// Color derived from the average sentiment of a feedback list.
    ///
    /// Empty lists resolve to white.
    static func color(for feedback: [ActFeedback]) -> Style.Color {
        guard !feedback.isEmpty else { return .white }
        let avg = feedback.map(\.sentiment).reduce(0, +) / Double(feedback.count)
        return color(for: avg)
    }

    /// Color for an edge weight in `[0, 1]`.
    ///
    /// Thresholds:
    /// - `>= 0.8` → bright green
    /// - `>= 0.5` → yellow
    /// - `>= 0.2` → red
    /// - else → bright black (dim)
    static func color(forEdgeWeight weight: Double) -> Style.Color {
        if weight >= 0.8 { return .brightGreen }
        if weight >= 0.5 { return .yellow }
        if weight >= 0.2 { return .red }
        return .brightBlack
    }
}
