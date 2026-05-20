import Foundation
@testable import HayesCore
import Operator
import Testing

@Suite("AnthropicBatchClient")
struct AnthropicBatchClientTests {
    /// A minimal analyzer-shaped request body.
    private static func sampleParams() -> LLM.OpenAICompatibleAPI.ChatCompletion {
        LLM.OpenAICompatibleAPI.ChatCompletion(
            model: ModelName(rawValue: "claude-haiku-4-5"),
            messages: [ChatMessage(content: "hello", role: .user)]
        )
    }

    /// Records the requests a stub transport receives.
    private actor Recorder {
        private(set) var requests: [URLRequest] = []
        func add(_ request: URLRequest) {
            requests.append(request)
        }
    }

    @Test("submit posts to /v1/messages/batches with auth headers and returns the batch id")
    func submitBuildsRequestAndParsesID() async throws {
        let recorder = Recorder()
        let response = Data(#"{"id":"msgbatch_123","processing_status":"in_progress","results_url":null}"#.utf8)
        let client = AnthropicBatchClient(apiKey: "sk-test") { request in
            await recorder.add(request)
            return (response, 200)
        }

        let id = try await client.submit([
            AnthropicBatchClient.Request(customID: "0", params: Self.sampleParams()),
        ])
        #expect(id == "msgbatch_123")

        let request = try #require(await recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages/batches")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") != nil)

        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let requests = try #require(json?["requests"] as? [[String: Any]])
        #expect(requests.count == 1)
        #expect(requests[0]["custom_id"] as? String == "0")
        // params must embed the request as a nested JSON object, not a string.
        let params = requests[0]["params"] as? [String: Any]
        #expect(params?["messages"] != nil)
    }

    @Test("status parses the processing status and results url")
    func statusParsesEnded() async throws {
        let response = Data(#"""
        {"id":"msgbatch_1","processing_status":"ended","results_url":"https://api.anthropic.com/v1/messages/batches/msgbatch_1/results"}
        """#.utf8)
        let client = AnthropicBatchClient(apiKey: "k") { _ in (response, 200) }

        let status = try await client.status(batchID: "msgbatch_1")
        #expect(status.processingStatus == .ended)
        #expect(status.resultsURL == "https://api.anthropic.com/v1/messages/batches/msgbatch_1/results")
    }

    @Test("status reports an in-progress batch with no results url yet")
    func statusParsesInProgress() async throws {
        let response = Data(#"{"id":"msgbatch_1","processing_status":"in_progress","results_url":null}"#.utf8)
        let client = AnthropicBatchClient(apiKey: "k") { _ in (response, 200) }

        let status = try await client.status(batchID: "msgbatch_1")
        #expect(status.processingStatus == .inProgress)
        #expect(status.resultsURL == nil)
    }

    @Test("results parses JSONL into per-request entries with extracted analysis")
    func resultsParsesJSONL() async throws {
        let jsonl = [
            #"{"custom_id":"0","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"t1","name":"submit_analysis","input":{"lessons":[{"seed":"yoga site","behavior":"calm palette","sentiment":0.8,"source":"user"}]}}]}}}"#,
            #"{"custom_id":"1","result":{"type":"succeeded","message":{"content":[{"type":"tool_use","id":"t2","name":"submit_analysis","input":{"lessons":[]}}]}}}"#,
            #"{"custom_id":"2","result":{"type":"errored"}}"#,
        ].joined(separator: "\n")
        let client = AnthropicBatchClient(apiKey: "k") { _ in (Data(jsonl.utf8), 200) }

        let entries = try await client.results(at: "https://api.anthropic.com/v1/messages/batches/x/results")
        #expect(entries.count == 3)

        #expect(entries[0].customID == "0")
        guard case let .succeeded(r0) = entries[0].outcome else {
            Issue.record("entry 0 should be succeeded")
            return
        }
        #expect(r0.lessons.count == 1)
        #expect(r0.lessons.first?.seed == "yoga site")

        #expect(entries[1].customID == "1")
        guard case let .succeeded(r1) = entries[1].outcome else {
            Issue.record("entry 1 should be succeeded")
            return
        }
        #expect(r1.lessons.isEmpty)

        #expect(entries[2].customID == "2")
        #expect(entries[2].outcome == .errored)
    }

    @Test("a non-2xx response throws a clear http error")
    func httpErrorThrows() async throws {
        let client = AnthropicBatchClient(apiKey: "k") { _ in (Data("nope".utf8), 400) }
        await #expect(throws: AnthropicBatchClient.BatchError.http(status: 400)) {
            _ = try await client.submit([
                AnthropicBatchClient.Request(customID: "0", params: Self.sampleParams()),
            ])
        }
    }
}
