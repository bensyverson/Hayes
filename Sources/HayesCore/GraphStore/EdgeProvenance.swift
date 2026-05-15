/// Provenance fields attached to an edge: which transcript and turn the
/// lesson was learned from, and an excerpt of that turn's text.
///
/// `EdgeProvenance` is a bag of nullable values rather than a "must
/// supply" payload — `hayes assess --no-store-source` can null out
/// `sourceTranscript` and `sourceExcerpt` while keeping `turnIndex`,
/// preserving position information without leaking identifying data.
public struct EdgeProvenance: Friendly {
    /// The harness-native session identifier the lesson was derived
    /// from, when available. `nil` opts out of transcript identity.
    public let sourceTranscript: String?
    /// The zero-based index of the turn within the transcript that
    /// produced the lesson.
    public let turnIndex: Int?
    /// A short excerpt of the producing turn's text.
    public let sourceExcerpt: String?

    /// Creates a new provenance value.
    public init(
        sourceTranscript: String? = nil,
        turnIndex: Int? = nil,
        sourceExcerpt: String? = nil
    ) {
        self.sourceTranscript = sourceTranscript
        self.turnIndex = turnIndex
        self.sourceExcerpt = sourceExcerpt
    }
}
