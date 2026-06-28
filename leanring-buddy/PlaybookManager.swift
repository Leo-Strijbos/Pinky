//
//  PlaybookManager.swift
//  leanring-buddy
//
//  Central coordinator for playbook storage, import, recording, and retrieval.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PlaybookManager: ObservableObject {
    @Published private(set) var playbooks: [Playbook] = []
    @Published private(set) var playbookCount: Int = 0
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStepCount = 0
    @Published private(set) var isProcessing = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var lastError: String?
    @Published var pinnedReferencePlaybookID: String?
    @Published var selectedPlaybookID: String?

    private var store: PlaybookStore?
    private let recorder = PlaybookRecorder()
    private var recordingRefreshTask: Task<Void, Never>?

    init() {
        do {
            try FileManager.default.createDirectory(
                at: PlaybookPaths.playbookRootDirectory,
                withIntermediateDirectories: true
            )
            let openedStore = try PlaybookStore()
            store = openedStore
            PlaybookMigration.migrateIfNeeded(into: openedStore)
            reloadCatalog(using: openedStore)
        } catch {
            print("⚠️ Playbook store failed to initialize: \(error.localizedDescription)")
            store = nil
        }
    }

    // MARK: - Catalog

    func reloadCatalog() {
        guard let store else { return }
        reloadCatalog(using: store)
    }

    func playbook(withID id: String) -> Playbook? {
        playbooks.first { $0.id == id }
    }

    func steps(forPlaybookID id: String) -> [PlaybookStep] {
        guard let store else { return [] }
        return (try? store.steps(forPlaybookID: id)) ?? []
    }

    func filteredPlaybooks(searchText: String, kind: PlaybookKind?) -> [Playbook] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return playbooks.filter { playbook in
            if let kind, playbook.kind != kind { return false }
            guard !trimmed.isEmpty else { return true }

            if playbook.title.lowercased().contains(trimmed) { return true }
            if playbook.summary.lowercased().contains(trimmed) { return true }
            if playbook.tags.contains(where: { $0.lowercased().contains(trimmed) }) { return true }
            return false
        }
    }

    // MARK: - Import

    func presentImportPanel(kind: PlaybookKind, claudeAPI: ClaudeAPI) {
        let openPanel = NSOpenPanel()
        openPanel.title = kind == .procedure ? "Add procedure" : "Add reference document"
        openPanel.message = "Choose a PDF to convert into a company playbook."
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.pdf]

        openPanel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                for url in openPanel.urls {
                    await self?.importPDF(from: url, kind: kind, claudeAPI: claudeAPI)
                }
            }
        }
    }

    func importPDF(from sourceURL: URL, kind: PlaybookKind, claudeAPI: ClaudeAPI) async {
        guard let store else {
            lastError = "Storage is unavailable."
            return
        }

        lastError = nil
        isProcessing = true
        defer { isProcessing = false }

        do {
            let result = try await PlaybookPDFImporter.importPDF(
                from: sourceURL,
                preferredKind: kind,
                claudeAPI: claudeAPI
            )
            try store.upsertPlaybook(result.playbook, steps: result.steps, chunks: result.chunks)
            persistCatalog(using: store)
            reloadCatalog(using: store)
            selectedPlaybookID = result.playbook.id
            lastMessage = "Added \"\(result.playbook.title)\""
            print("📘 Playbook imported: \(result.playbook.title)")
        } catch {
            lastError = error.localizedDescription
            print("⚠️ Playbook import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard store != nil else {
            lastError = "Storage is unavailable."
            return
        }

        lastError = nil
        lastMessage = nil
        recorder.start()
        isRecording = true
        recordingStepCount = 0

        recordingRefreshTask?.cancel()
        recordingRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isRecording else { return }
                self.recordingStepCount = self.recorder.snapshotCount
            }
        }
    }

    func stopRecording(claudeAPI: ClaudeAPI) async {
        guard let store else {
            lastError = "Storage is unavailable."
            return
        }

        recordingRefreshTask?.cancel()
        recordingRefreshTask = nil
        isRecording = false

        let snapshots = recorder.stop()
        recordingStepCount = 0

        guard !snapshots.isEmpty else {
            lastError = "No steps were captured."
            return
        }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        do {
            let title = defaultRecordingTitle()
            let (playbook, steps) = try await PlaybookRecordingBuilder.buildPlaybook(
                from: snapshots,
                title: title,
                claudeAPI: claudeAPI
            )
            try store.upsertPlaybook(playbook, steps: steps)
            persistCatalog(using: store)
            reloadCatalog(using: store)
            selectedPlaybookID = playbook.id
            lastMessage = "Saved \"\(playbook.title)\" (\(steps.count) steps)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func attachNarration(_ transcript: String) {
        guard isRecording else { return }
        recorder.attachNarration(transcript)
        lastMessage = "Narration saved for step \(recorder.snapshotCount)"
    }

    func resetRecordingFromHere() {
        guard isRecording else { return }
        Task {
            await recorder.resetFromHere()
            recordingStepCount = recorder.snapshotCount
            lastMessage = "Recording restarted from here"
        }
    }

    // MARK: - Delete

    func deletePlaybook(id: String) {
        guard let store else { return }
        lastError = nil

        do {
            try store.deletePlaybook(id: id)
            persistCatalog(using: store)
            reloadCatalog(using: store)
            if selectedPlaybookID == id { selectedPlaybookID = nil }
            if pinnedReferencePlaybookID == id { pinnedReferencePlaybookID = nil }
            lastMessage = "Playbook removed"
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Voice retrieval

    func retrieveProcedure(for query: String) -> PlaybookRetrieval? {
        guard let store else { return nil }
        return try? PlaybookRetriever.retrieveProcedure(query: query, store: store)
    }

    func referenceAppendix(for query: String) -> String {
        plannerReferenceAppendix(for: query, includeForProcedural: false)
    }

    /// Reference excerpts for session planning — retrieves matching chunks even for procedural how-to requests.
    func plannerReferenceAppendix(
        for query: String,
        includeForProcedural: Bool = true
    ) -> String {
        guard let store else { return "" }

        if let pinnedID = pinnedReferencePlaybookID {
            if let retrieval = try? PlaybookRetriever.retrieveReference(
                query: query,
                store: store,
                playbookID: pinnedID
            ) {
                return retrieval.promptFragment()
            }
        }

        if !includeForProcedural {
            guard PlaybookRetriever.isReferenceQuery(query)
                || PlaybookRetriever.shouldOpenDocument(for: query)
                || !ClickyProcedureQuery.isProcedural(query) else {
                return ""
            }
        }

        guard let retrieval = try? PlaybookRetriever.retrieveReference(query: query, store: store) else {
            return ""
        }
        return retrieval.promptFragment()
    }

    func resolveProcedureContext(
        for query: String,
        pinnedSession: CompanionActiveSession? = nil
    ) -> (retrieval: PlaybookRetrieval?, screenStepIndex: Int?) {
        guard let store else { return (nil, nil) }

        if let pinnedSession, let playbookID = pinnedSession.plan.playbookID {
            let steps = (try? store.steps(forPlaybookID: playbookID)) ?? pinnedSession.plan.playbookSteps ?? []
            if let playbook = try? store.playbook(withID: playbookID) {
                let retrieval = PlaybookRetrieval(
                    playbook: playbook,
                    steps: steps,
                    relevanceScore: 1.0
                )
                return (retrieval, pinnedSession.currentIndex)
            }
        }

        guard let retrieval = try? PlaybookRetriever.retrieveProcedure(query: query, store: store) else {
            return (nil, nil)
        }

        let context = PlaybookScreenContextCapture.captureCurrentContext()
        let match = PlaybookRetriever.matchScreenContext(steps: retrieval.steps, context: context)
        return (retrieval, match?.stepIndex)
    }

    func procedureAppendix(
        retrieval: PlaybookRetrieval?,
        screenStepIndex: Int?,
        pinnedSession: CompanionActiveSession?
    ) -> String {
        PlaybookSessionAdapter.procedureAppendix(
            retrieval: retrieval,
            screenMatchIndex: screenStepIndex,
            pinnedSession: pinnedSession
        )
    }

    func sourceDocuments(for query: String) -> [PlaybookSourceDocument] {
        guard let store else { return [] }

        if PlaybookRetriever.shouldOpenDocument(for: query),
           let match = playbooks.first(where: { query.lowercased().contains($0.title.lowercased()) }),
           let fileURL = match.sourceFileURL {
            return [
                PlaybookSourceDocument(
                    playbookID: match.id,
                    title: match.title,
                    fileURL: fileURL,
                    pageIndex: 0
                ),
            ]
        }

        return []
    }

    func pinReferencePlaybook(id: String?) {
        pinnedReferencePlaybookID = id
    }

    // MARK: - Private

    private func reloadCatalog(using store: PlaybookStore) {
        do {
            playbooks = try store.allPlaybooks()
            playbookCount = playbooks.count
        } catch {
            print("⚠️ Playbook reload failed: \(error.localizedDescription)")
        }
    }

    private func persistCatalog(using store: PlaybookStore) {
        do {
            let catalog = try store.allPlaybooks()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(catalog)
            try data.write(to: PlaybookPaths.catalogURL, options: .atomic)
        } catch {
            print("⚠️ Playbook catalog persist failed: \(error.localizedDescription)")
        }
    }

    private func defaultRecordingTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Procedure \(formatter.string(from: Date()))"
    }
}
