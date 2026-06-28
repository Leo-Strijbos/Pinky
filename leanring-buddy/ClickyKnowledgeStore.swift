//
//  ClickyKnowledgeStore.swift
//  leanring-buddy
//
//  Local SQLite + FTS5 index for uploaded knowledge documents.
//

import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ClickyKnowledgeStore {
    private var database: OpaquePointer?
    private let databaseURL: URL

    init(databaseURL: URL = ClickyKnowledgePaths.databaseURL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            throw storeError("Could not open knowledge database.")
        }

        try executeSQL("""
        CREATE TABLE IF NOT EXISTS documents (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            filename TEXT NOT NULL,
            aliases_json TEXT NOT NULL DEFAULT '[]',
            imported_at REAL NOT NULL
        );
        """)

        try? executeSQL("ALTER TABLE documents ADD COLUMN kind TEXT NOT NULL DEFAULT 'reference';")

        try executeSQL("""
        CREATE TABLE IF NOT EXISTS chunks (
            rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            chunk_id TEXT NOT NULL UNIQUE,
            document_id TEXT NOT NULL,
            document_title TEXT NOT NULL,
            page_index INTEGER NOT NULL,
            chunk_index INTEGER NOT NULL,
            chunk_text TEXT NOT NULL,
            FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
        );
        """)

        try executeSQL("""
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            chunk_text,
            document_id UNINDEXED,
            document_title UNINDEXED,
            chunk_id UNINDEXED,
            page_index UNINDEXED,
            chunk_index UNINDEXED,
            content='chunks',
            content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2'
        );
        """)

        try executeSQL("""
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO chunks_fts(
                rowid,
                chunk_text,
                document_id,
                document_title,
                chunk_id,
                page_index,
                chunk_index
            ) VALUES (
                new.rowid,
                new.chunk_text,
                new.document_id,
                new.document_title,
                new.chunk_id,
                new.page_index,
                new.chunk_index
            );
        END;
        """)

        try executeSQL("""
        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
            INSERT INTO chunks_fts(
                chunks_fts,
                rowid,
                chunk_text,
                document_id,
                document_title,
                chunk_id,
                page_index,
                chunk_index
            ) VALUES (
                'delete',
                old.rowid,
                old.chunk_text,
                old.document_id,
                old.document_title,
                old.chunk_id,
                old.page_index,
                old.chunk_index
            );
        END;
        """)

        try executeSQL("""
        CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
            INSERT INTO chunks_fts(
                chunks_fts,
                rowid,
                chunk_text,
                document_id,
                document_title,
                chunk_id,
                page_index,
                chunk_index
            ) VALUES (
                'delete',
                old.rowid,
                old.chunk_text,
                old.document_id,
                old.document_title,
                old.chunk_id,
                old.page_index,
                old.chunk_index
            );
            INSERT INTO chunks_fts(
                rowid,
                chunk_text,
                document_id,
                document_title,
                chunk_id,
                page_index,
                chunk_index
            ) VALUES (
                new.rowid,
                new.chunk_text,
                new.document_id,
                new.document_title,
                new.chunk_id,
                new.page_index,
                new.chunk_index
            );
        END;
        """)
    }

    deinit {
        if database != nil {
            sqlite3_close(database)
        }
    }

    func upsertDocument(_ document: ClickyKnowledgeDocument, chunks: [ClickyKnowledgeChunk]) throws {
        let aliasesJSON = try JSONEncoder().encode(document.aliases)
        let aliasesString = String(data: aliasesJSON, encoding: .utf8) ?? "[]"

        try executeSQL(
            """
            INSERT INTO documents (id, title, filename, aliases_json, imported_at, kind)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                filename = excluded.filename,
                aliases_json = excluded.aliases_json,
                imported_at = excluded.imported_at,
                kind = excluded.kind;
            """,
            bindings: [
                .text(document.id),
                .text(document.title),
                .text(document.filename),
                .text(aliasesString),
                .double(document.importedAt.timeIntervalSince1970),
                .text(document.kind.rawValue),
            ]
        )

        try executeSQL("DELETE FROM chunks WHERE document_id = ?;", bindings: [.text(document.id)])

        for chunk in chunks {
            try executeSQL(
                """
                INSERT INTO chunks (
                    chunk_id,
                    document_id,
                    document_title,
                    page_index,
                    chunk_index,
                    chunk_text
                ) VALUES (?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(chunk.id),
                    .text(chunk.documentID),
                    .text(chunk.documentTitle),
                    .int(chunk.pageIndex),
                    .int(chunk.chunkIndex),
                    .text(chunk.text),
                ]
            )
        }
    }

    func document(withID documentID: String) throws -> ClickyKnowledgeDocument? {
        let documents = try queryDocuments(
            sql: "SELECT id, title, filename, aliases_json, imported_at, kind FROM documents WHERE id = ? LIMIT 1;",
            bindings: [.text(documentID)]
        )
        return documents.first
    }

    func allDocuments() throws -> [ClickyKnowledgeDocument] {
        try queryDocuments(sql: "SELECT id, title, filename, aliases_json, imported_at, kind FROM documents ORDER BY title ASC;")
    }

    func documentCount() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM documents;", -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not count documents.")
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    func deleteDocument(id: String) throws {
        guard let document = try document(withID: id) else { return }

        try executeSQL(
            "DELETE FROM documents WHERE id = ?;",
            bindings: [.text(id)]
        )

        try? FileManager.default.removeItem(at: document.fileURL)
    }

    func search(query: String, limit: Int = 5) throws -> [ClickyKnowledgeChunk] {
        let ftsQuery = Self.ftsQuery(from: query)
        guard !ftsQuery.isEmpty else { return [] }

        let sql = """
        SELECT
            c.chunk_id,
            c.document_id,
            c.document_title,
            c.page_index,
            c.chunk_index,
            c.chunk_text,
            bm25(chunks_fts) AS score
        FROM chunks_fts
        JOIN chunks c ON c.rowid = chunks_fts.rowid
        WHERE chunks_fts MATCH ?
        ORDER BY score
        LIMIT ?;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not prepare knowledge search.")
        }

        sqlite3_bind_text(statement, 1, ftsQuery, -1, sqliteTransientDestructor)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var chunks: [ClickyKnowledgeChunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let relevanceScore = sqlite3_column_double(statement, 6)

            guard
                let chunkIDCString = sqlite3_column_text(statement, 0),
                let documentIDCString = sqlite3_column_text(statement, 1),
                let documentTitleCString = sqlite3_column_text(statement, 2),
                let chunkTextCString = sqlite3_column_text(statement, 5)
            else {
                continue
            }

            chunks.append(
                ClickyKnowledgeChunk(
                    id: String(cString: chunkIDCString),
                    documentID: String(cString: documentIDCString),
                    documentTitle: String(cString: documentTitleCString),
                    pageIndex: Int(sqlite3_column_int(statement, 3)),
                    chunkIndex: Int(sqlite3_column_int(statement, 4)),
                    text: String(cString: chunkTextCString),
                    relevanceScore: relevanceScore
                )
            )
        }

        return chunks
    }

    private func queryDocuments(sql: String, bindings: [SQLBinding] = []) throws -> [ClickyKnowledgeDocument] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("Could not query documents.")
        }

        for (index, binding) in bindings.enumerated() {
            let parameterIndex = Int32(index + 1)
            switch binding {
            case .text(let value):
                sqlite3_bind_text(statement, parameterIndex, value, -1, sqliteTransientDestructor)
            case .int(let value):
                sqlite3_bind_int(statement, parameterIndex, Int32(value))
            case .double(let value):
                sqlite3_bind_double(statement, parameterIndex, value)
            }
        }

        var documents: [ClickyKnowledgeDocument] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idCString = sqlite3_column_text(statement, 0),
                let titleCString = sqlite3_column_text(statement, 1),
                let filenameCString = sqlite3_column_text(statement, 2),
                let aliasesJSONCString = sqlite3_column_text(statement, 3)
            else {
                continue
            }

            let aliasesJSONData = Data(String(cString: aliasesJSONCString).utf8)
            let aliases = (try? JSONDecoder().decode([String].self, from: aliasesJSONData)) ?? []
            let importedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let kindRaw = sqlite3_column_count(statement) > 5
                ? String(cString: sqlite3_column_text(statement, 5))
                : ClickyKnowledgeDocumentKind.reference.rawValue

            documents.append(
                ClickyKnowledgeDocument(
                    id: String(cString: idCString),
                    title: String(cString: titleCString),
                    filename: String(cString: filenameCString),
                    aliases: aliases,
                    importedAt: importedAt,
                    kind: ClickyKnowledgeDocumentKind(rawValue: kindRaw) ?? .reference
                )
            )
        }

        return documents
    }

    private enum SQLBinding {
        case text(String)
        case int(Int)
        case double(Double)
    }

    private func executeSQL(_ sql: String, bindings: [SQLBinding] = []) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError(String(cString: sqlite3_errmsg(database)))
        }

        for (index, binding) in bindings.enumerated() {
            let parameterIndex = Int32(index + 1)
            switch binding {
            case .text(let value):
                sqlite3_bind_text(statement, parameterIndex, value, -1, sqliteTransientDestructor)
            case .int(let value):
                sqlite3_bind_int(statement, parameterIndex, Int32(value))
            case .double(let value):
                sqlite3_bind_double(statement, parameterIndex, value)
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw storeError(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func storeError(_ message: String) -> NSError {
        NSError(domain: "ClickyKnowledgeStore", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func ftsQuery(from rawQuery: String) -> String {
        let terms = rawQuery
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .filter { !searchStopWords.contains($0) }

        guard !terms.isEmpty else { return "" }

        let quotedTerms = terms.prefix(6).map { "\"\($0)\"" }

        if quotedTerms.count == 1 {
            return quotedTerms[0]
        }

        // OR keeps conversational queries working; bm25 ranking surfaces the best doc.
        return quotedTerms.joined(separator: " OR ")
    }

    private static let searchStopWords: Set<String> = [
        "about", "after", "also", "and", "are", "ask", "can", "check", "clicky",
        "could", "day", "did", "does", "document", "documents", "find", "for",
        "from", "get", "give", "guide", "had", "has", "have", "help", "hey", "him",
        "his", "how", "into", "its", "just", "know", "like", "look", "manual", "may",
        "much", "near", "need", "not", "now", "open", "our", "out", "please", "policy",
        "policies", "procedure", "procedures", "pull", "read", "say", "see", "she",
        "should", "show", "sop", "sops", "tell", "than", "that", "the", "their",
        "them", "then", "there", "these", "they", "this", "today", "too", "use",
        "view", "want", "was", "way", "what", "when", "where", "which", "who", "why",
        "will", "with", "would", "you", "your",
    ]
}
