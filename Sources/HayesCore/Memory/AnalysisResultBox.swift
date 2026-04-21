/// An actor-held single-slot mailbox for an ``AnalysisResult``.
///
/// The `submit_analysis` tool's handler deposits its decoded arguments
/// here during an ``AnalysisRunner`` run; when the Operative loop
/// completes, the runner reads the result. Last write wins: if the model
/// calls the tool more than once, only the final payload is retained.
public actor AnalysisResultBox {
    /// The most recently stored result, or `nil` before any store.
    public private(set) var result: AnalysisResult?

    /// Creates an empty box.
    public init() {}

    /// Stores `r`, overwriting any prior value.
    public func store(_ r: AnalysisResult) {
        result = r
    }
}
