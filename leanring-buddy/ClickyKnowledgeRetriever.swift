//
//  ClickyKnowledgeRetriever.swift
//  leanring-buddy
//
//  Runs FTS retrieval and resolves source documents for PDF panels.
//

import Foundation

enum ClickyKnowledgeRetriever {

    static let maxChunks = 5
    static let maxSourceDocuments = 2

    /// Skip local SOP search for live/web questions that should never open uploaded docs.
    static func shouldSkipKnowledgeSearch(for query: String) -> Bool {
        let normalizedQuery = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let skipPhrases = [
            "weather",
            "forecast",
            "temperature",
            "stock price",
            "share price",
            "trading at",
            "news about",
            "sports score",
            "exchange rate",
            "near me",
            "nearby",
            "opening hours",
            "what time is",
            "who won",
            "billing",
            "subscription",
            "invoice",
        ]

        return skipPhrases.contains { normalizedQuery.contains($0) }
    }

    static func retrieve(query: String, store: ClickyKnowledgeStore) throws -> ClickyKnowledgeRetrieval? {
        guard !shouldSkipKnowledgeSearch(for: query) else { return nil }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        if let referencedDocument = try documentReferencedInQuery(query: trimmedQuery, store: store) {
            let chunks = try store.search(query: trimmedQuery, limit: maxChunks)
            let sourceDocuments = try mergedSourceDocuments(
                preferred: referencedDocument,
                chunks: chunks,
                store: store
            )
            return ClickyKnowledgeRetrieval(chunks: chunks, sourceDocuments: sourceDocuments)
        }

        let chunks = try store.search(query: trimmedQuery, limit: maxChunks)
        guard !chunks.isEmpty else { return nil }

        let sourceDocuments = try sourceDocuments(from: chunks, store: store)
        return ClickyKnowledgeRetrieval(chunks: chunks, sourceDocuments: sourceDocuments)
    }

    /// True when the user is clearly asking about uploaded SOPs, policies, or documents.
    static func isKnowledgeDocumentQuery(_ query: String) -> Bool {
        let normalizedQuery = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let documentWords = [
            "sop",
            "sops",
            "document",
            "documents",
            "policy",
            "policies",
            "procedure",
            "procedures",
            "manual",
            "handbook",
            "guide",
            "playbook",
            "knowledge base",
            "uploaded",
            "runbook",
        ]

        return documentWords.contains { normalizedQuery.contains($0) }
    }

    /// True only when the user explicitly wants uploaded SOPs/docs — not general questions
    /// that happen to share words with indexed PDFs (e.g. "spotify billing information").
    static func isExplicitKnowledgeBaseQuestion(_ query: String) -> Bool {
        if shouldSkipKnowledgeSearch(for: query) {
            return false
        }

        if isKnowledgeDocumentQuery(query) {
            return true
        }

        if shouldOpenDocumentsDirectly(for: query) {
            return true
        }

        return false
    }

    static func shouldOpenDocumentsDirectly(for query: String) -> Bool {
        let normalizedQuery = query.lowercased()
        let openPhrases = [
            "open ",
            "show ",
            "pull up ",
            "display ",
            "view ",
            "look at ",
        ]
        let documentWords = [
            "sop",
            "document",
            "policy",
            "procedure",
            "manual",
            "guide",
        ]

        let hasOpenPhrase = openPhrases.contains { normalizedQuery.contains($0) }
        let hasDocumentWord = documentWords.contains { normalizedQuery.contains($0) }
        return hasOpenPhrase && hasDocumentWord
    }

    static func directDocumentMatch(query: String, store: ClickyKnowledgeStore) throws -> ClickyKnowledgeSourceDocument? {
        guard shouldOpenDocumentsDirectly(for: query) else { return nil }
        return try documentReferencedInQuery(query: query, store: store)
    }

    static func documentReferencedInQuery(query: String, store: ClickyKnowledgeStore) throws -> ClickyKnowledgeSourceDocument? {
        let normalizedQuery = query.lowercased()
        let documents = try store.allDocuments()

        var bestMatch: ClickyKnowledgeDocument?
        var bestMatchLength = 0

        for document in documents {
            let candidates = [document.title.lowercased()] + document.aliases.map { $0.lowercased() }
            for candidate in candidates where candidate.count >= 4 {
                if normalizedQuery.contains(candidate), candidate.count > bestMatchLength {
                    bestMatch = document
                    bestMatchLength = candidate.count
                }
            }
        }

        guard let document = bestMatch else { return nil }

        return ClickyKnowledgeSourceDocument(
            documentID: document.id,
            title: document.title,
            fileURL: document.fileURL,
            pageIndex: 0
        )
    }

    private static func mergedSourceDocuments(
        preferred: ClickyKnowledgeSourceDocument,
        chunks: [ClickyKnowledgeChunk],
        store: ClickyKnowledgeStore
    ) throws -> [ClickyKnowledgeSourceDocument] {
        var documents = [preferred]
        let chunkDocuments = try sourceDocuments(from: chunks, store: store)

        for document in chunkDocuments where !documents.contains(where: { $0.documentID == document.documentID }) {
            documents.append(document)
            if documents.count >= maxSourceDocuments {
                break
            }
        }

        return documents
    }

    private static func sourceDocuments(
        from chunks: [ClickyKnowledgeChunk],
        store: ClickyKnowledgeStore
    ) throws -> [ClickyKnowledgeSourceDocument] {
        var bestPageByDocumentID: [String: (pageIndex: Int, rank: Int)] = [:]

        for (rank, chunk) in chunks.enumerated() {
            if let existing = bestPageByDocumentID[chunk.documentID], existing.rank <= rank {
                continue
            }

            bestPageByDocumentID[chunk.documentID] = (pageIndex: chunk.pageIndex, rank: rank)
        }

        var results: [ClickyKnowledgeSourceDocument] = []
        for (documentID, value) in bestPageByDocumentID.sorted(by: { $0.value.rank < $1.value.rank }) {
            guard results.count < maxSourceDocuments else { break }
            guard let document = try store.document(withID: documentID) else { continue }
            results.append(
                ClickyKnowledgeSourceDocument(
                    documentID: document.id,
                    title: document.title,
                    fileURL: document.fileURL,
                    pageIndex: value.pageIndex
                )
            )
        }
        return results
    }
}
