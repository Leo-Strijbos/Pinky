//
//  ClickyKnowledgeManager.swift
//  leanring-buddy
//
//  Coordinates knowledge import, search, and catalog persistence.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ClickyKnowledgeManager: ObservableObject {
    @Published private(set) var documentCount: Int = 0
    @Published private(set) var documents: [ClickyKnowledgeDocument] = []
    @Published private(set) var lastImportMessage: String?
    @Published private(set) var lastImportError: String?

    private var store: ClickyKnowledgeStore?

    init() {
        do {
            try FileManager.default.createDirectory(
                at: ClickyKnowledgePaths.knowledgeRootDirectory,
                withIntermediateDirectories: true
            )
            let openedStore = try ClickyKnowledgeStore()
            store = openedStore
            reloadDocuments(using: openedStore)
        } catch {
            print("⚠️ Clicky knowledge store failed to initialize: \(error.localizedDescription)")
            store = nil
        }
    }

    func presentDocumentUploadPanel(
        kind: ClickyKnowledgeDocumentKind,
        claudeAPI: ClaudeAPI,
        workflowManager: ClickyWorkflowManager
    ) {
        let openPanel = NSOpenPanel()
        openPanel.title = kind == .procedure ? "Add step-by-step procedure" : "Add SOP or document"
        openPanel.message = kind == .procedure
            ? "Choose a PDF with numbered steps for Clicky to guide you through."
            : "Choose a PDF to add to Clicky's knowledge base."
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.pdf]

        openPanel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                for selectedURL in openPanel.urls {
                    await self?.importDocument(
                        from: selectedURL,
                        kind: kind,
                        claudeAPI: claudeAPI,
                        workflowManager: workflowManager
                    )
                }
            }
        }
    }

    func importDocument(
        from sourceURL: URL,
        kind: ClickyKnowledgeDocumentKind,
        claudeAPI: ClaudeAPI? = nil,
        workflowManager: ClickyWorkflowManager? = nil
    ) async {
        guard let store else {
            lastImportError = "Knowledge storage is unavailable."
            return
        }

        lastImportError = nil

        do {
            let (baseDocument, chunks) = try ClickyPDFIndexer.indexDocument(sourceURL: sourceURL)
            let document = ClickyKnowledgeDocument(
                id: baseDocument.id,
                title: baseDocument.title,
                filename: baseDocument.filename,
                aliases: baseDocument.aliases,
                importedAt: baseDocument.importedAt,
                kind: kind
            )

            switch kind {
            case .reference:
                try store.upsertDocument(document, chunks: chunks)
                try persistCatalogSnapshot(using: store)
                reloadDocuments(using: store)
                lastImportMessage = "Added reference document \"\(document.title)\""
                print("📚 Knowledge imported: \(document.title) (\(chunks.count) chunks)")

            case .procedure:
                guard let claudeAPI, let workflowManager else {
                    lastImportError = "Procedure import requires AI indexing."
                    return
                }

                try store.upsertDocument(document, chunks: [])
                try await workflowManager.importProcedureWorkflow(document: document, claudeAPI: claudeAPI)
                try persistCatalogSnapshot(using: store)
                reloadDocuments(using: store)
                lastImportMessage = "Added procedure \"\(document.title)\""
                print("📋 Procedure imported: \(document.title)")
            }
        } catch {
            lastImportError = error.localizedDescription
            print("⚠️ Knowledge import failed: \(error.localizedDescription)")
        }
    }

    func deleteDocument(id: String, workflowManager: ClickyWorkflowManager? = nil) {
        guard let store else {
            lastImportError = "Knowledge storage is unavailable."
            return
        }

        lastImportError = nil

        do {
            guard let document = try store.document(withID: id) else { return }
            workflowManager?.deleteWorkflowsLinkedToDocument(documentID: id)
            try store.deleteDocument(id: id)
            try persistCatalogSnapshot(using: store)
            reloadDocuments(using: store)
            lastImportMessage = "Removed \(document.title)"
            print("📚 Knowledge removed: \(document.title)")
        } catch {
            lastImportError = error.localizedDescription
            print("⚠️ Knowledge delete failed: \(error.localizedDescription)")
        }
    }

    func revealKnowledgeFolderInFinder() {
        NSWorkspace.shared.open(ClickyKnowledgePaths.knowledgeRootDirectory)
    }

    func document(withID documentID: String) -> ClickyKnowledgeDocument? {
        guard let store else { return nil }
        return try? store.document(withID: documentID)
    }

    func sourceDocument(forDocumentID documentID: String, pageIndex: Int = 0) -> ClickyKnowledgeSourceDocument? {
        guard let document = document(withID: documentID) else { return nil }
        return ClickyKnowledgeSourceDocument(
            documentID: document.id,
            title: document.title,
            fileURL: document.fileURL,
            pageIndex: pageIndex
        )
    }

    func referenceRetrieval(for query: String) -> ClickyKnowledgeRetrieval? {
        guard shouldIncludeReferenceKnowledge(for: query) else { return nil }
        guard let store else { return nil }
        guard !ClickyKnowledgeRetriever.shouldSkipKnowledgeSearch(for: query) else { return nil }

        do {
            if let directDocument = try ClickyKnowledgeRetriever.directDocumentMatch(query: query, store: store) {
                guard let document = try store.document(withID: directDocument.documentID) else {
                    return nil
                }

                if document.kind == .reference || ClickyKnowledgeRetriever.shouldOpenDocumentsDirectly(for: query) {
                    return ClickyKnowledgeRetrieval(
                        chunks: [],
                        sourceDocuments: [directDocument]
                    )
                }
                return nil
            }

            guard let retrieval = try ClickyKnowledgeRetriever.retrieve(query: query, store: store) else {
                return nil
            }

            let referenceChunks = retrieval.chunks.filter { chunk in
                guard let document = try? store.document(withID: chunk.documentID) else { return true }
                return document.kind == .reference
            }
            let referenceSources = retrieval.sourceDocuments.filter { source in
                guard let document = try? store.document(withID: source.documentID) else { return true }
                return document.kind == .reference
            }

            guard !referenceChunks.isEmpty || !referenceSources.isEmpty else { return nil }

            return ClickyKnowledgeRetrieval(
                chunks: referenceChunks,
                sourceDocuments: referenceSources
            )
        } catch {
            print("⚠️ Knowledge retrieval failed: \(error.localizedDescription)")
            return nil
        }
    }

    func hasRelevantReferenceKnowledge(for query: String) -> Bool {
        guard let retrieval = referenceRetrieval(for: query) else { return false }
        return !retrieval.isEmpty
    }

    func referenceDocumentAppendix(for query: String) -> String {
        guard let retrieval = referenceRetrieval(for: query), !retrieval.isEmpty else {
            return ""
        }
        return retrieval.promptFragment()
    }

    func sourceDocumentsToPresent(for query: String) -> [ClickyKnowledgeSourceDocument] {
        guard shouldIncludeReferenceKnowledge(for: query),
              let retrieval = referenceRetrieval(for: query),
              !retrieval.sourceDocuments.isEmpty else {
            return []
        }
        return retrieval.sourceDocuments
    }

    private func shouldIncludeReferenceKnowledge(for query: String) -> Bool {
        if ClickyKnowledgeRetriever.shouldOpenDocumentsDirectly(for: query) {
            return true
        }

        if ClickyProcedureQuery.isProcedural(query),
           !ClickyKnowledgeRetriever.isKnowledgeDocumentQuery(query) {
            return false
        }
        return ClickyKnowledgeRetriever.isExplicitKnowledgeBaseQuestion(query)
    }

    private func persistCatalogSnapshot(using store: ClickyKnowledgeStore) throws {
        let documents = try store.allDocuments()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let catalogData = try encoder.encode(documents)
        try catalogData.write(to: ClickyKnowledgePaths.catalogURL, options: .atomic)
    }

    private func reloadDocuments(using store: ClickyKnowledgeStore) {
        do {
            documents = try store.allDocuments()
            documentCount = documents.count
        } catch {
            print("⚠️ Knowledge reload failed: \(error.localizedDescription)")
        }
    }
}
