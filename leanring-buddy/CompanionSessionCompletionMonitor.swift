//
//  CompanionSessionCompletionMonitor.swift
//  leanring-buddy
//
//  Detects when the user has completed the current guide step.
//

import Foundation

enum CompanionCompletionCheckContext {
    /// Background polling — cheap workflow matches and rate-limited vision checks.
    case backgroundPoll
    /// User spoke or finished a turn — may run vision checks too.
    case userTurn
}

struct CompanionStepCompletionResult: Equatable {
    let isComplete: Bool
    let transitionPhrase: String?
    let reason: String

    static func completed(reason: String, transition: String? = nil) -> CompanionStepCompletionResult {
        CompanionStepCompletionResult(
            isComplete: true,
            transitionPhrase: transition,
            reason: reason
        )
    }
}

@MainActor
final class CompanionSessionCompletionMonitor {
    private let claudeAPI: ClaudeAPI
    private var lastVisionCheckAt: Date?

    /// Minimum time on a step before heuristic auto-advance is allowed.
    private static let minimumStepDwellSeconds: TimeInterval = 1.5
    private static let minimumVisionCheckIntervalSeconds: TimeInterval = 12

    init(claudeAPI: ClaudeAPI) {
        self.claudeAPI = claudeAPI
    }

    func checkCompletion(
        session: CompanionActiveSession,
        workflowManager: SkillManager,
        context: CompanionCompletionCheckContext
    ) async -> CompanionStepCompletionResult? {
        guard session.awaitingAdvance,
              let guideStep = session.currentGuideStep,
              guideStep.completion != .manual,
              session.policy.advanceMode != .manual else {
            return checkContextDeltaCompletion(session: session)
        }

        guard hasMetMinimumDwell(session) else { return nil }

        if let deltaResult = checkContextDeltaCompletion(session: session) {
            return deltaResult
        }

        switch guideStep.completion {
        case .manual:
            return nil

        case .skillStep(let stepID):
            return checkSkillStep(stepID: stepID, session: session)

        case .visionCheck(let description):
            return await checkVision(
                description: description,
                session: session,
                context: context
            )
        }
    }

    private func hasMeaningfulContextChange(for session: CompanionActiveSession) -> Bool {
        guard let snapshot = session.stepContextSnapshot else { return false }
        let currentContext = ScreenContextCapture.captureCurrentContext()
        return CompanionScreenContextDelta.hasMeaningfulChange(from: snapshot, to: currentContext)
    }

    private func checkContextDeltaCompletion(
        session: CompanionActiveSession
    ) -> CompanionStepCompletionResult? {
        guard session.policy.advanceMode == .hybrid,
              hasMetMinimumDwell(session),
              let snapshot = session.stepContextSnapshot else {
            return nil
        }

        let currentContext = ScreenContextCapture.captureCurrentContext()
        guard CompanionScreenContextDelta.hasMeaningfulChange(from: snapshot, to: currentContext) else {
            return nil
        }

        switch session.currentGuideStep?.completion {
        case .manual, .none:
            return .completed(reason: "context-delta")
        case .visionCheck, .skillStep:
            return nil
        }
    }

    private func hasMetMinimumDwell(_ session: CompanionActiveSession) -> Bool {
        guard let stepReadyAt = session.stepReadyAt else { return false }
        return Date().timeIntervalSince(stepReadyAt) >= Self.minimumStepDwellSeconds
    }

    private func checkSkillStep(
        stepID: String,
        session: CompanionActiveSession
    ) -> CompanionStepCompletionResult? {
        guard
            let target = session.plan.skillSteps?.first(where: { $0.id == stepID })
        else {
            return nil
        }

        let context = ScreenContextCapture.captureCurrentContext()
        let score = ScreenContextMatcher.matchScore(for: target, context: context)
        guard score >= 0.42 else { return nil }

        return .completed(reason: "skill-step")
    }

    private func checkVision(
        description: String,
        session: CompanionActiveSession,
        context: CompanionCompletionCheckContext
    ) async -> CompanionStepCompletionResult? {
        if context == .backgroundPoll, !canRunVisionCheckNow(session: session) {
            return nil
        }

        guard let capture = try? await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG() else {
            return nil
        }

        lastVisionCheckAt = Date()

        let dimensionInfo =
            " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
        let labeledImages = [(
            data: capture.imageData,
            label: capture.label + dimensionInfo
        )]

        let systemPrompt = """
        decide whether the screenshot shows the user has completed this step.
        reply with ONLY JSON: {"complete":true|false,"confidence":0.0-1.0}
        """

        let userPrompt = "step completion check: \(description)"

        do {
            let (raw, _) = try await claudeAPI.analyzeImage(
                images: labeledImages,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: CompanionAgentPrompt.sessionPlannerModel
            )
            let parsed = try CompanionSessionCompletionParser.parse(raw)
            guard parsed.complete, parsed.confidence >= 0.75 else { return nil }

            return .completed(reason: "vision-check")
        } catch {
            print("⚠️ Session completion vision check failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func canRunVisionCheckNow(session: CompanionActiveSession) -> Bool {
        if hasMeaningfulContextChange(for: session) {
            return true
        }

        guard let lastVisionCheckAt else { return true }
        return Date().timeIntervalSince(lastVisionCheckAt) >= Self.minimumVisionCheckIntervalSeconds
    }
}

enum CompanionSessionCompletionParser {
    struct ParsedResult: Equatable {
        let complete: Bool
        let confidence: Double
    }

    private struct DecodablePayload: Decodable {
        let complete: Bool
        let confidence: Double
    }

    static func parse(_ raw: String) throws -> ParsedResult {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard
            let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            let data = String(text[start...end]).data(using: .utf8)
        else {
            throw NSError(domain: "CompanionSessionCompletionParser", code: -1)
        }

        let payload = try JSONDecoder().decode(DecodablePayload.self, from: data)
        return ParsedResult(complete: payload.complete, confidence: payload.confidence)
    }
}
