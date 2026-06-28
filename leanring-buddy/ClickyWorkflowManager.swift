//
//  ClickyWorkflowManager.swift
//  leanring-buddy
//
//  Coordinates workflow recording, indexing, and screen-state matching.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ClickyWorkflowManager: ObservableObject {
    @Published private(set) var workflowCount: Int = 0
    @Published private(set) var screenStateCount: Int = 0
    @Published private(set) var workflows: [ClickyWorkflow] = []
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSnapshotCount = 0
    @Published private(set) var isProcessingRecording = false
    @Published private(set) var lastWorkflowMessage: String?
    @Published private(set) var lastWorkflowError: String?
    @Published private(set) var lastNarrationMessage: String?

    private var store: ClickyWorkflowStore?
    private var recorder = ClickyWorkflowRecorder()
    private var recordingRefreshTask: Task<Void, Never>?

    init() {
        do {
            try FileManager.default.createDirectory(
                at: ClickyWorkflowPaths.workflowRootDirectory,
                withIntermediateDirectories: true
            )
            let openedStore = try ClickyWorkflowStore()
            store = openedStore
            reloadCatalog(using: openedStore)
        } catch {
            print("⚠️ Clicky workflow store failed to initialize: \(error.localizedDescription)")
            store = nil
        }
    }

    func startRecording() {
        guard store != nil else {
            lastWorkflowError = "Workflow storage is unavailable."
            return
        }

        lastWorkflowError = nil
        lastWorkflowMessage = nil
        lastNarrationMessage = nil
        recorder.start()
        isRecording = true
        recordingSnapshotCount = 0

        recordingRefreshTask?.cancel()
        recordingRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isRecording else { return }
                self.recordingSnapshotCount = self.recorder.snapshotCount
            }
        }
    }

    func stopRecording(claudeAPI: ClaudeAPI) async {
        guard let store else {
            lastWorkflowError = "Workflow storage is unavailable."
            return
        }

        recordingRefreshTask?.cancel()
        recordingRefreshTask = nil
        isRecording = false

        let snapshots = recorder.stop()
        recordingSnapshotCount = 0

        guard !snapshots.isEmpty else {
            lastWorkflowError = "No workflow screens were captured."
            return
        }

        isProcessingRecording = true
        lastWorkflowError = nil
        defer { isProcessingRecording = false }

        do {
            let workflowID = UUID().uuidString.lowercased()
            let workflowName = defaultWorkflowName()
            let states = try await ClickyWorkflowIndexer.buildScreenStates(
                workflowID: workflowID,
                snapshots: snapshots,
                claudeAPI: claudeAPI
            )
            let metadata = try await ClickyWorkflowIndexer.buildWorkflowMetadata(
                name: workflowName,
                states: states,
                claudeAPI: claudeAPI
            )

            let workflow = ClickyWorkflow(
                id: workflowID,
                name: workflowName,
                summary: metadata.summary,
                goal: metadata.goal,
                triggerPhrases: metadata.triggerPhrases,
                recordedAt: Date(),
                stateCount: states.count
            )

            try store.upsertWorkflow(workflow, states: states)
            try persistCatalogSnapshot(using: store)
            reloadCatalog(using: store)
            lastWorkflowMessage = "Saved workflow \"\(workflowName)\" (\(states.count) screens)"
            print("🎬 Workflow saved: \(workflowName) with \(states.count) screen states")
        } catch {
            lastWorkflowError = error.localizedDescription
            print("⚠️ Workflow processing failed: \(error.localizedDescription)")
        }
    }

    func resetRecordingFromHere() {
        guard isRecording else { return }
        Task {
            await recorder.resetFromHere()
            recordingSnapshotCount = recorder.snapshotCount
            lastWorkflowMessage = "Recording restarted from current screen"
        }
    }

    func attachNarration(_ transcript: String) {
        guard isRecording else { return }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        recorder.attachNarration(trimmed)
        lastNarrationMessage = "Narration saved for step \(recorder.snapshotCount)"
        print("🎬 Workflow narration: \(trimmed)")
    }

    func resolveWorkflowContext(
        for query: String,
        cursorScreenCapture: CompanionScreenCapture? = nil
    ) async -> ClickyWorkflowContextResult {
        guard let store else {
            return ClickyWorkflowContextResult(retrieval: nil, screenMatch: nil)
        }

        do {
            let retrieval = try ClickyWorkflowRetriever.retrieve(query: query, store: store)

            let screenMatch = await matchCurrentScreen(
                preferCoreStates: true,
                cursorScreenCapture: cursorScreenCapture
            )
            return ClickyWorkflowContextResult(retrieval: retrieval, screenMatch: screenMatch)
        } catch {
            print("⚠️ Workflow context resolution failed: \(error.localizedDescription)")
            let screenMatch = await matchCurrentScreen(
                preferCoreStates: true,
                cursorScreenCapture: cursorScreenCapture
            )
            return ClickyWorkflowContextResult(retrieval: nil, screenMatch: screenMatch)
        }
    }

    func matchCurrentScreen(
        preferCoreStates: Bool = true,
        cursorScreenCapture: CompanionScreenCapture? = nil
    ) async -> ClickyWorkflowMatch? {
        guard let store else { return nil }

        do {
            let states = try store.allScreenStates()
            guard !states.isEmpty else { return nil }

            let workflows = try store.allWorkflows()
            let workflowsByID = Dictionary(uniqueKeysWithValues: workflows.map { ($0.id, $0) })
            let recordedStates = states.filter { workflowsByID[$0.workflowID]?.source == .recorded }
            guard !recordedStates.isEmpty else { return nil }

            let baseContext = ClickyWorkflowContextCapture.captureCurrentContext()
            let initial = ClickyScreenStateMatcher.evaluateMatch(
                context: baseContext,
                states: recordedStates,
                workflowsByID: workflowsByID,
                preferCoreStates: preferCoreStates
            )

            if let match = initial.match, !initial.needsOCR {
                return match
            }

            guard initial.needsOCR else {
                return initial.match
            }

            let cursorScreen: CompanionScreenCapture?
            if let cursorScreenCapture {
                cursorScreen = cursorScreenCapture
            } else {
                cursorScreen = try? await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
            }

            guard let cursorScreen else {
                return initial.match
            }

            let terms = ClickyWorkflowOCR.recognizeTerms(from: cursorScreen.imageData)
            let enrichedContext = ClickyWorkflowScreenContext(
                app: baseContext.app,
                url: baseContext.url,
                windowTitle: baseContext.windowTitle,
                ocrTerms: terms,
                visualFingerprint: nil
            )

            return ClickyScreenStateMatcher.bestMatch(
                context: enrichedContext,
                states: recordedStates,
                workflowsByID: workflowsByID,
                preferCoreStates: preferCoreStates
            ) ?? initial.match
        } catch {
            print("⚠️ Workflow screen match failed: \(error.localizedDescription)")
            return nil
        }
    }

    func procedureAppendix(for result: ClickyWorkflowContextResult) -> String {
        result.promptAppendix()
    }

    func sourceDocuments(for result: ClickyWorkflowContextResult, knowledgeManager: ClickyKnowledgeManager) -> [ClickyKnowledgeSourceDocument] {
        let workflow = result.screenMatch?.workflow ?? result.retrieval?.workflow
        guard let workflow, workflow.source == .pdf, let documentID = workflow.sourceDocumentID else {
            return []
        }
        return knowledgeManager.sourceDocument(forDocumentID: documentID, pageIndex: 0).map { [$0] } ?? []
    }

    func deleteWorkflowsLinkedToDocument(documentID: String) {
        guard let store else { return }

        do {
            let linked = try store.workflows(withSourceDocumentID: documentID)
            for workflow in linked {
                try store.deleteWorkflow(id: workflow.id)
            }
            if !linked.isEmpty {
                try persistCatalogSnapshot(using: store)
                reloadCatalog(using: store)
            }
        } catch {
            print("⚠️ Could not delete linked workflows: \(error.localizedDescription)")
        }
    }

    func importProcedureWorkflow(
        document: ClickyKnowledgeDocument,
        claudeAPI: ClaudeAPI
    ) async throws {
        guard let store else {
            throw NSError(domain: "ClickyWorkflowManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Workflow storage is unavailable.",
            ])
        }

        let parsed = try await ClickyProcedurePDFImporter.buildProcedure(
            document: document,
            claudeAPI: claudeAPI
        )

        if let existing = try store.workflows(withSourceDocumentID: document.id).first {
            try store.deleteWorkflow(id: existing.id)
        }

        try store.upsertWorkflow(parsed.workflow, states: parsed.steps)
        try persistCatalogSnapshot(using: store)
        reloadCatalog(using: store)
        lastWorkflowMessage = "Indexed procedure \"\(document.title)\" (\(parsed.steps.count) steps)"
        print("📋 Procedure workflow saved: \(document.title) with \(parsed.steps.count) steps")
    }

    func revealWorkflowFolderInFinder() {
        NSWorkspace.shared.open(ClickyWorkflowPaths.workflowRootDirectory)
    }

    func screenStates(forWorkflowID workflowID: String) -> [ClickyWorkflowScreenState] {
        guard let store else { return [] }
        return (try? store.screenStates(forWorkflowID: workflowID)) ?? []
    }

    func retrieveWorkflow(for query: String) -> ClickyWorkflowRetrieval? {
        guard let store else { return nil }
        return try? ClickyWorkflowRetriever.retrieve(query: query, store: store)
    }

    func retrieveStoredProcedure(for query: String) -> ClickyWorkflowRetrieval? {
        guard let store else { return nil }
        return try? ClickyWorkflowRetriever.retrieveStoredProcedure(query: query, store: store)
    }

    func orderedProcedureSteps(forWorkflowID workflowID: String) -> [ClickyWorkflowScreenState] {
        let ordered = screenStates(forWorkflowID: workflowID).sorted { $0.stepIndex < $1.stepIndex }
        let coreSteps = ordered.filter(\.isCoreState)
        return coreSteps.isEmpty ? ordered : coreSteps
    }

    func resolveWorkflowContextForPinnedSession(
        session: CompanionActiveSession,
        cursorScreenCapture: CompanionScreenCapture? = nil
    ) async -> ClickyWorkflowContextResult {
        guard
            session.plan.source == .storedProcedure,
            let playbookID = session.plan.playbookID,
            let store,
            let workflow = try? store.workflow(withID: playbookID)
        else {
            let screenMatch = await matchCurrentScreen(
                preferCoreStates: true,
                cursorScreenCapture: cursorScreenCapture
            )
            return ClickyWorkflowContextResult(retrieval: nil, screenMatch: screenMatch)
        }

        let workflowSteps = (try? store.screenStates(forWorkflowID: playbookID)) ?? []

        let retrieval = ClickyWorkflowRetrieval(
            workflow: workflow,
            steps: workflowSteps,
            relevanceScore: 1.0
        )

        var screenMatch = await matchCurrentScreen(
            preferCoreStates: true,
            cursorScreenCapture: cursorScreenCapture
        )
        if let match = screenMatch, match.workflow.id != workflow.id {
            screenMatch = nil
        }

        return ClickyWorkflowContextResult(retrieval: retrieval, screenMatch: screenMatch)
    }

    func deleteWorkflow(id: String) {
        guard let store else {
            lastWorkflowError = "Workflow storage is unavailable."
            return
        }

        lastWorkflowError = nil

        do {
            guard let workflow = try store.workflow(withID: id) else {
                lastWorkflowError = "Workflow not found."
                return
            }
            try store.deleteWorkflow(id: id)
            try persistCatalogSnapshot(using: store)
            reloadCatalog(using: store)
            lastWorkflowMessage = "Deleted workflow \"\(workflow.name)\""
            print("🎬 Workflow deleted: \(workflow.name)")
        } catch {
            lastWorkflowError = error.localizedDescription
            print("⚠️ Workflow delete failed: \(error.localizedDescription)")
        }
    }

    func saveWorkflowEdits(
        workflowID: String,
        name: String,
        goal: String,
        summary: String,
        triggerPhrases: [String],
        steps: [ClickyWorkflowScreenState]
    ) {
        guard let store else {
            lastWorkflowError = "Workflow storage is unavailable."
            return
        }

        lastWorkflowError = nil

        do {
            guard let existing = try store.workflow(withID: workflowID) else { return }

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                lastWorkflowError = "Workflow name can't be empty."
                return
            }

            let renumberedSteps = steps.enumerated().map { index, step in
                ClickyWorkflowScreenState(
                    id: step.id,
                    workflowID: workflowID,
                    stepIndex: index,
                    name: step.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    app: step.app,
                    urlPattern: step.urlPattern,
                    windowTitlePattern: step.windowTitlePattern,
                    meaning: step.meaning.trimmingCharacters(in: .whitespacesAndNewlines),
                    userIntent: step.userIntent,
                    spokenDescription: step.spokenDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                    isEntryState: step.isEntryState,
                    ocrTerms: step.ocrTerms,
                    commonQuestions: step.commonQuestions,
                    relatedSOPIDs: step.relatedSOPIDs,
                    visualFingerprint: step.visualFingerprint,
                    thumbnailFilename: step.thumbnailFilename,
                    capturedAt: step.capturedAt
                )
            }

            guard !renumberedSteps.isEmpty else {
                lastWorkflowError = "Workflow needs at least one step."
                return
            }

            let existingStates = try store.screenStates(forWorkflowID: workflowID)
            let newStepIDs = Set(renumberedSteps.map(\.id))
            for removedState in existingStates where !newStepIDs.contains(removedState.id) {
                ClickyWorkflowPaths.removeWorkflowAsset(at: removedState.thumbnailURL)
            }

            let updatedWorkflow = ClickyWorkflow(
                id: existing.id,
                name: trimmedName,
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                triggerPhrases: triggerPhrases
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                recordedAt: existing.recordedAt,
                stateCount: renumberedSteps.count,
                source: existing.source,
                sourceDocumentID: existing.sourceDocumentID
            )

            try store.upsertWorkflow(updatedWorkflow, states: renumberedSteps)
            try persistCatalogSnapshot(using: store)
            reloadCatalog(using: store)
            lastWorkflowMessage = "Updated workflow \"\(trimmedName)\""
            print("🎬 Workflow updated: \(trimmedName)")
        } catch {
            lastWorkflowError = error.localizedDescription
            print("⚠️ Workflow update failed: \(error.localizedDescription)")
        }
    }

    private func defaultWorkflowName() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Workflow \(formatter.string(from: Date()))"
    }

    private func persistCatalogSnapshot(using store: ClickyWorkflowStore) throws {
        let workflows = try store.allWorkflows()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let catalogData = try encoder.encode(workflows)
        try catalogData.write(to: ClickyWorkflowPaths.catalogURL, options: .atomic)
    }

    private func reloadCatalog(using store: ClickyWorkflowStore) {
        do {
            workflows = try store.allWorkflows()
            workflowCount = workflows.count
            screenStateCount = try store.screenStateCount()
        } catch {
            print("⚠️ Workflow reload failed: \(error.localizedDescription)")
        }
    }
}
