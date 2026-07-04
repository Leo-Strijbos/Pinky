//
//  CompanionTurnService.swift
//  leanring-buddy
//
//  Unified voice agent turn: capture → enrich context → single LLM call → structured side effects.
//

import Foundation

@MainActor
final class CompanionTurnService {
    private let claudeAPI: ClaudeAPI
    private let skillManager: SkillManager
    private let capabilityRegistry: CompanionCapabilityRegistry

    init(
        claudeAPI: ClaudeAPI,
        skillManager: SkillManager,
        capabilityRegistry: CompanionCapabilityRegistry = .standard
    ) {
        self.claudeAPI = claudeAPI
        self.skillManager = skillManager
        self.capabilityRegistry = capabilityRegistry
    }

    struct AgentTurnDelivery {
        let result: CompanionAgentTurnResult
        let cursorScreenCapture: CompanionScreenCapture
        let procedureRetrieval: SkillRetrieval?
        let screenStepIndex: Int?
    }

    func runAgentTurn(
        transcript: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        model: String,
        capabilityContext: CompanionCapabilityContext,
        pinnedProcedureSession: CompanionActiveSession? = nil
    ) async throws -> AgentTurnDelivery {
        let cursorScreenCapture = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()

        let resolved = skillManager.resolveProcedureContext(
            for: transcript,
            pinnedSession: pinnedProcedureSession
        )

        let procedureAppendix: String
        if pinnedProcedureSession != nil {
            procedureAppendix = skillManager.procedureAppendix(
                retrieval: resolved.retrieval,
                screenStepIndex: resolved.screenStepIndex,
                pinnedSession: pinnedProcedureSession
            )
        } else if let retrieval = resolved.retrieval {
            procedureAppendix = retrieval.overviewPromptFragment()
        } else {
            procedureAppendix = ""
        }

        let knowledgeAppendix = skillManager.plannerReferenceAppendix(
            for: transcript,
            includeForProcedural: true
        )
        let needsLiveData = PinkyLiveDataQuery.requiresFreshWebSearch(transcript)
        let liveDataAppendix = needsLiveData ? PinkyLiveDataQuery.liveDataSystemPromptAppendix : nil

        let systemPrompt = CompanionAgentPrompt.agentSystemPrompt(
            workflowAppendix: procedureAppendix,
            knowledgeAppendix: knowledgeAppendix,
            liveDataAppendix: liveDataAppendix
        )

        let userPrompt = needsLiveData
            ? PinkyLiveDataQuery.forcedSearchUserPrompt(for: transcript)
            : transcript

        let labeledImages = labeledImages(from: cursorScreenCapture)
        var context = capabilityContext
        context.screenCapture = cursorScreenCapture

        var agentResult = try await claudeAPI.sendVisionAgentTurn(
            images: labeledImages,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            model: model,
            includeWebSearch: true,
            capabilityRegistry: capabilityRegistry,
            capabilityScope: .agent,
            capabilityContext: context
        )

        if needsLiveData, !agentResult.usedWebSearch {
            print("⚠️ Live-data query — web search not used, retrying with forced search")
            agentResult = try await claudeAPI.sendVisionAgentTurn(
                images: labeledImages,
                systemPrompt: systemPrompt + "\n\n" + PinkyLiveDataQuery.liveDataSystemPromptAppendix,
                conversationHistory: conversationHistory,
                userPrompt: PinkyLiveDataQuery.forcedSearchUserPrompt(for: transcript),
                model: model,
                includeWebSearch: true,
                capabilityRegistry: capabilityRegistry,
                capabilityScope: .agent,
                capabilityContext: context
            )
        }

        if pinnedProcedureSession == nil {
            skillManager.pinReferenceSkill(name: nil)
        }

        return AgentTurnDelivery(
            result: agentResult,
            cursorScreenCapture: cursorScreenCapture,
            procedureRetrieval: resolved.retrieval,
            screenStepIndex: resolved.screenStepIndex
        )
    }

    func sourceDocumentsToPresent(for query: String) -> [SkillSourceDocument] {
        skillManager.sourceDocuments(for: query)
    }

    func runGuideStepTurn(
        session: CompanionActiveSession,
        model: String,
        capabilityContext: CompanionCapabilityContext
    ) async throws -> AgentTurnDelivery {
        let cursorScreenCapture = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
        let systemPrompt = CompanionAgentPrompt.guideStepSystemPrompt(
            sessionAppendix: session.stepAppendix()
        )
        let userPrompt = CompanionAgentPrompt.guideStepUserPrompt(for: session)
        let labeledImages = labeledImages(from: cursorScreenCapture)
        var context = capabilityContext
        context.screenCapture = cursorScreenCapture

        print(
            "🎬 Session guide step: \(session.plan.title) " +
            "step \(session.currentIndex + 1)/\(session.plan.steps.count)"
        )

        let agentResult = try await claudeAPI.sendVisionAgentTurn(
            images: labeledImages,
            systemPrompt: systemPrompt,
            conversationHistory: [],
            userPrompt: userPrompt,
            model: model,
            includeWebSearch: false,
            capabilityRegistry: capabilityRegistry,
            capabilityScope: .guideStep,
            capabilityContext: context
        )

        return AgentTurnDelivery(
            result: agentResult,
            cursorScreenCapture: cursorScreenCapture,
            procedureRetrieval: nil,
            screenStepIndex: session.currentIndex
        )
    }

    private func labeledImages(from capture: CompanionScreenCapture) -> [(data: Data, label: String)] {
        let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
        return [(data: capture.imageData, label: capture.label + dimensionInfo)]
    }
}
