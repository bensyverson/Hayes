import GRDB

extension GraphStore {
    /// Runs the schema migration for a fresh or existing database.
    /// - Parameter queue: The database queue.
    static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS nodes (
                id TEXT PRIMARY KEY NOT NULL,
                text TEXT NOT NULL,
                embedding BLOB NOT NULL
            );
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS edges (
                source_id TEXT NOT NULL,
                target_id TEXT NOT NULL,
                weight REAL NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (source_id, target_id)
            );
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS edges_source_idx ON edges(source_id);
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS edges_weight_idx ON edges(weight DESC);
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS acts (
                id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                seed_ids TEXT NOT NULL,
                behavior_ids TEXT NOT NULL,
                status TEXT NOT NULL
            );
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS acts_created_idx ON acts(created_at DESC);
            """)
        }
        try migrator.migrate(queue)
    }
}
