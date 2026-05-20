import Foundation
import Operator

/// A minimal client for Anthropic's Message Batches API, scoped to what
/// the batch assess path needs: submit a set of analyzer requests, poll a
/// batch's status, and decode its results into ``AnalysisResult``s.
///
/// The HTTP transport is injectable (``Send``) so the request construction
/// and response parsing are testable without a network. The default
/// transport uses `URLSession`. Each analyzer request's body is an
/// `LLM.OpenAICompatibleAPI.ChatCompletion` built by
/// `Operative.requestBody(for:provider:)`, so a batched request is byte-for-byte
/// the request the live analyzer would send.
///
/// See `project/2026-05-20-batch-assess-pipeline.md`.
public struct AnthropicBatchClient: Sendable {
    /// An injectable HTTP transport: given a request, return the response
    /// body and its HTTP status code. The status code (not `HTTPURLResponse`)
    /// crosses the boundary so the closure stays `Sendable`.
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)

    /// One analyzer request to include in a batch.
    ///
    /// Not `Sendable`: it wraps `LLM.OpenAICompatibleAPI.ChatCompletion`,
    /// which isn't `Sendable`. It never crosses an isolation boundary — only
    /// the encoded `URLRequest` reaches the transport — so this is safe.
    public struct Request {
        /// Unique-within-the-batch id used to map a result back to its turn.
        public let customID: String
        /// The analyzer request body, embedded as the batch request's `params`.
        public let params: LLM.OpenAICompatibleAPI.ChatCompletion

        /// Creates a batch request item.
        public init(customID: String, params: LLM.OpenAICompatibleAPI.ChatCompletion) {
            self.customID = customID
            self.params = params
        }
    }

    /// A batch's processing status, mirroring Anthropic's `processing_status`.
    public enum ProcessingStatus: String, Sendable {
        case inProgress = "in_progress"
        case canceling
        case ended
    }

    /// A batch's status snapshot.
    public struct Status: Sendable, Equatable {
        /// Where the batch is in its lifecycle.
        public let processingStatus: ProcessingStatus
        /// The URL to fetch results from, present once `processingStatus`
        /// is ``ProcessingStatus/ended``.
        public let resultsURL: String?
    }

    /// A single request's result within a batch.
    public struct Entry: Sendable, Equatable {
        /// The ``Request/customID`` this result corresponds to.
        public let customID: String
        /// What became of the request.
        public let outcome: Outcome
    }

    /// The disposition of one batched request.
    public enum Outcome: Sendable, Equatable {
        /// The request completed; carries the distilled analysis (empty
        /// when the model called `submit_analysis` with no lessons, or did
        /// not call it at all).
        case succeeded(AnalysisResult)
        /// The request errored.
        case errored
        /// The request was canceled.
        case canceled
        /// The request expired before processing.
        case expired
    }

    /// Errors thrown by the client.
    public enum BatchError: Error, Sendable, Equatable {
        /// A non-2xx HTTP response.
        case http(status: Int)
        /// A response that couldn't be decoded as expected.
        case malformedResponse(String)
    }

    private let apiKey: String
    private let baseURL: URL
    private let anthropicVersion: String
    private let send: Send

    /// Creates a client.
    /// - Parameters:
    ///   - apiKey: The Anthropic API key.
    ///   - baseURL: The API base URL. Defaults to `https://api.anthropic.com`.
    ///   - anthropicVersion: The `anthropic-version` header value.
    ///   - send: The HTTP transport. Defaults to a `URLSession`-backed sender.
    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        anthropicVersion: String = "2023-06-01",
        send: @escaping Send = AnthropicBatchClient.liveSend
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.anthropicVersion = anthropicVersion
        self.send = send
    }

    // MARK: - Operations

    /// Submits `requests` as one batch and returns the batch id.
    public func submit(_ requests: [Request]) async throws -> String {
        let body = SubmitBody(requests: requests.map { item in
            SubmitBody.Item(custom_id: item.customID, params: item.params)
        })
        var request = makeRequest(path: "v1/messages/batches", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)

        let object = try await fetch(BatchObject.self, request: request)
        return object.id
    }

    /// Fetches the current status of `batchID`.
    public func status(batchID: String) async throws -> Status {
        let request = makeRequest(path: "v1/messages/batches/\(batchID)", method: "GET")
        let object = try await fetch(BatchObject.self, request: request)
        guard let status = ProcessingStatus(rawValue: object.processing_status) else {
            throw BatchError.malformedResponse("unknown processing_status \"\(object.processing_status)\"")
        }
        return Status(processingStatus: status, resultsURL: object.results_url)
    }

    /// Fetches and decodes the JSONL results at `resultsURL`.
    public func results(at resultsURL: String) async throws -> [Entry] {
        guard let url = URL(string: resultsURL) else {
            throw BatchError.malformedResponse("invalid results_url \"\(resultsURL)\"")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request)

        let (data, code) = try await send(request)
        guard (200 ..< 300).contains(code) else { throw BatchError.http(status: code) }

        let decoder = JSONDecoder()
        let text = String(decoding: data, as: UTF8.self)
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let result = try decoder.decode(ResultLine.self, from: Data(line.utf8))
                return Entry(customID: result.custom_id, outcome: result.result.toOutcome())
            }
    }

    /// The default `URLSession`-backed transport.
    public static let liveSend: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, code)
    }

    // MARK: - Request building

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        applyAuthHeaders(to: &request)
        return request
    }

    private func applyAuthHeaders(to request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
    }

    private func fetch<T: Decodable>(_: T.Type, request: URLRequest) async throws -> T {
        let (data, code) = try await send(request)
        guard (200 ..< 300).contains(code) else { throw BatchError.http(status: code) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BatchError.malformedResponse(String(describing: error))
        }
    }

    // MARK: - Wire types

    private struct SubmitBody: Encodable {
        let requests: [Item]
        struct Item: Encodable {
            let custom_id: String
            let params: LLM.OpenAICompatibleAPI.ChatCompletion
        }
    }

    private struct BatchObject: Decodable {
        let id: String
        let processing_status: String
        let results_url: String?
    }

    private struct ResultLine: Decodable {
        let custom_id: String
        let result: ResultBody

        struct ResultBody: Decodable {
            let type: String
            let message: ResultMessage?

            func toOutcome() -> Outcome {
                switch type {
                case "succeeded": .succeeded(message?.analysisResult() ?? .empty)
                case "canceled": .canceled
                case "expired": .expired
                default: .errored
                }
            }
        }
    }

    private struct ResultMessage: Decodable {
        let content: [Block]

        struct Block: Decodable {
            let type: String
            let name: String?
            let input: AnalysisInput?
        }

        /// Extracts the `submit_analysis` tool call's distilled analysis,
        /// or an empty result if the model didn't call it.
        func analysisResult() -> AnalysisResult {
            for block in content where block.type == "tool_use" && block.name == "submit_analysis" {
                if let input = block.input { return input.toAnalysisResult() }
            }
            return .empty
        }
    }
}

private extension AnalysisResult {
    /// An analysis with no lessons.
    static let empty: AnalysisResult = .init(lessons: [])
}
