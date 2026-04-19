import Foundation
@testable import HayesCore
import Operator
import Testing

@Suite("MemoryMiddleware")
struct MemoryMiddlewareTests {
    private static func makeMiddleware(
        store: GraphStore,
        embeddings: any EmbeddingProvider,
        extractor: [String],
        analyzer: [String]
    ) -> (MemoryMiddleware, extractor: MockLLM, analyzer: MockLLM) {
        let extractorLLM = MockLLM(responses: extractor)
        let analyzerLLM = MockLLM(responses: analyzer)
        let middleware = MemoryMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ContextExtractor(llm: extractorLLM),
            analyzer: AnalysisRunner(llm: analyzerLLM)
        )
        return (middleware, extractorLLM, analyzerLLM)
    }

    private static func firstEvent<T>(
        _ middleware: MemoryMiddleware,
        matching transform: (MiddlewareEvent) -> T?,
        maxCount: Int = 5
    ) async -> T? {
        var iter = middleware.events.makeAsyncIterator()
        for _ in 0 ..< maxCount {
            guard let event = await iter.next() else { return nil }
            if let hit = transform(event) { return hit }
        }
        return nil
    }

    private static func userTurn() -> Operator.RunContext {
        Operator.RunContext(
            messages: [FakeTurn.userMessage("update"), FakeTurn.assistantMessage("ok")],
            thinking: "",
            finalText: "ok",
            toolCalls: []
        )
    }

    // MARK: - Scenario 1: Empty graph, no pending acts

    @Test("empty graph: memory tool injected, moves and act created")
    func emptyGraph() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["""
            ["landing page design", "wellness brand"]
            """],
            analyzer: ["""
            {"moves": ["warm palette", "clamp() typography"], "user_feedback": [], "self_assessment": []}
            """]
        )

        var request = FakeTurn.request(messages: [FakeTurn.userMessage("Design a yoga studio site")])
        try await middleware.beforeRequest(&request)

        let toolCalls = request.messages.compactMap(\.toolCalls).flatMap { $0 }
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].name == "memory")

        try await middleware.afterRun(Operator.RunContext(
            messages: [FakeTurn.userMessage("Design a yoga studio site"), FakeTurn.assistantMessage("ok")],
            thinking: "I picked warm palette and clamp() typography",
            finalText: "ok",
            toolCalls: []
        ))

        var events: [MiddlewareEvent] = []
        var iter = middleware.events.makeAsyncIterator()
        for _ in 0 ..< 5 {
            if let event = await iter.next() { events.append(event) }
        }
        #expect(events.count == 5)
        if case let .memoryInjected(seeds, behaviors) = events[0] {
            #expect(seeds.isEmpty)
            #expect(behaviors.isEmpty)
        } else {
            Issue.record("Expected memoryInjected; got \(events[0])")
        }
        if case let .movesExtracted(texts) = events[3] {
            #expect(texts == ["warm palette", "clamp() typography"])
        } else {
            Issue.record("expected movesExtracted")
        }
        if case let .actCreated(_, seedIDs, behaviorIDs) = events[4] {
            #expect(seedIDs.count == 2)
            #expect(behaviorIDs.count == 2)
        } else {
            Issue.record("expected actCreated")
        }

        let acts = try await store.recentActs(limit: 10)
        #expect(acts.count == 1)
    }

    // MARK: - Scenario 2: Populated graph, related turn

    @Test("populated graph surfaces seeds and behaviors")
    func populatedGraph() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "wellness brand", embedding: embeddings.embed("wellness brand"))
        let behavior = try await store.insertNode(text: "warm palette", embedding: embeddings.embed("warm palette"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: 0.8)

        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["""
            ["wellness brand"]
            """],
            analyzer: ["""
            {"moves": [], "user_feedback": [], "self_assessment": []}
            """]
        )

        var request = FakeTurn.request(messages: [FakeTurn.userMessage("Design a yoga site")])
        try await middleware.beforeRequest(&request)

        let injected = await Self.firstEvent(middleware) { event -> (seeds: [RetrievalResult.Scored<Node>], behaviors: [RetrievalResult.Scored<Node>])? in
            if case let .memoryInjected(seeds, behaviors) = event { return (seeds, behaviors) }
            return nil
        }
        let hit = try #require(injected)
        #expect(hit.seeds.count == 1)
        #expect(hit.seeds[0].value.text == "wellness brand")
        #expect(hit.behaviors.count == 1)
        #expect(hit.behaviors[0].value.text == "warm palette")
    }

    // MARK: - Scenario 3: User feedback list applied

    @Test("user feedback list adjusts edges and flips statuses")
    func userFeedbackApplied() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "seed", embedding: embeddings.embed("seed"))
        let b1 = try await store.insertNode(text: "b1", embedding: embeddings.embed("b1"))
        let b2 = try await store.insertNode(text: "b2", embedding: embeddings.embed("b2"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: b1.id, weight: 0.5)
        _ = try await store.insertEdge(sourceID: seed.id, targetID: b2.id, weight: 0.5)
        let actA = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [b1.id])
        let actB = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [b2.id])

        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["""
            ["x"]
            """],
            analyzer: ["""
            {
              "moves": [],
              "user_feedback": [
                {"act_id": "\(actA.id)", "sentiment": 1.0},
                {"act_id": "\(actB.id)", "sentiment": -1.0}
              ],
              "self_assessment": []
            }
            """]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let edgeA = try await store.findEdge(sourceID: seed.id, targetID: b1.id)
        let edgeB = try await store.findEdge(sourceID: seed.id, targetID: b2.id)
        #expect(abs((edgeA?.weight ?? 0) - 0.55) < 1e-9)
        #expect(abs((edgeB?.weight ?? 0) - 0.45) < 1e-9)

        let reloadA = try await store.findAct(id: actA.id)
        let reloadB = try await store.findAct(id: actB.id)
        #expect(reloadA?.status == .accepted)
        #expect(reloadB?.status == .revised)

        let feedback = await Self.firstEvent(middleware) { event -> [ActFeedback]? in
            if case let .userFeedback(list) = event { return list }
            return nil
        }
        #expect(feedback?.count == 2)
    }

    // MARK: - Scenario 4: Self-assessment list applied (30% scale)

    @Test("self-assessment applies at 0.3 scale")
    func selfAssessmentApplied() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "seed", embedding: embeddings.embed("seed"))
        let beh = try await store.insertNode(text: "b", embedding: embeddings.embed("b"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: beh.id, weight: 0.5)
        let act = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [beh.id])

        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["""
            ["x"]
            """],
            analyzer: ["""
            {"moves": [], "user_feedback": [], "self_assessment": [{"act_id": "\(act.id)", "sentiment": 1.0}]}
            """]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let edge = try await store.findEdge(sourceID: seed.id, targetID: beh.id)
        #expect(abs((edge?.weight ?? 0) - 0.515) < 1e-9)
        let reloaded = try await store.findAct(id: act.id)
        #expect(reloaded?.status == .accepted)

        let feedback = await Self.firstEvent(middleware) { event -> [ActFeedback]? in
            if case let .selfAssessment(list) = event { return list }
            return nil
        }
        #expect(feedback?.count == 1)
        #expect(feedback?.first?.actID == act.id)
    }

    // MARK: - Scenario 5: User and self on same act — user wins

    @Test("user feedback applies before self-assessment; self no-ops")
    func userWinsOverSelf() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "seed", embedding: embeddings.embed("seed"))
        let beh = try await store.insertNode(text: "b", embedding: embeddings.embed("b"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: beh.id, weight: 0.5)
        let act = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [beh.id])

        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["""
            ["x"]
            """],
            analyzer: ["""
            {
              "moves": [],
              "user_feedback": [{"act_id": "\(act.id)", "sentiment": 1.0}],
              "self_assessment": [{"act_id": "\(act.id)", "sentiment": -1.0}]
            }
            """]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let edge = try await store.findEdge(sourceID: seed.id, targetID: beh.id)
        #expect(abs((edge?.weight ?? 0) - 0.55) < 1e-9)
        let reloaded = try await store.findAct(id: act.id)
        #expect(reloaded?.status == .accepted)
    }

    // MARK: - Scenario 6: once-feedback-wins

    @Test("once-feedback-wins: non-pending act is ignored")
    func onceFeedbackWins() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "seed", embedding: embeddings.embed("seed"))
        let beh = try await store.insertNode(text: "b", embedding: embeddings.embed("b"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: beh.id, weight: 0.5)
        let act = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [beh.id])
        // Flip to accepted so recentActs(.pending) excludes it, but applyFeedback no-ops either way.
        try await store.setActStatus(id: act.id, status: .accepted)

        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["""
            ["x"]
            """],
            analyzer: ["""
            {"moves": [], "user_feedback": [{"act_id": "\(act.id)", "sentiment": 1.0}], "self_assessment": []}
            """]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let edge = try await store.findEdge(sourceID: seed.id, targetID: beh.id)
        #expect(edge?.weight == 0.5)
    }

    // MARK: - Scenario 7: unknown act ID tolerated

    @Test("unknown act ID in feedback is skipped without throwing")
    func unknownActIDSkipped() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "seed", embedding: embeddings.embed("seed"))
        let beh = try await store.insertNode(text: "b", embedding: embeddings.embed("b"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: beh.id, weight: 0.5)
        let realAct = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [beh.id])

        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["""
            ["x"]
            """],
            analyzer: ["""
            {
              "moves": [],
              "user_feedback": [
                {"act_id": "nonexistent", "sentiment": 1.0},
                {"act_id": "\(realAct.id)", "sentiment": 1.0}
              ],
              "self_assessment": []
            }
            """]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let edge = try await store.findEdge(sourceID: seed.id, targetID: beh.id)
        #expect(abs((edge?.weight ?? 0) - 0.55) < 1e-9)
    }

    // MARK: - Scenario 8: beforeRequest twice is idempotent

    @Test("beforeRequest called twice on same run no-ops the second time")
    func beforeRequestIdempotent() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, extractorLLM, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["""
            ["a", "b"]
            """],
            analyzer: ["""
            {"moves": [], "user_feedback": [], "self_assessment": []}
            """]
        )

        var request = FakeTurn.request(messages: [FakeTurn.userMessage("hi")])
        try await middleware.beforeRequest(&request)
        let afterFirstCount = request.messages.count
        try await middleware.beforeRequest(&request)
        #expect(request.messages.count == afterFirstCount)
        #expect(extractorLLM.calls.count == 1)
    }

    // MARK: - Scenario 9: current turn's act is NOT in recentActs at analyze() time

    @Test("current turn's act is inserted AFTER analyze; not visible to it")
    func currentActNotInRecent() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, _, analyzerLLM) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["""
            ["x"]
            """],
            analyzer: ["""
            {"moves": ["m"], "user_feedback": [], "self_assessment": []}
            """]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("hi")])
        try await middleware.beforeRequest(&req)

        let before = try await store.recentActs(limit: 100).count
        #expect(before == 0)

        try await middleware.afterRun(Operator.RunContext(
            messages: [FakeTurn.userMessage("hi"), FakeTurn.assistantMessage("ok")],
            thinking: "",
            finalText: "ok",
            toolCalls: []
        ))

        let after = try await store.recentActs(limit: 100).count
        #expect(after == 1)
        // Analyzer saw an empty recent-acts list: verify via the MockLLM's captured payload.
        let payload = analyzerLLM.calls[0].userMessage
        #expect(payload.contains("RECENT PENDING ACTS:"))
        #expect(payload.contains("(none)"))
    }

    // MARK: - Scenario 10: phantom memory tool-call arguments must be a JSON object

    @Test("phantom memory tool arguments serialize as a JSON object, not an array")
    func phantomArgumentsAreObject() async throws {
        // Anthropic's adapter refuses tool-use messages whose `input` does not
        // decode as `[String: JSONValue]`. A top-level JSON array (from a
        // `[String]` encode) trips it and surfaces as a DecodingError the
        // user sees as "LLM error: The data couldn't be read…". Lock the
        // object shape in.
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["""
            ["landing page design", "wellness brand"]
            """],
            analyzer: ["""
            {"moves": [], "user_feedback": [], "self_assessment": []}
            """]
        )

        var request = FakeTurn.request(messages: [FakeTurn.userMessage("Design a yoga studio site")])
        try await middleware.beforeRequest(&request)

        let toolCall = try #require(
            request.messages.compactMap(\.toolCalls).flatMap { $0 }.first { $0.name == "memory" }
        )
        let data = Data(toolCall.arguments.utf8)
        // Object shape: decodes as a dictionary.
        let decoded = try JSONSerialization.jsonObject(with: data)
        #expect(decoded is [String: Any])

        // Named "phrases" key with the extracted values.
        guard let dict = decoded as? [String: Any] else {
            Issue.record("expected dictionary; got \(type(of: decoded))")
            return
        }
        let phrases = try #require(dict["phrases"] as? [String])
        #expect(phrases == ["landing page design", "wellness brand"])
    }
}
