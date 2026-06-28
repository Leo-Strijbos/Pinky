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
    private let playbookManager: PlaybookManager
    private let capabilityRegistry: CompanionCapabilityRegistry

    init(
        claudeAPI: ClaudeAPI,
        playbookManager: PlaybookManager,
        capabilityRegistry: CompanionCapabilityRegistry = .standard
    ) {
        self.claudeAPI = claudeAPI
        self.playbookManager = playbookManager
        self.capabilityRegistry = capabilityRegistry
    }

    struct AgentTurnDelivery {
        let result: CompanionAgentTurnResult
        let cursorScreenCapture: CompanionScreenCapture
        let procedureRetrieval: PlaybookRetrieval?
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

        let procedureAppendix = ""
        let retrieval: PlaybookRetrieval? = nil
        let screenStepIndex: Int? = nil

        let knowledgeAppendix = ""
        let needsLiveData = ClickyLiveDataQuery.requiresFreshWebSearch(transcript)
        let liveDataAppendix = needsLiveData ? ClickyLiveDataQuery.liveDataSystemPromptAppendix : nil

        let systemPrompt = CompanionAgentPrompt.agentSystemPrompt(
            workflowAppendix: procedureAppendix,
            knowledgeAppendix: knowledgeAppendix,
            liveDataAppendix: liveDataAppendix
        )

        let userPrompt = needsLiveData
            ? ClickyLiveDataQuery.forcedSearchUserPrompt(for: transcript)
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
                systemPrompt: systemPrompt + "\n\n" + ClickyLiveDataQuery.liveDataSystemPromptAppendix,
                conversationHistory: conversationHistory,
                userPrompt: ClickyLiveDataQuery.forcedSearchUserPrompt(for: transcript),
                model: model,
                includeWebSearch: true,
                capabilityRegistry: capabilityRegistry,
                capabilityScope: .agent,
                capabilityContext: context
            )
        }

        if pinnedProcedureSession == nil {
            playbookManager.pinReferencePlaybook(id: nil)
        }

        return AgentTurnDelivery(
            result: agentResult,
            cursorScreenCapture: cursorScreenCapture,
            procedureRetrieval: retrieval,
            screenStepIndex: screenStepIndex
        )
    }

    func sourceDocumentsToPresent(for query: String) -> [ClickyKnowledgeSourceDocument] {
        []
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

    func runOnboardingDemoTurn(
        cursorScreenCapture: CompanionScreenCapture,
        model: String,
        capabilityContext: CompanionCapabilityContext
    ) async throws -> CompanionAgentTurnResult {
        let labeledImages = labeledImages(from: cursorScreenCapture)
        var context = capabilityContext
        context.screenCapture = cursorScreenCapture

        return try await claudeAPI.sendVisionAgentTurn(
            images: labeledImages,
            systemPrompt: CompanionAgentPrompt.onboardingDemo,
            conversationHistory: [],
            userPrompt: "look around my screen and find something interesting to point at",
            model: model,
            includeWebSearch: false,
            capabilityRegistry: capabilityRegistry,
            capabilityScope: .onboarding,
            capabilityContext: context
        )
    }

    private func labeledImages(from capture: CompanionScreenCapture) -> [(data: Data, label: String)] {
        let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
        return [(data: capture.imageData, label: capture.label + dimensionInfo)]
    }
}
