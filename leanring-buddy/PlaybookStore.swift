//
//  PlaybookStore.swift
//  leanring-buddy
//
//  Local SQLite + FTS5 for unified playbook storage.
//

import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class PlaybookStore {
    private var database: OpaquePointer?
    private let databaseURL: URL

    init(databaseURL: URL = PlaybookPaths.databaseURL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: PlaybookPaths.documentsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: PlaybookPaths.thumbnailsDirectory,
            withIntermediateDirectories: true
        )

        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            throw storeError("Could not open playbook database.")
        }

        try executeSQL("PRAGMA foreign_keys = ON;")

        try executeSQL("""
        CREATE TABLE IF NOT EXISTS playbooks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            summary TEXT NOT NULL DEFAULT '',
            tags_json TEXT NOT NULL DEFAULT '[]',
            kind TEXT NOT NULL,
            source TEXT NOT NULL,
            source_filename TEXT,
            step_count INTEGER NOT NULL DEFAULT 0,
            trigger_phrases_json TEXT NOT NULL DEFAULT '[]',
            doc_blocks_json TEXT NOT NULL DEFAULT '[]',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        try executeSQL("""
        CREATE TABLE IF NOT EXISTS playbook_steps (
            id TEXT PRIMARY KEY,
            playbook_id TEXT NOT NULL,
            step_index INTEGER NOT NULL,
            title TEXT NOT NULL,
            instruction TEXT NOT NULL,
            context_app TEXT,
            context_url_pattern TEXT,
            context_window_pattern TEXT,
            look_for TEXT,
            done_when TEXT,
            thumbnail_filename TEXT,
            captured_at REAL,
            FOREIGN KEY(playbook_id) REFERENCES playbooks(id) ON DELETE CASCADE
        );
        """)

        try executeSQL("""
        CREATE TABLE IF NOT EXISTS playbook_chunks (
            rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            chunk_id TEXT NOT NULL UNIQUE,
            playbook_id TEXT NOT NULL,
            playbook_title TEXT NOT NULL,
            page_index INTEGER NOT NULL,
            chunk_index INTEGER NOT NULL,
            chunk_text TEXT NOT NULL,
            FOREIGN KEY(playbook_id) REFERENCES playbooks(id) ON DELETE CASCADE
        );
        """)

        try executeSQL("""
        CREATE VIRTUAL TABLE IF NOT EXISTS playbook_search_fts USING fts5(
            search_text,
            playbook_id UNINDEXED,
            step_id UNINDEXED,
            kind UNINDEXED,
            content='',
            tokenize='unicode61 remove_diacritics 2'
        );
        """)

        try executeSQL("""
        CREATE VIRTUAL TABLE IF NOT EXISTS playbook_chunks_fts USING fts5(
            chunk_text,
            playbook_id UNINDEXED,
            playbook_title UNINDEXED,
            chunk_id UNINDEXED,
            page_index UNINDEXED,
            chunk_index UNINDEXED,
            content='playbook_chunks',
            content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2'
        );
        """)

        try createChunkFTSTriggersIfNeeded()
        try executeSQL("""
        CREATE INDEX IF NOT EXISTS idx_playbook_steps_order
        ON playbook_steps(playbook_id, step_index);
        """)
    }

    deinit {
        if database != nil {
            sqlite3_close(database)
        }
    }

    func upsertPlaybook(_ playbook: Playbook, steps: [PlaybookStep], chunks: [PlaybookChunk] = []) throws {
        let tagsJSON = try encodeJSON(playbook.tags)
        let triggerJSON = try encodeJSON(playbook.triggerPhrases)
        let docBlocksJSON = try encodeJSON(playbook.docBlocks)

        try executeSQL(
            """
            INSERT INTO playbooks (
                id, title, summary, tags_json, kind, source, source_filename,
                step_count, trigger_phrases_json, doc_blocks_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                summary = excluded.summary,
                tags_json = excluded.tags_json,
                kind = excluded.kind,
                source = excluded.source,
                source_filename = excluded.source_filename,
                step_count = excluded.step_count,
                trigger_phrases_json = excluded.trigger_phrases_json,
                doc_blocks_json = excluded.doc_blocks_json,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                .text(playbook.id),
                .text(playbook.title),
                .text(playbook.summary),
                .text(tagsJSON),
                .text(playbook.kind.rawValue),
                .text(playbook.source.rawValue),
                .text(playbook.sourceFilename),
                .int(playbook.stepCount),
                .text(triggerJSON),
                .text(docBlocksJSON),
                .double(playbook.createdAt.timeIntervalSince1970),
                .double(playbook.updatedAt.timeIntervalSince1970),
            ]
        )

        try executeSQL("DELETE FROM playbook_steps WHERE playbook_id = ?;", bindings: [.text(playbook.id)])
        try executeSQL("DELETE FROM playbook_chunks WHERE playbook_id = ?;", bindings: [.text(playbook.id)])
        try executeSQL("DELETE FROM playbook_search_fts WHERE playbook_id = ?;", bindings: [.text(playbook.id)])

        for step in steps.sorted(by: { $0.index < $1.index }) {
            try executeSQL(
                """
                INSERT INTO playbook_steps (
                    id, playbook_id, step_index, title, instruction,
                    context_app, context_url_pattern, context_window_pattern,
                    look_for, done_when, thumbnail_filename, captured_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(step.id),
                    .text(step.playbookID),
                    .int(step.index),
                    .text(step.title),
                    .text(step.instruction),
                    .text(step.contextApp),
                    .text(step.contextURLPattern),
                    .text(step.contextWindowPattern),
                    .text(step.lookFor),
                    .text(step.doneWhen),
                    .text(step.thumbnailFilename),
                    .double(step.capturedAt?.timeIntervalSince1970),
                ]
            )

            let searchText = [step.title, step.instruction, step.lookFor ?? ""]
                .joined(separator: " ")
            try insertSearchRow(
                playbookID: playbook.id,
                stepID: step.id,
                kind: "step",
                searchText: searchText
            )
        }

        let playbookSearchText = [
            playbook.title,
            playbook.summary,
            playbook.tags.joined(separator: " "),
            playbook.triggerPhrases.joined(separator: " "),
        ].joined(separator: " ")
        try insertSearchRow(
            playbookID: playbook.id,
            stepID: nil,
            kind: "playbook",
            searchText: playbookSearchText
        )

        for chunk in chunks {
            try executeSQL(
                """
                INSERT INTO playbook_chunks (
                    chunk_id, playbook_id, playbook_title, page_index, chunk_index, chunk_text
                ) VALUES (?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(chunk.id),
                    .text(chunk.playbookID),
                    .text(chunk.playbookTitle),
                    .int(chunk.pageIndex),
                    .int(chunk.chunkIndex),
                    .text(chunk.text),
                ]
            )
        }
    }

    func playbook(withID id: String) throws -> Playbook? {
        try queryPlaybooks(sql: """
            SELECT id, title, summary, tags_json, kind, source, source_filename,
                   step_count, trigger_phrases_json, doc_blocks_json, created_at, updated_at
            FROM playbooks WHERE id = ? LIMIT 1;
            """, bindings: [.text(id)]).first
    }

    func allPlaybooks() throws -> [Playbook] {
        try queryPlaybooks(sql: """
            SELECT id, title, summary, tags_json, kind, source, source_filename,
                   step_count, trigger_phrases_json, doc_blocks_json, created_at, updated_at
            FROM playbooks ORDER BY updated_at DESC;
            """)
    }

    func playbookCount() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM playbooks;", -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not count playbooks.")
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    func steps(forPlaybookID playbookID: String) throws -> [PlaybookStep] {
        try querySteps(
            sql: """
            SELECT id, playbook_id, step_index, title, instruction,
                   context_app, context_url_pattern, context_window_pattern,
                   look_for, done_when, thumbnail_filename, captured_at
            FROM playbook_steps WHERE playbook_id = ? ORDER BY step_index ASC;
            """,
            bindings: [.text(playbookID)]
        )
    }

    func deletePlaybook(id: String) throws {
        guard let playbook = try playbook(withID: id) else { return }
        try executeSQL("DELETE FROM playbooks WHERE id = ?;", bindings: [.text(id)])
        try executeSQL("DELETE FROM playbook_search_fts WHERE playbook_id = ?;", bindings: [.text(id)])

        if let sourceFilename = playbook.sourceFilename {
            let fileURL = PlaybookPaths.documentsDirectory.appendingPathComponent(sourceFilename)
            try? FileManager.default.removeItem(at: fileURL)
        }
        PlaybookPaths.deleteAssets(forPlaybookID: id)
    }

    func searchPlaybooks(query: String, kind: PlaybookKind? = nil, limit: Int = 5) throws -> [PlaybookRetrieval] {
        let ftsQuery = Self.ftsQuery(from: query)
        guard !ftsQuery.isEmpty else { return [] }

        let sql = """
        SELECT playbook_id, bm25(playbook_search_fts) AS score
        FROM playbook_search_fts
        WHERE playbook_search_fts MATCH ?
        GROUP BY playbook_id
        ORDER BY score
        LIMIT ?;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not prepare playbook search.")
        }

        sqlite3_bind_text(statement, 1, ftsQuery, -1, sqliteTransientDestructor)
        sqlite3_bind_int(statement, 2, Int32(limit * 3))

        var results: [PlaybookRetrieval] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let playbookIDCString = sqlite3_column_text(statement, 0) else { continue }
            let playbookID = String(cString: playbookIDCString)
            let score = sqlite3_column_double(statement, 1)

            guard let playbook = try playbook(withID: playbookID) else { continue }
            if let kind, playbook.kind != kind { continue }

            let steps = try steps(forPlaybookID: playbookID)
            results.append(PlaybookRetrieval(playbook: playbook, steps: steps, relevanceScore: score))
            if results.count >= limit { break }
        }

        return results
    }

    func searchReferenceChunks(query: String, playbookID: String? = nil, limit: Int = 5) throws -> [PlaybookChunk] {
        let ftsQuery = Self.ftsQuery(from: query)
        guard !ftsQuery.isEmpty else { return [] }

        let sql: String
        if playbookID != nil {
            sql = """
            SELECT c.chunk_id, c.playbook_id, c.playbook_title, c.page_index, c.chunk_index, c.chunk_text,
                   bm25(playbook_chunks_fts) AS score
            FROM playbook_chunks_fts
            JOIN playbook_chunks c ON c.rowid = playbook_chunks_fts.rowid
            WHERE playbook_chunks_fts MATCH ? AND c.playbook_id = ?
            ORDER BY score
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT c.chunk_id, c.playbook_id, c.playbook_title, c.page_index, c.chunk_index, c.chunk_text,
                   bm25(playbook_chunks_fts) AS score
            FROM playbook_chunks_fts
            JOIN playbook_chunks c ON c.rowid = playbook_chunks_fts.rowid
            WHERE playbook_chunks_fts MATCH ?
            ORDER BY score
            LIMIT ?;
            """
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not prepare chunk search.")
        }

        sqlite3_bind_text(statement, 1, ftsQuery, -1, sqliteTransientDestructor)
        if let playbookID {
            sqlite3_bind_text(statement, 2, playbookID, -1, sqliteTransientDestructor)
            sqlite3_bind_int(statement, 3, Int32(limit))
        } else {
            sqlite3_bind_int(statement, 2, Int32(limit))
        }

        var chunks: [PlaybookChunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let chunkID = sqlite3_column_text(statement, 0),
                let pbID = sqlite3_column_text(statement, 1),
                let pbTitle = sqlite3_column_text(statement, 2),
                let chunkText = sqlite3_column_text(statement, 5)
            else { continue }

            chunks.append(
                PlaybookChunk(
                    id: String(cString: chunkID),
                    playbookID: String(cString: pbID),
                    playbookTitle: String(cString: pbTitle),
                    pageIndex: Int(sqlite3_column_int(statement, 3)),
                    chunkIndex: Int(sqlite3_column_int(statement, 4)),
                    text: String(cString: chunkText),
                    relevanceScore: sqlite3_column_double(statement, 6)
                )
            )
        }

        return chunks
    }

    private func insertSearchRow(playbookID: String, stepID: String?, kind: String, searchText: String) throws {
        try executeSQL(
            """
            INSERT INTO playbook_search_fts (search_text, playbook_id, step_id, kind)
            VALUES (?, ?, ?, ?);
            """,
            bindings: [
                .text(searchText),
                .text(playbookID),
                .text(stepID),
                .text(kind),
            ]
        )
    }

    private func createChunkFTSTriggersIfNeeded() throws {
        try executeSQL("""
        CREATE TRIGGER IF NOT EXISTS playbook_chunks_ai AFTER INSERT ON playbook_chunks BEGIN
            INSERT INTO playbook_chunks_fts(
                rowid, chunk_text, playbook_id, playbook_title, chunk_id, page_index, chunk_index
            ) VALUES (
                new.rowid, new.chunk_text, new.playbook_id, new.playbook_title,
                new.chunk_id, new.page_index, new.chunk_index
            );
        END;
        """)

        try executeSQL("""
        CREATE TRIGGER IF NOT EXISTS playbook_chunks_ad AFTER DELETE ON playbook_chunks BEGIN
            INSERT INTO playbook_chunks_fts(
                playbook_chunks_fts, rowid, chunk_text, playbook_id, playbook_title, chunk_id, page_index, chunk_index
            ) VALUES (
                'delete', old.rowid, old.chunk_text, old.playbook_id, old.playbook_title,
                old.chunk_id, old.page_index, old.chunk_index
            );
        END;
        """)
    }

    private func queryPlaybooks(sql: String, bindings: [SQLBinding] = []) throws -> [Playbook] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not query playbooks.")
        }

        try bind(bindings, to: statement)

        var playbooks: [Playbook] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = sqlite3_column_text(statement, 0),
                let title = sqlite3_column_text(statement, 1),
                let summary = sqlite3_column_text(statement, 2),
                let tagsJSON = sqlite3_column_text(statement, 3),
                let kindRaw = sqlite3_column_text(statement, 4),
                let sourceRaw = sqlite3_column_text(statement, 5)
            else { continue }

            let sourceFilename = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            let stepCount = Int(sqlite3_column_int(statement, 7))
            let triggerJSON = sqlite3_column_text(statement, 8).map { String(cString: $0) } ?? "[]"
            let docBlocksJSON = sqlite3_column_text(statement, 9).map { String(cString: $0) } ?? "[]"

            playbooks.append(
                Playbook(
                    id: String(cString: id),
                    title: String(cString: title),
                    summary: String(cString: summary),
                    tags: decodeJSON(String(cString: tagsJSON), as: [String].self) ?? [],
                    kind: PlaybookKind(rawValue: String(cString: kindRaw)) ?? .reference,
                    source: PlaybookSource(rawValue: String(cString: sourceRaw)) ?? .pdfImport,
                    sourceFilename: sourceFilename,
                    stepCount: stepCount,
                    triggerPhrases: decodeJSON(triggerJSON, as: [String].self) ?? [],
                    docBlocks: decodeJSON(docBlocksJSON, as: [PlaybookDocBlock].self) ?? [],
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
                )
            )
        }

        return playbooks
    }

    private func querySteps(sql: String, bindings: [SQLBinding] = []) throws -> [PlaybookStep] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not query steps.")
        }

        try bind(bindings, to: statement)

        var steps: [PlaybookStep] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = sqlite3_column_text(statement, 0),
                let playbookID = sqlite3_column_text(statement, 1),
                let title = sqlite3_column_text(statement, 3),
                let instruction = sqlite3_column_text(statement, 4)
            else { continue }

            let capturedAt = sqlite3_column_type(statement, 11) != SQLITE_NULL
                ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
                : nil

            steps.append(
                PlaybookStep(
                    id: String(cString: id),
                    playbookID: String(cString: playbookID),
                    index: Int(sqlite3_column_int(statement, 2)),
                    title: String(cString: title),
                    instruction: String(cString: instruction),
                    contextApp: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                    contextURLPattern: sqlite3_column_text(statement, 6).map { String(cString: $0) },
                    contextWindowPattern: sqlite3_column_text(statement, 7).map { String(cString: $0) },
                    lookFor: sqlite3_column_text(statement, 8).map { String(cString: $0) },
                    doneWhen: sqlite3_column_text(statement, 9).map { String(cString: $0) },
                    thumbnailFilename: sqlite3_column_text(statement, 10).map { String(cString: $0) },
                    capturedAt: capturedAt
                )
            )
        }

        return steps
    }

    private enum SQLBinding {
        case text(String?)
        case int(Int)
        case double(Double?)
    }

    private func bind(_ bindings: [SQLBinding], to statement: OpaquePointer?) throws {
        for (index, binding) in bindings.enumerated() {
            let parameterIndex = Int32(index + 1)
            switch binding {
            case .text(let value):
                if let value {
                    sqlite3_bind_text(statement, parameterIndex, value, -1, sqliteTransientDestructor)
                } else {
                    sqlite3_bind_null(statement, parameterIndex)
                }
            case .int(let value):
                sqlite3_bind_int(statement, parameterIndex, Int32(value))
            case .double(let value):
                if let value {
                    sqlite3_bind_double(statement, parameterIndex, value)
                } else {
                    sqlite3_bind_null(statement, parameterIndex)
                }
            }
        }
    }

    private func executeSQL(_ sql: String, bindings: [SQLBinding] = []) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError(String(cString: sqlite3_errmsg(database)))
        }

        try bind(bindings, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw storeError(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeJSON<T: Decodable>(_ json: String, as type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func storeError(_ message: String) -> NSError {
        NSError(domain: "PlaybookStore", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func ftsQuery(from rawQuery: String) -> String {
        let terms = rawQuery
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .filter { !searchStopWords.contains($0) }

        guard !terms.isEmpty else { return "" }
        let quotedTerms = terms.prefix(6).map { "\"\($0)\"" }
        return quotedTerms.count == 1 ? quotedTerms[0] : quotedTerms.joined(separator: " OR ")
    }

    private static let searchStopWords: Set<String> = [
        "about", "after", "also", "and", "are", "ask", "can", "check", "clicky",
        "could", "document", "documents", "find", "for", "from", "get", "give",
        "guide", "help", "how", "just", "know", "need", "open", "our", "please",
        "policy", "procedure", "show", "sop", "tell", "that", "the", "their",
        "them", "this", "walk", "want", "what", "when", "where", "which", "who",
        "why", "with", "would", "you", "your",
    ]
}
