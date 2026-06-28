//
//  PlaybookMigration.swift
//  leanring-buddy
//
//  One-time migration from legacy workflow and knowledge stores.
//

import Foundation

enum PlaybookMigration {

    static func migrateIfNeeded(into store: PlaybookStore) {
        do {
            let existingCount = try store.playbookCount()
            guard existingCount == 0 else { return }

            var migrated = 0

            if let workflowStore = try? ClickyWorkflowStore() {
                migrated += try migrateWorkflows(from: workflowStore, into: store)
            }

            if let knowledgeStore = try? ClickyKnowledgeStore() {
                migrated += try migrateKnowledge(from: knowledgeStore, into: store)
            }

            if migrated > 0 {
                print("📘 Playbook migration: imported \(migrated) playbooks from legacy stores")
            }
        } catch {
            print("⚠️ Playbook migration failed: \(error.localizedDescription)")
        }
    }

    private static func migrateWorkflows(from workflowStore: ClickyWorkflowStore, into store: PlaybookStore) throws -> Int {
        let workflows = try workflowStore.allWorkflows()
        var count = 0

        for workflow in workflows {
            let states = try workflowStore.screenStates(forWorkflowID: workflow.id)
            let steps = states.sorted { $0.stepIndex < $1.stepIndex }.map { state in
                PlaybookStep(
                    id: state.id,
                    playbookID: workflow.id,
                    index: state.stepIndex,
                    title: state.name,
                    instruction: state.spokenDescription.isEmpty ? state.meaning : state.spokenDescription,
                    contextApp: state.app.isEmpty ? nil : state.app,
                    contextURLPattern: state.urlPattern,
                    contextWindowPattern: state.windowTitlePattern,
                    lookFor: state.name,
                    doneWhen: nil,
                    thumbnailFilename: state.thumbnailFilename == "__pdf_procedure__.jpg" ? nil : state.thumbnailFilename,
                    capturedAt: state.capturedAt
                )
            }

            let kind: PlaybookKind = steps.isEmpty ? .reference : .procedure
            let source: PlaybookSource = workflow.source == .pdf ? .pdfImport : .recorded
            var sourceFilename: String?

            if workflow.source == .pdf, let docID = workflow.sourceDocumentID {
                sourceFilename = "\(docID).pdf"
                let legacyPath = ClickyKnowledgePaths.documentsDirectory.appendingPathComponent("\(docID).pdf")
                let destPath = PlaybookPaths.documentsDirectory.appendingPathComponent("\(docID).pdf")
                if FileManager.default.fileExists(atPath: legacyPath.path),
                   !FileManager.default.fileExists(atPath: destPath.path) {
                    try? FileManager.default.copyItem(at: legacyPath, to: destPath)
                }
            }

            let docBlocks = buildDocBlocks(
                title: workflow.name,
                summary: workflow.summary.isEmpty ? workflow.goal : workflow.summary,
                steps: steps
            )

            let playbook = Playbook(
                id: workflow.id,
                title: workflow.name,
                summary: workflow.summary.isEmpty ? workflow.goal : workflow.summary,
                tags: [],
                kind: kind,
                source: source,
                sourceFilename: sourceFilename,
                stepCount: steps.count,
                triggerPhrases: workflow.triggerPhrases,
                docBlocks: docBlocks,
                createdAt: workflow.recordedAt,
                updatedAt: workflow.recordedAt
            )

            try store.upsertPlaybook(playbook, steps: steps)
            count += 1
        }

        return count
    }

    private static func migrateKnowledge(from knowledgeStore: ClickyKnowledgeStore, into store: PlaybookStore) throws -> Int {
        let documents = try knowledgeStore.allDocuments()
        var count = 0

        for document in documents {
            if (try? store.playbook(withID: document.id)) != nil { continue }
            if document.kind == .procedure { continue }

            let chunks = try knowledgeStore.search(query: document.title, limit: 100)
            let playbookChunks = chunks.map { chunk in
                PlaybookChunk(
                    id: chunk.id,
                    playbookID: document.id,
                    playbookTitle: document.title,
                    pageIndex: chunk.pageIndex,
                    chunkIndex: chunk.chunkIndex,
                    text: chunk.text,
                    relevanceScore: 0
                )
            }

            let destFilename = document.filename
            let legacyPath = document.fileURL
            let destPath = PlaybookPaths.documentsDirectory.appendingPathComponent(destFilename)
            if FileManager.default.fileExists(atPath: legacyPath.path),
               !FileManager.default.fileExists(atPath: destPath.path) {
                try? FileManager.default.copyItem(at: legacyPath, to: destPath)
            }

            let docBlocks: [PlaybookDocBlock] = [
                PlaybookDocBlock(kind: .hero, title: document.title, body: "Reference document"),
                PlaybookDocBlock(
                    kind: .paragraph,
                    body: playbookChunks.prefix(3).map(\.text).joined(separator: "\n\n")
                ),
            ]

            let playbook = Playbook(
                id: document.id,
                title: document.title,
                summary: "Reference document",
                tags: document.aliases,
                kind: .reference,
                source: .pdfImport,
                sourceFilename: destFilename,
                stepCount: 0,
                triggerPhrases: document.aliases,
                docBlocks: docBlocks,
                createdAt: document.importedAt,
                updatedAt: document.importedAt
            )

            try store.upsertPlaybook(playbook, steps: [], chunks: playbookChunks)
            count += 1
        }

        return count
    }

    private static func buildDocBlocks(title: String, summary: String, steps: [PlaybookStep]) -> [PlaybookDocBlock] {
        var blocks: [PlaybookDocBlock] = [
            PlaybookDocBlock(kind: .hero, title: title, body: summary),
        ]

        if !steps.isEmpty {
            blocks.append(PlaybookDocBlock(kind: .heading, title: "Steps"))
            blocks.append(
                PlaybookDocBlock(
                    kind: .steps,
                    items: steps.map { "\($0.title): \($0.instruction)" }
                )
            )
        }

        return blocks
    }
}
