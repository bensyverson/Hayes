import Foundation
import GRDB
@testable import HayesCore
import Operator
import Testing

@Suite("BatchReconciler")
struct BatchReconcilerTests {
    // MARK: - Fixtures

    private static func turns(_ prompts: [String]) -> [Operator.Message] {
        prompts.flatMap { prompt in
            [
                Operator.Message(role: .user, content: prompt),
                Operator.Message(role: .assistant, content: "ok"),
            ]
        }
    }

    private static func makeReconciler(
        store: GraphStore,
        send: @escaping AnthropicBatchClient.Send
    ) -> BatchReconciler {
        let embeddings = FakeEmbeddingProvider(dimension: 64)
        let analyzer = AnalysisRunner(backend: .anthropic(apiKey: "k"))
        let assess = AssessService(
            store: store,
            embeddings: embeddings,
            analyzer: analyzer,
            backend: .anthropic(apiKey: "k")
        )
        let client = AnthropicBatchClient(apiKey: "k", send: send)
        return BatchReconciler(store: store, assess: assess, analyzer: analyzer, batchClient: client)
    }

    private actor Recorder {
        private(set) var posts: [URLRequest] = []
        func addPost(_ request: URLRequest) {
            posts.append(request)
        }
    }

    private static func lessonLine(customID: String, seed: String) -> String {
        #"{"custom_id":"\#(customID)","result":{"type":"succeeded","message":{"content":[{"type":"tool_use","id":"t","name":"submit_analysis","input":{"lessons":[{"seed":"\#(seed)","behavior":"b","sentiment":0.7,"source":"user"}]}}]}}}"#
    }

    private static func erroredLine(customID: String) -> String {
        #"{"custom_id":"\#(customID)","result":{"type":"errored"}}"#
    }

