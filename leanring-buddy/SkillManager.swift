//
//  SkillManager.swift
//  leanring-buddy
//
//  Central coordinator for Agent Skills storage, teaching, import, and retrieval.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SkillManager: ObservableObject {
    @Published private(set) var skills: [AgentSkill] = []
    @Published private(set) var skillCount: Int = 0
    @Published private(set) var isTeaching = false
    @Published private(set) var teachingStepCount = 0
    @Published private(set) var isProcessing = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var pendingDraft: SkillDraft?
    @Published var pendingDraftTitle: String = ""
    @Published var pinnedReferenceSkillName: String?
    @Published var selectedSkillName: String?

    private var store: SkillStore?
    private let teachingCapture = TeachingCaptureCoordinator()
    private let interpreter: TeachingInterpreter = NarrationPrimaryTeachingInterpreter()
    private var pendingArtifact: TeachingArtifact?
    private var teachingRefreshTask: Task<Void, Never>?

    init() {
        do {
            try FileManager.default.createDirectory(
                at: SkillPaths.applicationSupportDirectory,
                withIntermediateDirectories: true
            )
            store = try SkillStore()
            reloadCatalog()
        } catch {
            print("⚠️ Skill store failed to initialize: \(error.localizedDescription)")
            store = nil
        }
    }

    // MARK: - Catalog

    func reloadCatalog() {
        guard let store else { return }
        do {
            skills = try store.allSkills()
            skillCount = skills.count
        } catch {
            print("⚠️ Skill reload failed: \(error.localizedDescription)")
        }
    }

    func skill(named name: String) -> AgentSkill? {
        skills.first { $0.name == name }
    }

    func playbackSteps(forSkillName name: String) -> [SkillPlaybackStep] {
        skill(named: name)?.playbackSteps ?? []
    }

    func filteredSkills(searchText: String, kind: SkillKind?) -> [AgentSkill] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return skills.filter { skill in
            if let kind, skill.kind != kind { return false }
            guard !trimmed.isEmpty else { return true }

            if skill.name.contains(trimmed) { return true }
            if skill.title.lowercased().contains(trimmed) { return true }
            if skill.description.lowercased().contains(trimmed) { return true }
            if skill.tags.contains(where: { $0.lowercased().contains(trimmed) }) { return true }
            return false
        }
    }

    // MARK: - Import

    func presentImportPanel(kind: SkillKind, claudeAPI: ClaudeAPI) {
        let openPanel = NSOpenPanel()
        openPanel.title = kind == .procedure ? "Add procedure skill" : "Add reference skill"
        openPanel.message = "Choose a PDF to convert into an Agent Skill."
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

    func importPDF(from sourceURL: URL, kind: SkillKind, claudeAPI: ClaudeAPI) async {
        guard store != nil else {
            lastError = "Storage is unavailable."
            return
        }

        lastError = nil
        isProcessing = true
        defer { isProcessing = false }

        do {
            let existingNames = Set(skills.map(\.name))
            let skill = try await SkillPDFImporter.importPDF(
                from: sourceURL,
                preferredKind: kind,
                claudeAPI: claudeAPI,
                existingNames: existingNames
            )
            reloadCatalog()
            selectedSkillName = skill.name
            lastMessage = "Added skill \"\(skill.title)\""
            print("📗 Skill imported: \(skill.name)")
        } catch {
            lastError = error.localizedDescription
            print("⚠️ Skill import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Teaching

    func startTeaching() {
        guard store != nil else {
            lastError = "Storage is unavailable."
            return
        }

        lastError = nil
        lastMessage = nil
        pendingDraft = nil
        pendingArtifact = nil
        pendingDraftTitle = ""

        teachingCapture.start()
        isTeaching = true
        teachingStepCount = 0

        teachingRefreshTask?.cancel()
        teachingRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.isTeaching else { return }
                self.teachingStepCount = self.teachingCapture.keyframeCount
            }
        }
    }

    func stopTeaching(claudeAPI: ClaudeAPI) async -> SkillDraft? {
        teachingRefreshTask?.cancel()
        teachingRefreshTask = nil
        isTeaching = false
        teachingStepCount = 0

        guard let artifact = await teachingCapture.stop() else {
            lastError = "No teaching session was active."
            return nil
        }

        guard !artifact.keyframes.isEmpty || !artifact.signals.isEmpty else {
            lastError = TeachingInterpreterError.emptyArtifact.localizedDescription
            return nil
        }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        do {
            let draft = try await interpreter.buildDraft(from: artifact, claudeAPI: claudeAPI)
            pendingArtifact = artifact
            pendingDraft = draft
            pendingDraftTitle = draft.suggestedTitle
            return draft
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func confirmTeachingSave(title: String? = nil) async {
        guard let store, let draft = pendingDraft, let artifact = pendingArtifact else {
            lastError = "Nothing to save."
            return
        }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        do {
            let resolvedTitle = (title ?? pendingDraftTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = resolvedTitle.isEmpty ? draft.suggestedTitle : resolvedTitle
            let baseName = draft.suggestedName.isEmpty
                ? SkillNameFormatter.kebabCase(from: finalTitle)
                : draft.suggestedName
            let skillName = SkillNameFormatter.uniqueName(
                base: baseName,
                existing: Set(skills.map(\.name))
            )

            let skill = try SkillWriter.writeSkill(
                from: draft,
                artifact: artifact,
                name: skillName,
                title: finalTitle
            )
            try store.upsert(skill)
            reloadCatalog()
            selectedSkillName = skill.name
            pendingDraft = nil
            pendingArtifact = nil
            pendingDraftTitle = ""
            lastMessage = "Saved skill \"\(skill.title)\" (\(skill.playbackSteps.count) steps)"
            print("📗 Skill saved: \(skill.directoryURL.path)")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelPendingDraft() {
        pendingDraft = nil
        pendingArtifact = nil
        pendingDraftTitle = ""
        lastMessage = "Workflow discarded"
    }

    func attachNarration(_ transcript: String) {
        guard isTeaching else { return }
        Task {
            await teachingCapture.attachNarration(transcript)
            teachingStepCount = teachingCapture.keyframeCount
            lastMessage = "Narration saved for step \(teachingStepCount)"
        }
    }

    func resetTeachingFromHere() {
        guard isTeaching else { return }
        Task {
            await teachingCapture.resetFromHere()
            teachingStepCount = teachingCapture.keyframeCount
            lastMessage = "Teaching restarted from here"
        }
    }

    func deleteSkill(named name: String) {
        guard let store else { return }
        lastError = nil

        do {
            try store.deleteSkill(named: name)
            reloadCatalog()
            if selectedSkillName == name { selectedSkillName = nil }
            if pinnedReferenceSkillName == name { pinnedReferenceSkillName = nil }
            lastMessage = "Skill removed"
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Voice retrieval

    func retrieveProcedure(for query: String) -> SkillRetrieval? {
        if let match = SkillRetriever.retrieveProcedure(query: query, skills: skills) {
            return match
        }
        return recentRecordedProcedureFallback(for: query)
    }

    private func recentRecordedProcedureFallback(for query: String) -> SkillRetrieval? {
        let normalized = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let ownershipPhrases = [
            "my workflow", "the workflow", "that workflow", "this workflow",
            "my procedure", "the procedure", "that procedure", "this procedure",
            "i taught", "i recorded", "i showed you", "what did i teach",
            "what workflow", "that thing i taught", "the thing i taught",
        ]
        guard ownershipPhrases.contains(where: { normalized.contains($0) }) else {
            return nil
        }

        let recorded = skills
            .filter { $0.kind == .procedure && $0.source == .recorded && !$0.playbackSteps.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }

        guard let skill = recorded.first else { return nil }
        return SkillRetrieval(skill: skill, steps: skill.playbackSteps, relevanceScore: 0.5)
    }

    func referenceAppendix(for query: String) -> String {
        plannerReferenceAppendix(for: query, includeForProcedural: false)
    }

    func plannerReferenceAppendix(
        for query: String,
        includeForProcedural: Bool = true
    ) -> String {
        if let pinnedName = pinnedReferenceSkillName {
            if let retrieval = SkillRetriever.retrieveReference(
                query: query,
                skills: skills,
                skillName: pinnedName
            ) {
                return retrieval.promptFragment()
            }
        }

        if !includeForProcedural {
            guard SkillRetriever.isReferenceQuery(query)
                || SkillRetriever.shouldOpenDocument(for: query)
                || !PinkyProcedureQuery.isProcedural(query) else {
                return ""
            }
        }

        guard let retrieval = SkillRetriever.retrieveReference(query: query, skills: skills) else {
            return ""
        }
        return retrieval.promptFragment()
    }

    func resolveProcedureContext(
        for query: String,
        pinnedSession: CompanionActiveSession? = nil
    ) -> (retrieval: SkillRetrieval?, screenStepIndex: Int?) {
        if let pinnedSession, let skillName = pinnedSession.plan.skillName {
            let steps = pinnedSession.plan.skillSteps ?? playbackSteps(forSkillName: skillName)
            if let skill = skill(named: skillName) {
                let retrieval = SkillRetrieval(skill: skill, steps: steps, relevanceScore: 1.0)
                return (retrieval, pinnedSession.currentIndex)
            }
        }

        guard let retrieval = retrieveProcedure(for: query) else {
            return (nil, nil)
        }

        let context = ScreenContextCapture.captureCurrentContext()
        let match = SkillRetriever.matchScreenContext(steps: retrieval.steps, context: context)
        return (retrieval, match?.stepIndex)
    }

    func procedureAppendix(
        retrieval: SkillRetrieval?,
        screenStepIndex: Int?,
        pinnedSession: CompanionActiveSession?
    ) -> String {
        SkillSessionAdapter.procedureAppendix(
            retrieval: retrieval,
            screenMatchIndex: screenStepIndex,
            pinnedSession: pinnedSession
        )
    }

    func sourceDocuments(for query: String) -> [SkillSourceDocument] {
        if SkillRetriever.shouldOpenDocument(for: query),
           let match = skills.first(where: { query.lowercased().contains($0.title.lowercased()) }),
           let fileURL = match.sourceFileURL {
            return [
                SkillSourceDocument(
                    skillName: match.name,
                    title: match.title,
                    fileURL: fileURL,
                    pageIndex: 0
                ),
            ]
        }
        return []
    }

    func pinReferenceSkill(name: String?) {
        pinnedReferenceSkillName = name
    }
}
