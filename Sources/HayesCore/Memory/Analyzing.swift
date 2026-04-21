import Operator

/// The analyzer-stage surface area seen by ``MemoryMiddleware``.
///
/// Factored out of the concrete ``AnalysisRunner`` so tests can inject a
/// canned analyzer without building an `Operative` + `LLMService` stack.
/// Production callers still construct ``AnalysisRunner`` directly;
/// middleware holds `any Analyzing`.
public protocol Analyzing: Sendable {
    /// Runs analysis over a completed turn.
    func analyze(
        messages: [Operator.Message],
        thinking: String
    ) async throws -> AnalysisResult
}

extension AnalysisRunner: Analyzing {}
