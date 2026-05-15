import HayesCore
import Operator

extension MemoryBackend {
    /// Builds an ``HayesCore/LLMClient`` driven by this backend.
    ///
    /// Used by the CLI to instantiate single-shot stages
    /// (``HayesCore/ContextExtractor``) without dragging in the streaming
    /// ``Operator/LLMService`` boilerplate at every call site.
    func makeLLMClient() -> any LLMClient {
        let service: any LLMService = switch self {
        case .appleIntelligence:
            AppleIntelligenceService()
        case let .anthropic(apiKey):
            LLMServiceAdapter(provider: .anthropic(apiKey: apiKey))
        }
        return OperatorLLMClient(service: service)
    }
}
