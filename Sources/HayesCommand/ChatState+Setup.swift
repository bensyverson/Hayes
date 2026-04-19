import Foundation
import HayesCore
import Operator

/// The phantom `memory` tool surface.
///
/// `MemoryMiddleware` injects a synthetic `memory` tool-use/tool-result pair
/// at the start of each turn. Anthropic validates that every tool-call in the
/// transcript references a tool in the current tool list, so we must register
/// a `memory` tool on the Operative. The description discourages invocation;
/// the handler is a harmless fallback in case the model calls it anyway.
private struct MemoryPhantom: Operable {
    let toolGroup: ToolGroup = {
        let tool = Tool(
            name: "memory",
            description: """
            Ambient memory context. Surfaced automatically at the start of each turn \
            by the runtime. You do not need to call this tool — when relevant prior \
            work exists, it will already be in the conversation.
            """
        ) {
            ToolOutput("See the memory exchange already appended earlier in this turn.")
        }
        return ToolGroup(name: "Memory", tools: [tool])
    }()
}

extension ChatState {
    /// Wires the graph store, middleware, and operative, then starts draining
    /// `MemoryMiddleware.events` onto the main actor.
    ///
    /// Any setup error surfaces via ``providerWarning`` rather than throwing —
    /// the UI stays usable (the input box works) so the user can see the
    /// warning and fix their configuration.
    func start() {
        do {
            try HayesPaths.ensureDirectory()
            let dbURL = HayesPaths.resolve(dbArgument: args.db)
            let store = try GraphStore(path: dbURL)
            self.store = store

            let embeddings = try NLEmbeddingProvider()

            guard let apiKey = Self.resolveAnthropicKey() else {
                providerWarning = "Set ANTHROPIC_API_KEY to enable hayes chat."
                return
            }

            let service = LLMServiceAdapter(provider: .anthropic(apiKey: apiKey))
            let memoryLLM = OperatorLLMClient(
                service: service,
                configuration: ConversationConfiguration(modelType: .fast, maxTokens: 2048)
            )
            let extractor = ContextExtractor(llm: memoryLLM)
            let analyzer = AnalysisRunner(llm: memoryLLM)

            let middleware = MemoryMiddleware(
                store: store,
                embeddings: embeddings,
                extractor: extractor,
                analyzer: analyzer
            )
            memoryMiddleware = middleware

            let coordinator = CanvasCoordinator()
            self.coordinator = coordinator

            let canvas = try CanvasOperable(
                coordinator: coordinator,
                outputURL: HayesPaths.canvasImage
            )

            let config = ConversationConfiguration(
                modelType: .fast,
                inference: .direct,
                maxTokens: 4096
            )

            operative = try Operative(
                name: "Hayes Design Agent",
                description: "Visual designer powered by NativeCanvas.",
                provider: .anthropic(apiKey: apiKey),
                systemPrompt: HayesSystemPrompt.text,
                tools: [canvas, MemoryPhantom()],
                budget: Budget(maxTurns: 20),
                middleware: [middleware],
                configuration: config
            )

            startEventDrain(middleware: middleware)
            refreshTopEdges()
        } catch {
            providerWarning = "Setup error: \(error.localizedDescription)"
        }
    }

    private func startEventDrain(middleware: MemoryMiddleware) {
        let stream = middleware.events
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                self?.apply(event)
            }
        }
    }

    /// Re-reads the top edges and publishes them to the sidebar.
    func refreshTopEdges() {
        guard let store else { return }
        Task { @MainActor [weak self] in
            guard let edges = try? await store.topEdgesByWeight(limit: 20) else { return }
            self?.topEdges = edges
        }
    }
}
