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
        }
        migrator.registerMigration("drop_acts") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS acts;")
        }
        migrator.registerMigration("v2_provenance_sessions") { db in
            try db.execute(sql: "ALTER TABLE edges ADD COLUMN source_transcript TEXT;")
            try db.execute(sql: "ALTER TABLE edges ADD COLUMN turn_index INTEGER;")
            try db.execute(sql: "ALTER TABLE edges ADD COLUMN source_excerpt TEXT;")
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                last_seen_at REAL NOT NULL
            );
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS session_injections (
                session_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                target_id TEXT NOT NULL,
                injected_at REAL NOT NULL,
                matched_text TEXT,
                PRIMARY KEY (session_id, source_id, target_id),
                FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE,
                FOREIGN KEY (source_id, target_id) REFERENCES edges(source_id, target_id) ON DELETE CASCADE
            );
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS session_injections_session_idx
                ON session_injections(session_id);
            """)
        }
        try migrator.migrate(queue)
    }
}