    private func edgeCount(_ store: GraphStore) async throws -> Int {
        try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges") ?? -1
        }
    }

    // MARK: - Submit

    @Test("submit posts one batch covering the backlog and records a pending row")
    func submitCreatesPending() async throws {
        let store = try GraphStore.inMemory()
        let recorder = Recorder()
        let reconciler = Self.makeReconciler(store: store) { request in
            await recorder.addPost(request)
            return (Data(#"{"id":"msgbatch_1","processing_status":"in_progress","results_url":null}"#.utf8), 200)
        }

        try await reconciler.submit(transcript: "sess-1", messages: Self.turns(["first", "second"]))

        let pending = try #require(try await store.pendingBatch(forTranscript: "sess-1"))
        #expect(pending.batchID == "msgbatch_1")
        #expect(pending.minTurn == 0)
        #expect(pending.maxTurn == 1)

        let post = try #require(await recorder.posts.first)
        let body = try JSONSerialization.jsonObject(with: #require(post.httpBody)) as? [String: Any]
        let requests = try #require(body?["requests"] as? [[String: Any]])
        #expect(requests.map { $0["custom_id"] as? String } == ["0", "1"])
    }

    @Test("submit skips a transcript that already has a batch in flight")
    func submitSkipsWhenPending() async throws {
        let store = try GraphStore.inMemory()
        try await store.insertPendingBatch(batchID: "b0", transcript: "sess-1", minTurn: 0, maxTurn: 0)
        let recorder = Recorder()
        let reconciler = Self.makeReconciler(store: store) { request in
            await recorder.addPost(request)
            return (Data(#"{"id":"x","processing_status":"in_progress","results_url":null}"#.utf8), 200)
        }

        try await reconciler.submit(transcript: "sess-1", messages: Self.turns(["first", "second"]))

        #expect(await recorder.posts.isEmpty)
        #expect(try await store.pendingBatch(forTranscript: "sess-1")?.batchID == "b0")
    }

    @Test("submit only batches turns past the recorded progress")
    func submitOnlyBacklog() async throws {
        let store = try GraphStore.inMemory()
        try await store.advanceAssessProgress(identity: "sess-1", to: 0)
        let recorder = Recorder()
        let reconciler = Self.makeReconciler(store: store) { request in
            await recorder.addPost(request)
            return (Data(#"{"id":"msgbatch_2","processing_status":"in_progress","results_url":null}"#.utf8), 200)
        }

        try await reconciler.submit(transcript: "sess-1", messages: Self.turns(["first", "second", "third"]))

        let pending = try #require(try await store.pendingBatch(forTranscript: "sess-1"))
        #expect(pending.minTurn == 1)
        #expect(pending.maxTurn == 2)
        let post = try #require(await recorder.posts.first)
        let body = try JSONSerialization.jsonObject(with: #require(post.httpBody)) as? [String: Any]
        let requests = try #require(body?["requests"] as? [[String: Any]])
        #expect(requests.map { $0["custom_id"] as? String } == ["1", "2"])
    }

    @Test("submit does nothing when there is no backlog")
    func submitNoBacklog() async throws {
        let store = try GraphStore.inMemory()
        try await store.advanceAssessProgress(identity: "sess-1", to: 1)
        let recorder = Recorder()
        let reconciler = Self.makeReconciler(store: store) { request in
            await recorder.addPost(request)
            return (Data(#"{"id":"x","processing_status":"in_progress","results_url":null}"#.utf8), 200)
        }

        try await reconciler.submit(transcript: "sess-1", messages: Self.turns(["first", "second"]))
        #expect(await recorder.posts.isEmpty)
        #expect(try await store.pendingBatch(forTranscript: "sess-1") == nil)
    }

    // MARK: - Collect

    @Test("collect ingests succeeded turns, advances progress, and drops the pending row")
    func collectIngestsAndAdvances() async throws {
        let store = try GraphStore.inMemory()
        try await store.insertPendingBatch(batchID: "msgbatch_1", transcript: "sess-1", minTurn: 0, maxTurn: 1)

        let resultsURL = "https://api.anthropic.com/v1/messages/batches/msgbatch_1/results"
        let jsonl = [
            Self.lessonLine(customID: "0", seed: "yoga site"),
            Self.lessonLine(customID: "1", seed: "spa site"),
        ].joined(separator: "\n")
        let statusJSON = #"{"id":"msgbatch_1","processing_status":"ended","results_url":"\#(resultsURL)"}"#

        let reconciler = Self.makeReconciler(store: store) { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/results") { return (Data(jsonl.utf8), 200) }
            return (Data(statusJSON.utf8), 200)
        }

        try await reconciler.collect()

        #expect(try await edgeCount(store) == 2)
        #expect(try await store.assessProgress(for: "sess-1") == 1)
        #expect(try await store.pendingBatch(forTranscript: "sess-1") == nil)
    }

    @Test("collect stops at the first non-succeeded turn and re-enqueues the tail")
    func collectStopsAtGap() async throws {
        let store = try GraphStore.inMemory()
        try await store.insertPendingBatch(batchID: "msgbatch_1", transcript: "sess-1", minTurn: 0, maxTurn: 2)

        let resultsURL = "https://api.anthropic.com/v1/messages/batches/msgbatch_1/results"
        let jsonl = [
            Self.lessonLine(customID: "0", seed: "kept"),
            Self.erroredLine(customID: "1"),
            Self.lessonLine(customID: "2", seed: "discarded"),
        ].joined(separator: "\n")
        let statusJSON = #"{"id":"msgbatch_1","processing_status":"ended","results_url":"\#(resultsURL)"}"#

        let reconciler = Self.makeReconciler(store: store) { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/results") { return (Data(jsonl.utf8), 200) }
            return (Data(statusJSON.utf8), 200)
        }

        try await reconciler.collect()

        // Only turn 0 ingested; progress advances to 0; pending dropped so [1...2] re-enters the backlog.
        #expect(try await edgeCount(store) == 1)
        #expect(try await store.assessProgress(for: "sess-1") == 0)
        #expect(try await store.pendingBatch(forTranscript: "sess-1") == nil)
    }

    @Test("collect leaves an in-progress batch untouched")
    func collectLeavesInProgress() async throws {
        let store = try GraphStore.inMemory()
        try await store.insertPendingBatch(batchID: "msgbatch_1", transcript: "sess-1", minTurn: 0, maxTurn: 1)

        let reconciler = Self.makeReconciler(store: store) { _ in
            (Data(#"{"id":"msgbatch_1","processing_status":"in_progress","results_url":null}"#.utf8), 200)
        }

        try await reconciler.collect()

        #expect(try await edgeCount(store) == 0)
        #expect(try await store.assessProgress(for: "sess-1") == nil)
        #expect(try await store.pendingBatch(forTranscript: "sess-1")?.batchID == "msgbatch_1")
    }
}
