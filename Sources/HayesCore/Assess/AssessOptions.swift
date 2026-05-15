/// Caller-tunable knobs for ``AssessService/assess(messages:transcriptIdentity:options:)``.
public struct AssessOptions: Sendable {
    /// Per-turn analysis with bounded concurrency, or one analysis call
    /// over the entire transcript.
    public enum Strategy: Sendable, Equatable {
        /// Chunk the transcript at user-turn boundaries and run
        /// `analyze` per chunk in a `TaskGroup` capped at `concurrency`.
        case parallel(concurrency: Int)
        /// Single `analyze` call covering the entire message list. Not
        /// supported on `.appleIntelligence` whose context window can't
        /// accommodate a full conversation.
        case oneShot

        /// Parallel with the default concurrency of 4. Drop to 1 if a
        /// backend (e.g. AFM) serializes its on-device queue and
        /// concurrent calls error.
        public static let parallel: Strategy = .parallel(concurrency: 4)
    }

    /// Analysis strategy to use.
    public var strategy: Strategy

    /// When `false`, `source_transcript` and `source_excerpt` are
    /// written as NULL even when a `transcriptIdentity` is supplied —
    /// the `--no-store-source` privacy switch. `turn_index` is
    /// preserved either way.
    public var storeSource: Bool

    /// Maximum length, in characters, of the `source_excerpt` derived
    /// from a turn. Defaults to 500.
    public var sourceExcerptLimit: Int

    /// Creates a new options value. All parameters are defaulted.
    public init(
        strategy: Strategy = .parallel,
        storeSource: Bool = true,
        sourceExcerptLimit: Int = 500
    ) {
        self.strategy = strategy
        self.storeSource = storeSource
        self.sourceExcerptLimit = sourceExcerptLimit
    }

    /// Default options: parallel(concurrency: 4), provenance on, 500-char excerpts.
    public static let `default`: AssessOptions = .init()
}
