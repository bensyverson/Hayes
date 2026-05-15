import Operator

/// An `Operable` that exposes a single `submit_analysis` tool.
///
/// Drives the tool-calling path for ``AnalysisRunner``. The Operative
/// loop dispatches the tool; its handler deposits the typed
/// ``AnalysisInput`` into the injected ``AnalysisResultBox`` so the
/// runner can read a strongly-typed result once the loop completes.
///
/// The tool argument type (``AnalysisInput``) conforms to `@Generable`,
/// which guarantees schema-constrained output on both Anthropic
/// (tool-use) and Apple Intelligence (guided generation) — solving the
/// enum-drift problem that free-form JSON parsing could not.
public struct SubmitAnalysis: Operable {
    public let toolGroup: ToolGroup

    /// Creates a new `submit_analysis` tool bound to `box`.
    /// - Parameter box: Destination for the decoded analysis payload.
    public init(box: AnalysisResultBox) {
        // swiftlint:disable:next force_try
        let tool = try! Tool(
            name: "submit_analysis",
            description: """
            Record the distilled lessons from this turn. Call exactly once with \
            the complete list; return an empty `lessons` array only if the turn \
            carried no evaluative signal at all.
            """,
            input: AnalysisInput.self
        ) { input in
            await SubmitAnalysis.apply(input, to: box)
            return ToolOutput("Recorded.")
        }
        toolGroup = ToolGroup(name: "Analysis", tools: [tool])
    }

    /// Handler logic, extracted for unit testing without needing to
    /// invoke Operator's tool-dispatch machinery.
    static func apply(_ input: AnalysisInput, to box: AnalysisResultBox) async {
        await box.store(input.toAnalysisResult())
    }
}
