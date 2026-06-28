//
//  ClickyWorkflowStore.swift
//  leanring-buddy
//
//  Local SQLite + FTS5 store for recorded workflow screen states.
//

import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ClickyWorkflowStore {
    private var database: OpaquePointer?
    private let databaseURL: URL

    init(databaseURL: URL = ClickyWorkflowPaths.databaseURL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: ClickyWorkflowPaths.thumbnailsDirectory,
            withIntermediateDirectories: true
        )

        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            throw storeError("Could not open workflow database.")
        }

        try executeSQL("PRAGMA foreign_keys = ON;")

        try executeSQL("""
        CREATE TABLE IF NOT EXISTS workflows (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            summary TEXT NOT NULL DEFAULT '',
            goal TEXT NOT NULL DEFAULT '',
            trigger_phrases_json TEXT NOT NULL DEFAULT '[]',
            recorded_at REAL NOT NULL,
            state_count INTEGER NOT NULL DEFAULT 0
        );
        """)

        try executeSQL("""
        CREATE TABLE IF NOT EXISTS screen_states (
            id TEXT PRIMARY KEY,
            workflow_id TEXT NOT NULL,
            step_index INTEGER NOT NULL,
            name TEXT NOT NULL,
            app TEXT NOT NULL,
            url_pattern TEXT,
            window_title_pattern TEXT,
            meaning TEXT NOT NULL,
            user_intent TEXT NOT NULL DEFAULT '',
            spoken_description TEXT NOT NULL DEFAULT '',
            is_entry_state INTEGER NOT NULL DEFAULT 0,
            ocr_terms_json TEXT NOT NULL DEFAULT '[]',
            common_questions_json TEXT NOT NULL DEFAULT '[]',
            related_sop_ids_json TEXT NOT NULL DEFAULT '[]',
            thumbnail_filename TEXT NOT NULL,
            captured_at REAL NOT NULL,
            FOREIGN KEY(workflow_id) REFERENCES workflows(id) ON DELETE CASCADE
        );
        """)

        try migrateSchemaIfNeeded()

        try executeSQL("""
        CREATE TABLE IF NOT EXISTS workflow_search (
            rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            workflow_id TEXT NOT NULL,
            state_id TEXT,
            kind TEXT NOT NULL,
            search_text TEXT NOT NULL
        );
        """)

        try executeSQL("""
        CREATE VIRTUAL TABLE IF NOT EXISTS workflow_search_fts USING fts5(
            search_text,
            workflow_id UNINDEXED,
            state_id UNINDEXED,
            kind UNINDEXED,
            content='workflow_search',
            content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2'
        );
        """)

        try createFTSTriggersIfNeeded()
        try executeSQL("""
        CREATE INDEX IF NOT EXISTS idx_screen_states_workflow
        ON screen_states(workflow_id, step_index);
        """)

        try purgeOrphanedRecords()
    }

    deinit {
        if database != nil {
            sqlite3_close(database)
        }
    }

    func upsertWorkflow(_ workflow: ClickyWorkflow, states: [ClickyWorkflowScreenState]) throws {
        try executeSQL(
            """
            INSERT INTO workflows (id, name, summary, goal, trigger_phrases_json, recorded_at, state_count, source, source_document_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                summary = excluded.summary,
                goal = excluded.goal,
                trigger_phrases_json = excluded.trigger_phrases_json,
                recorded_at = excluded.recorded_at,
                state_count = excluded.state_count,
                source = excluded.source,
                source_document_id = excluded.source_document_id;
            """,
            bindings: [
                .text(workflow.id),
                .text(workflow.name),
                .text(workflow.summary),
                .text(workflow.goal),
                .text(encodeJSON(workflow.triggerPhrases)),
                .double(workflow.recordedAt.timeIntervalSince1970),
                .int(workflow.stateCount),
                .text(workflow.source.rawValue),
                .text(workflow.sourceDocumentID),
            ]
        )

        try executeSQL(
            "DELETE FROM screen_states WHERE workflow_id = ?;",
            bindings: [.text(workflow.id)]
        )

        for state in states {
            try executeSQL(
                """
                INSERT INTO screen_states (
                    id, workflow_id, step_index, name, app, url_pattern, window_title_pattern,
                    meaning, user_intent, spoken_description, is_entry_state,
                    ocr_terms_json, common_questions_json,
                    related_sop_ids_json, visual_fingerprint, thumbnail_filename, captured_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(state.id),
                    .text(state.workflowID),
                    .int(state.stepIndex),
                    .text(state.name),
                    .text(state.app),
                    .text(state.urlPattern),
                    .text(state.windowTitlePattern),
                    .text(state.meaning),
                    .text(state.userIntent),
                    .text(state.spokenDescription),
                    .int(state.isEntryState ? 1 : 0),
                    .text(encodeJSON(state.ocrTerms)),
                    .text(encodeJSON(state.commonQuestions)),
                    .text(encodeJSON(state.relatedSOPIDs)),
                    .text(state.visualFingerprint),
                    .text(state.thumbnailFilename),
                    .double(state.capturedAt.timeIntervalSince1970),
                ]
            )
        }

        try rebuildSearchIndex(for: workflow, states: states)
    }

    func search(query: String, limit: Int = 5) throws -> [ClickyWorkflowSearchHit] {
        let ftsQuery = Self.ftsQuery(from: query)
        guard !ftsQuery.isEmpty else { return [] }

        let sql = """
        SELECT
            workflow_id,
            state_id,
            kind,
            search_text,
            bm25(workflow_search_fts) AS score
        FROM workflow_search_fts
        WHERE workflow_search_fts MATCH ?
        ORDER BY score
        LIMIT ?;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not prepare workflow search.")
        }

        sqlite3_bind_text(statement, 1, ftsQuery, -1, sqliteTransientDestructor)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var hits: [ClickyWorkflowSearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            hits.append(
                ClickyWorkflowSearchHit(
                    workflowID: stringColumn(statement, 0),
                    stateID: optionalStringColumn(statement, 1),
                    kind: stringColumn(statement, 2),
                    searchText: stringColumn(statement, 3),
                    relevanceScore: sqlite3_column_double(statement, 4)
                )
            )
        }
        return hits
    }

    func workflows(withSourceDocumentID documentID: String) throws -> [ClickyWorkflow] {
        try queryWorkflows(
            sql: """
            SELECT id, name, summary, goal, trigger_phrases_json, recorded_at, state_count, source, source_document_id
            FROM workflows WHERE source_document_id = ? ORDER BY recorded_at DESC;
            """,
            bindings: [.text(documentID)]
        )
    }

    func allWorkflows() throws -> [ClickyWorkflow] {
        try queryWorkflows(sql: """
            SELECT id, name, summary, goal, trigger_phrases_json, recorded_at, state_count, source, source_document_id
            FROM workflows ORDER BY recorded_at DESC;
            """)
    }

    func workflow(withID workflowID: String) throws -> ClickyWorkflow? {
        try queryWorkflows(
            sql: """
            SELECT id, name, summary, goal, trigger_phrases_json, recorded_at, state_count, source, source_document_id
            FROM workflows WHERE id = ? LIMIT 1;
            """,
            bindings: [.text(workflowID)]
        ).first
    }

    func screenStates(forWorkflowID workflowID: String) throws -> [ClickyWorkflowScreenState] {
        try queryScreenStates(
            sql: """
            SELECT id, workflow_id, step_index, name, app, url_pattern, window_title_pattern,
                   meaning, user_intent, spoken_description, is_entry_state,
                   ocr_terms_json, common_questions_json,
                   related_sop_ids_json, visual_fingerprint, thumbnail_filename, captured_at
            FROM screen_states
            WHERE workflow_id = ?
            ORDER BY step_index ASC;
            """,
            bindings: [.text(workflowID)]
        )
    }

    func allScreenStates() throws -> [ClickyWorkflowScreenState] {
        try queryScreenStates(
            sql: """
            SELECT id, workflow_id, step_index, name, app, url_pattern, window_title_pattern,
                   meaning, user_intent, spoken_description, is_entry_state,
                   ocr_terms_json, common_questions_json,
                   related_sop_ids_json, visual_fingerprint, thumbnail_filename, captured_at
            FROM screen_states
            WHERE workflow_id IN (SELECT id FROM workflows)
            ORDER BY captured_at DESC;
            """
        )
    }

    func workflowCount() throws -> Int {
        try scalarInt(sql: "SELECT COUNT(*) FROM workflows;")
    }

    func screenStateCount() throws -> Int {
        try scalarInt(sql: """
            SELECT COUNT(*)
            FROM screen_states
            WHERE workflow_id IN (SELECT id FROM workflows);
            """)
    }

    /// Removes screen states and search rows whose parent workflow no longer exists.
    func purgeOrphanedRecords() throws {
        let orphanedStates = try queryScreenStates(sql: """
            SELECT id, workflow_id, step_index, name, app, url_pattern, window_title_pattern,
                   meaning, user_intent, spoken_description, is_entry_state,
                   ocr_terms_json, common_questions_json,
                   related_sop_ids_json, visual_fingerprint, thumbnail_filename, captured_at
            FROM screen_states
            WHERE workflow_id NOT IN (SELECT id FROM workflows);
            """)

        for state in orphanedStates {
            ClickyWorkflowPaths.removeWorkflowAsset(at: state.thumbnailURL)
        }

        guard !orphanedStates.isEmpty else { return }

        print("🎬 Purging \(orphanedStates.count) orphaned workflow screen state(s)")

        try executeSQL("""
            DELETE FROM screen_states
            WHERE workflow_id NOT IN (SELECT id FROM workflows);
            """)
        try executeSQL("""
            DELETE FROM workflow_search
            WHERE workflow_id NOT IN (SELECT id FROM workflows);
            """)
    }

    func deleteWorkflow(id: String) throws {
        let states = try screenStates(forWorkflowID: id)
        for state in states {
            ClickyWorkflowPaths.removeWorkflowAsset(at: state.thumbnailURL)
        }

        // Also sweep by workflow ID prefix — catches orphans and DB/file mismatches.
        ClickyWorkflowPaths.deleteAssets(forWorkflowID: id)

        try executeSQL("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try executeSQL(
                "DELETE FROM screen_states WHERE workflow_id = ?;",
                bindings: [.text(id)]
            )
            try executeSQL(
                "DELETE FROM workflow_search WHERE workflow_id = ?;",
                bindings: [.text(id)]
            )
            try executeSQL(
                "DELETE FROM workflows WHERE id = ?;",
                bindings: [.text(id)]
            )
            try executeSQL("COMMIT;")
        } catch {
            try? executeSQL("ROLLBACK;")
            throw error
        }

        try purgeOrphanedRecords()

        // Reclaim disk space — SQLite keeps deleted pages until VACUUM.
        try? executeSQL("PRAGMA wal_checkpoint(TRUNCATE);")
        try? executeSQL("VACUUM;")
    }

    func deleteScreenState(id: String) throws {
        if let state = try allScreenStates().first(where: { $0.id == id }) {
            ClickyWorkflowPaths.removeWorkflowAsset(at: state.thumbnailURL)
        }
        try executeSQL(
            "DELETE FROM screen_states WHERE id = ?;",
            bindings: [.text(id)]
        )
    }

    // MARK: - Schema + FTS

    private func migrateSchemaIfNeeded() throws {
        try? executeSQL("ALTER TABLE workflows ADD COLUMN goal TEXT NOT NULL DEFAULT '';")
        try? executeSQL("ALTER TABLE workflows ADD COLUMN trigger_phrases_json TEXT NOT NULL DEFAULT '[]';")
        try? executeSQL("ALTER TABLE screen_states ADD COLUMN spoken_description TEXT NOT NULL DEFAULT '';")
        try? executeSQL("ALTER TABLE screen_states ADD COLUMN is_entry_state INTEGER NOT NULL DEFAULT 0;")
        try? executeSQL("ALTER TABLE screen_states ADD COLUMN visual_fingerprint TEXT NOT NULL DEFAULT '';")
        try? executeSQL("ALTER TABLE workflows ADD COLUMN source TEXT NOT NULL DEFAULT 'recorded';")
        try? executeSQL("ALTER TABLE workflows ADD COLUMN source_document_id TEXT;")
    }

    private func createFTSTriggersIfNeeded() throws {
        let triggers = [
            """
            CREATE TRIGGER IF NOT EXISTS workflow_search_ai AFTER INSERT ON workflow_search BEGIN
                INSERT INTO workflow_search_fts(rowid, search_text, workflow_id, state_id, kind)
                VALUES (new.rowid, new.search_text, new.workflow_id, new.state_id, new.kind);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS workflow_search_ad AFTER DELETE ON workflow_search BEGIN
                INSERT INTO workflow_search_fts(workflow_search_fts, rowid, search_text, workflow_id, state_id, kind)
                VALUES ('delete', old.rowid, old.search_text, old.workflow_id, old.state_id, old.kind);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS workflow_search_au AFTER UPDATE ON workflow_search BEGIN
                INSERT INTO workflow_search_fts(workflow_search_fts, rowid, search_text, workflow_id, state_id, kind)
                VALUES ('delete', old.rowid, old.search_text, old.workflow_id, old.state_id, old.kind);
                INSERT INTO workflow_search_fts(rowid, search_text, workflow_id, state_id, kind)
                VALUES (new.rowid, new.search_text, new.workflow_id, new.state_id, new.kind);
            END;
            """,
        ]

        for trigger in triggers {
            try executeSQL(trigger)
        }
    }

    private func rebuildSearchIndex(for workflow: ClickyWorkflow, states: [ClickyWorkflowScreenState]) throws {
        try executeSQL(
            "DELETE FROM workflow_search WHERE workflow_id = ?;",
            bindings: [.text(workflow.id)]
        )

        var rows: [(kind: String, stateID: String?, text: String)] = [
            ("workflow_name", nil, workflow.name),
            ("workflow_summary", nil, workflow.summary),
            ("workflow_goal", nil, workflow.goal),
        ]

        for phrase in workflow.triggerPhrases where !phrase.isEmpty {
            rows.append(("workflow_trigger", nil, phrase))
        }

        for state in states {
            rows.append(("state_name", state.id, state.name))
            rows.append(("state_meaning", state.id, state.meaning))
            rows.append(("state_intent", state.id, state.userIntent))
            if !state.spokenDescription.isEmpty {
                rows.append(("state_narration", state.id, state.spokenDescription))
            }
            for question in state.commonQuestions where !question.isEmpty {
                rows.append(("state_question", state.id, question))
            }
            for term in state.ocrTerms where !term.isEmpty {
                rows.append(("state_ocr", state.id, term))
            }
        }

        for row in rows {
            let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            try executeSQL(
                """
                INSERT INTO workflow_search (workflow_id, state_id, kind, search_text)
                VALUES (?, ?, ?, ?);
                """,
                bindings: [
                    .text(workflow.id),
                    .text(row.stateID),
                    .text(row.kind),
                    .text(trimmed),
                ]
            )
        }
    }

    private static func ftsQuery(from rawQuery: String) -> String {
        let terms = rawQuery
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .filter { !searchStopWords.contains($0) }

        guard !terms.isEmpty else { return "" }

        let quotedTerms = terms.prefix(8).map { "\"\($0)\"" }
        if quotedTerms.count == 1 {
            return quotedTerms[0]
        }
        return quotedTerms.joined(separator: " OR ")
    }

    private static let searchStopWords: Set<String> = [
        "about", "and", "are", "can", "clicky", "could", "does", "for", "from",
        "have", "help", "hey", "how", "just", "need", "please", "that", "the",
        "this", "what", "when", "where", "which", "will", "with", "would", "you",
        "your",
    ]

    // MARK: - SQLite helpers

    private enum SQLBinding {
        case text(String?)
        case int(Int)
        case double(Double)
    }

    private func executeSQL(_ sql: String, bindings: [SQLBinding] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not prepare SQL.")
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw storeError("Could not execute SQL.")
        }
    }

    private func bind(_ bindings: [SQLBinding], to statement: OpaquePointer?) throws {
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case .text(let value):
                if let value {
                    _ = value.withCString { sqlite3_bind_text(statement, position, $0, -1, sqliteTransientDestructor) }
                } else {
                    sqlite3_bind_null(statement, position)
                }
            case .int(let value):
                sqlite3_bind_int(statement, position, Int32(value))
            case .double(let value):
                sqlite3_bind_double(statement, position, value)
            }
        }
    }

    private func queryWorkflows(sql: String, bindings: [SQLBinding] = []) throws -> [ClickyWorkflow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not prepare workflow query.")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var workflows: [ClickyWorkflow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            workflows.append(
                ClickyWorkflow(
                    id: stringColumn(statement, 0),
                    name: stringColumn(statement, 1),
                    summary: stringColumn(statement, 2),
                    goal: stringColumn(statement, 3),
                    triggerPhrases: decodeStringArray(stringColumn(statement, 4)),
                    recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    stateCount: Int(sqlite3_column_int(statement, 6)),
                    source: ClickyWorkflowSource(rawValue: stringColumn(statement, 7)) ?? .recorded,
                    sourceDocumentID: optionalStringColumn(statement, 8)
                )
            )
        }
        return workflows
    }

    private func queryScreenStates(sql: String, bindings: [SQLBinding] = []) throws -> [ClickyWorkflowScreenState] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not prepare screen state query.")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var states: [ClickyWorkflowScreenState] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            states.append(
                ClickyWorkflowScreenState(
                    id: stringColumn(statement, 0),
                    workflowID: stringColumn(statement, 1),
                    stepIndex: Int(sqlite3_column_int(statement, 2)),
                    name: stringColumn(statement, 3),
                    app: stringColumn(statement, 4),
                    urlPattern: optionalStringColumn(statement, 5),
                    windowTitlePattern: optionalStringColumn(statement, 6),
                    meaning: stringColumn(statement, 7),
                    userIntent: stringColumn(statement, 8),
                    spokenDescription: stringColumn(statement, 9),
                    isEntryState: sqlite3_column_int(statement, 10) != 0,
                    ocrTerms: decodeStringArray(stringColumn(statement, 11)),
                    commonQuestions: decodeStringArray(stringColumn(statement, 12)),
                    relatedSOPIDs: decodeStringArray(stringColumn(statement, 13)),
                    visualFingerprint: stringColumn(statement, 14),
                    thumbnailFilename: stringColumn(statement, 15),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16))
                )
            )
        }
        return states
    }

    private func scalarInt(sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not prepare count query.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func stringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func optionalStringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = stringColumn(statement, index)
        return value.isEmpty ? nil : value
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private func decodeStringArray(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    private func storeError(_ message: String) -> NSError {
        NSError(domain: "ClickyWorkflowStore", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
