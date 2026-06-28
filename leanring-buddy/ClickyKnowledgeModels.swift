//
//  ClickyKnowledgeModels.swift
//  leanring-buddy
//
//  Models for uploaded SOP documents and RAG retrieval results.
//

import Foundation

enum ClickyKnowledgeDocumentKind: String, Equatable, Codable {
    case reference
    case procedure
}

struct ClickyKnowledgeDocument: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    let filename: String
    var aliases: [String]
    let importedAt: Date
    var kind: ClickyKnowledgeDocumentKind

    init(
        id: String,
        title: String,
        filename: String,
        aliases: [String],
        importedAt: Date,
        kind: ClickyKnowledgeDocumentKind = .reference
    ) {
        self.id = id
        self.title = title
        self.filename = filename
        self.aliases = aliases
        self.importedAt = importedAt
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        filename = try container.decode(String.self, forKey: .filename)
        aliases = try container.decode([String].self, forKey: .aliases)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        kind = try container.decodeIfPresent(ClickyKnowledgeDocumentKind.self, forKey: .kind) ?? .reference
    }

    var fileURL: URL {
        ClickyKnowledgePaths.documentsDirectory.appendingPathComponent(filename)
    }
}

struct ClickyKnowledgeChunk: Identifiable, Equatable {
    let id: String
    let documentID: String
    let documentTitle: String
    let pageIndex: Int
    let chunkIndex: Int
    let text: String
    /// FTS5 bm25 score — lower (more negative) means a stronger match.
    let relevanceScore: Double
}

struct ClickyKnowledgeSourceDocument: Equatable {
    let documentID: String
    let title: String
    let fileURL: URL
    let pageIndex: Int
}

struct ClickyKnowledgeRetrieval: Equatable {
    let chunks: [ClickyKnowledgeChunk]
    let sourceDocuments: [ClickyKnowledgeSourceDocument]

    var isEmpty: Bool {
        chunks.isEmpty && sourceDocuments.isEmpty
    }

    func promptFragment() -> String {
        if !chunks.isEmpty {
            var lines = [
                "relevant excerpts from the user's uploaded SOPs and documents:",
                "",
            ]

            for chunk in chunks {
                lines.append("[\(chunk.documentTitle) p.\(chunk.pageIndex + 1)]: \(chunk.text)")
                lines.append("")
            }

            lines.append("use these excerpts when answering. if the user asked to open or show a document, mention you've pulled it up. do not invent policy details beyond these excerpts.")
            return lines.joined(separator: "\n")
        }

        guard !sourceDocuments.isEmpty else { return "" }

        let titles = sourceDocuments.map(\.title).joined(separator: ", ")
        return """
        the user is asking about their uploaded document(s): \(titles).
        you've pulled up the matching PDF panel for them.
        answer from any excerpts above when present; otherwise say you're showing the document and summarize only what you can infer from the title — do not invent policy details.
        """
    }
}

enum ClickyKnowledgePaths {
    static var applicationSupportDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("Clicky", isDirectory: true)
    }

    static var knowledgeRootDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("knowledge", isDirectory: true)
    }

    static var documentsDirectory: URL {
        knowledgeRootDirectory.appendingPathComponent("documents", isDirectory: true)
    }

    static var catalogURL: URL {
        knowledgeRootDirectory.appendingPathComponent("catalog.json")
    }

    static var databaseURL: URL {
        knowledgeRootDirectory.appendingPathComponent("knowledge.sqlite")
    }
}
