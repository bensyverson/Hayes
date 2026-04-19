import Foundation

/// An ``LLMClient`` decorator that appends each call's inputs and
/// response to a JSONL log file.
///
/// Used for ad-hoc debugging of the memory pipeline — e.g. diagnosing
/// why `AnalysisRunner` is returning empty `moves` despite a
/// substantial turn. Writes one JSON object per line so the file
/// stays tail-readable.
///
/// Writes are serialised through a shared ``LogWriter`` actor so
/// multiple wrappers (one per stage) can safely target the same file.
public struct LoggingLLMClient: LLMClient {
    private let inner: any LLMClient
    private let stage: String
    private let writer: LogWriter

    /// Creates a new wrapper.
    /// - Parameters:
    ///   - inner: The underlying client to forward calls to.
    ///   - stage: A short label recorded on every entry so multiple
    ///     wrappers sharing a writer (extractor, analyzer) can be
    ///     told apart in the log.
    ///   - writer: The destination for log entries. Share a single
    ///     writer across wrappers to keep entries ordered.
    public init(
        wrapping inner: any LLMClient,
        stage: String,
        writer: LogWriter
    ) {
        self.inner = inner
        self.stage = stage
        self.writer = writer
    }

    public func complete(systemPrompt: String, userMessage: String) async throws -> String {
        let timestamp = Date()
        do {
            let response = try await inner.complete(
                systemPrompt: systemPrompt,
                userMessage: userMessage
            )
            await writer.append(LogEntry(
                stage: stage,
                timestamp: timestamp,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                response: response,
                error: nil
            ))
            return response
        } catch {
            await writer.append(LogEntry(
                stage: stage,
                timestamp: timestamp,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                response: nil,
                error: String(describing: error)
            ))
            throw error
        }
    }

    /// A single log entry.
    public struct LogEntry: Friendly {
        /// Short label identifying which memory stage emitted the call.
        public let stage: String
        /// When the call was initiated (ISO-8601 on encode).
        public let timestamp: Date
        /// The system prompt sent to the LLM.
        public let systemPrompt: String
        /// The user-role payload sent to the LLM.
        public let userMessage: String
        /// The accumulated assistant text on success. `nil` on error.
        public let response: String?
        /// The error description on failure. `nil` on success.
        public let error: String?

        /// Creates a new entry.
        /// - Parameters:
        ///   - stage: A short stage label (e.g. `"extractor"`).
        ///   - timestamp: When the call was initiated.
        ///   - systemPrompt: The system prompt sent to the LLM.
        ///   - userMessage: The user-role payload sent to the LLM.
        ///   - response: The assistant's text on success.
        ///   - error: The error description on failure.
        public init(
            stage: String,
            timestamp: Date,
            systemPrompt: String,
            userMessage: String,
            response: String?,
            error: String?
        ) {
            self.stage = stage
            self.timestamp = timestamp
            self.systemPrompt = systemPrompt
            self.userMessage = userMessage
            self.response = response
            self.error = error
        }
    }

    /// Serialised JSONL writer, shared across ``LoggingLLMClient``
    /// wrappers that target the same file.
    public actor LogWriter {
        private let url: URL
        private let encoder: JSONEncoder

        /// Creates a new writer for `url`. The file is created if it
        /// does not exist; new entries are appended.
        /// - Parameter url: The destination file path.
        public init(url: URL) {
            self.url = url
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes]
            self.encoder = encoder
        }

        /// Appends one entry as a single JSONL line. Swallows write
        /// errors — the logger must not destabilise the pipeline it
        /// observes.
        public func append(_ entry: LogEntry) {
            guard let data = try? encoder.encode(entry) else { return }
            var line = data
            line.append(0x0A) // newline

            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: line)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                return
            }
        }
    }
}
