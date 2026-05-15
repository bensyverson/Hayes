/// Caller-tunable knobs for ``RecallService/recall(messages:sessionID:options:)``.
public struct RecallOptions: Sendable {
    /// Number of trailing conversation messages to consider when forming
    /// the context window. `nil` falls back to
    /// ``RetrievalConfig/contextWindowSize``.
    public var windowSize: Int?

    /// When `true`, retrieval runs but no `session_injections` rows are
    /// written and pairs already injected this session surface under
    /// ``RecallResult/skipped`` with
    /// ``RecallResult/SkipReason/alreadyInjectedThisSession``.
    public var dryRun: Bool

    /// When `false`, surfaced pairs are returned but not persisted to the
    /// session injections table. Useful for embedded callers that want
    /// retrieval semantics without the dedup side effect.
    public var storeInjection: Bool

    /// Creates a new options value. All parameters are defaulted.
    public init(
        windowSize: Int? = nil,
        dryRun: Bool = false,
        storeInjection: Bool = true
    ) {
        self.windowSize = windowSize
        self.dryRun = dryRun
        self.storeInjection = storeInjection
    }

    /// Default options: window from `RetrievalConfig`, no dry-run,
    /// injections stored.
    public static let `default`: RecallOptions = .init()
}
