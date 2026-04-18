import Foundation
import GRDB

/// An actor-guarded SQLite-backed store for the memory graph.
///
/// `GraphStore` owns a `DatabaseQueue` and an in-memory cache of node embeddings.
/// The cache is populated on `init` and kept in sync on every `insertNode`,
/// so retrieval can run cosine similarity against the full corpus without
/// touching the database on the query path.
///
/// Use ``init(path:idGenerator:)`` to open a file-backed store, or
/// ``inMemory(idGenerator:)`` for tests.
public actor GraphStore {
    private let dbQueue: DatabaseQueue
    private var embeddingCache: [String: [Float]] = [:]
    private let idGenerator: @Sendable () -> String
    private static let maxIDRetries: Int = 5

    /// Errors produced by ``GraphStore`` operations.
    public enum Error: Swift.Error, Sendable {
        /// A primary-key collision could not be resolved within the retry budget.
        case idCollisionExhausted
        /// The referenced node does not exist.
        case nodeNotFound(id: String)
        /// The referenced edge does not exist.
        case edgeNotFound(sourceID: String, targetID: String)
        /// The referenced act does not exist.
        case actNotFound(id: String)
    }

    /// Opens a file-backed graph store at `path`.
    ///
    /// Creates parent directories as needed. Runs the schema migration on first open.
    /// Warms the in-memory embedding cache from the stored nodes.
    /// - Parameter path: The SQLite file URL.
    /// - Parameter idGenerator: Optional ID generator override (defaults to ``NodeID/make()``).
    public init(path: URL, idGenerator: @escaping @Sendable () -> String = { NodeID.make() }) throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: path.path)
        try GraphStore.migrate(queue)
        dbQueue = queue
        self.idGenerator = idGenerator
        embeddingCache = try GraphStore.loadEmbeddingCache(queue)
    }

    private init(queue: DatabaseQueue, idGenerator: @escaping @Sendable () -> String) throws {
        try GraphStore.migrate(queue)
        dbQueue = queue
        self.idGenerator = idGenerator
        embeddingCache = try GraphStore.loadEmbeddingCache(queue)
    }

    /// Creates an in-memory store, useful for tests.
    /// - Parameter idGenerator: Optional ID generator override.
    /// - Returns: A fresh in-memory ``GraphStore``.
    public static func inMemory(
        idGenerator: @escaping @Sendable () -> String = { NodeID.make() }
    ) throws -> GraphStore {
        let queue = try DatabaseQueue()
        return try GraphStore(queue: queue, idGenerator: idGenerator)
    }

    /// Exposed for extension files.
    nonisolated var database: DatabaseQueue {
        dbQueue
    }

    func embeddingSnapshot() -> [String: [Float]] {
        embeddingCache
    }

    func cacheEmbedding(id: String, embedding: [Float]) {
        embeddingCache[id] = embedding
    }

    func nextID() -> String {
        idGenerator()
    }

    private static func loadEmbeddingCache(_ queue: DatabaseQueue) throws -> [String: [Float]] {
        try queue.read { db in
            var cache: [String: [Float]] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT id, embedding FROM nodes")
            for row in rows {
                let id: String = row["id"]
                let data: Data = row["embedding"] ?? Data()
                cache[id] = floatsFromData(data)
            }
            return cache
        }
    }
}

/// Converts a `[Float]` to `Data` for BLOB storage.
/// - Parameter floats: The float array.
/// - Returns: The little-endian raw bytes.
func dataFromFloats(_ floats: [Float]) -> Data {
    floats.withUnsafeBufferPointer { buffer in
        Data(buffer: buffer)
    }
}

/// Converts raw `Data` back to a `[Float]`.
/// - Parameter data: The raw BLOB bytes.
/// - Returns: The reconstructed float array.
func floatsFromData(_ data: Data) -> [Float] {
    guard !data.isEmpty else { return [] }
    let count = data.count / MemoryLayout<Float>.size
    return data.withUnsafeBytes { raw in
        Array(UnsafeBufferPointer(
            start: raw.bindMemory(to: Float.self).baseAddress,
            count: count
        ))
    }
}
