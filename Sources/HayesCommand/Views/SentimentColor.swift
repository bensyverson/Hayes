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
    static func color(forSentiment sentiment: Double) -> Style.Color {
        if sentiment >= 0.3 { return .brightGreen }
        if sentiment >= 0 { return .green }
        if sentiment > -0.3 { return .red }
        return .brightRed
    }

    /// Color for a signed edge weight in `[-1, 1]`.
    ///
    /// Thresholds:
    /// - `>= 0.6` → bright green (strongly reinforced)
    /// - `>= 0.2` → green
    /// - `> -0.2` → bright black (weak / neutral)
    /// - `> -0.6` → red
    /// - else → bright red (strongly avoided)
    static func color(forEdgeWeight weight: Double) -> Style.Color {
        if weight >= 0.6 { return .brightGreen }
        if weight >= 0.2 { return .green }
        if weight > -0.2 { return .brightBlack }
        if weight > -0.6 { return .red }
        return .brightRed
    }
}
