//
//  CompanionSessionManager.swift
//  leanring-buddy
//
//  Owns active sessions and routes multi-step voice input.
//

import Foundation

@MainActor
final class CompanionSessionManager {
    private(set) var activeSession: CompanionActiveSession?
    private var isAdvanceInProgress = false

    /// Consecutive auto-advances before switching to shadow coaching.
    private static let shadowModeAutoAdvanceThreshold = 2
    private static let stuckNudgeDelaySeconds: TimeInterval = 15

    #if DEBUG
    func debugSetActiveSession(_ session: CompanionActiveSession?) {
        activeSession = session
    }
    #endif

    func process(
        transcript: String,
        workflowManager: SkillManager,
        completionMonitor: CompanionSessionCompletionMonitor,
        routingContext: CompanionWalkthroughRoutingContext = .empty
    ) async -> CompanionSessionOutcome? {
        if let session = activeSession {
            let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmedTranscript.isEmpty {
                if let userOutcome = processActiveSession(
                    transcript: transcript,
                    session: session
                ) {
                    return userOutcome
                }
            }

            if let autoOutcome = await tryAutoAdvance(
                workflowManager: workflowManager,
                completionMonitor: completionMonitor,
                context: trimmedTranscript.isEmpty ? .backgroundPoll : .userTurn
            ) {
                return autoOutcome
            }

            if trimmedTranscript.isEmpty,
               let stuckOutcome = checkStuckAndNudge(session: session) {
                return stuckOutcome
            }

            return nil
        }

        if let compoundSteps = CompanionSessionPlanBuilder.compoundSteps(from: transcript) {
            return .runCompoundSteps(compoundSteps)
        }

        guard PinkyProcedureQuery.shouldStartWalkthroughPlanning(
            transcript: transcript,
            context: routingContext
        ) else {
            return nil
        }

        if let storedPlan = CompanionSessionPlanBuilder.storedProcedurePlan(
            transcript: transcript,
            skillManager: workflowManager
        ) {
            return activatePlan(storedPlan)
        }

        return .needsPlan(transcript: transcript)
    }

    func activatePlan(_ plan: CompanionSessionPlan) -> CompanionSessionOutcome {
        var session = CompanionActiveSession(
            plan: plan,
            currentIndex: max(0, min(plan.startIndex, plan.steps.count - 1)),
            awaitingAdvance: false,
            stepContextSnapshot: nil,
            stepReadyAt: nil,
            hasShownAdvanceHint: false
        )
        session = prepareForCurrentStep(session)

        let (skippedSession, skippedCount) = CompanionSessionLookahead.skipAheadIfAlreadyComplete(session)
        session = skippedSession

        activeSession = session
        print("🎬 Session: source=\(plan.source.rawValue) title=\"\(plan.title)\" steps=\(plan.steps.count)")

        var introParts = [CompanionSessionPromptFormatter.sessionIntro(for: session)]
        if let bridge = CompanionSessionLookahead.skipBridgePrefix(skippedCount: skippedCount) {
            introParts.append(bridge)
        }
        let intro = introParts.compactMap { $0 }.joined(separator: " ")

        return presentCurrentStep(prefix: intro.isEmpty ? nil : intro)
    }

    func clearSession() {
        activeSession = nil
    }

    func endWalkthrough(reason: CompanionSessionExitReason = .userDone) -> CompanionSessionOutcome {
        activeSession = nil
        return .ended(spoken: CompanionSessionPromptFormatter.exitMessage(for: reason))
    }

    func checkForAutoAdvance(
        workflowManager: SkillManager,
        completionMonitor: CompanionSessionCompletionMonitor,
        context: CompanionCompletionCheckContext
    ) async -> (session: CompanionActiveSession, result: CompanionStepCompletionResult)? {
        guard let session = activeSession, session.awaitingAdvance else { return nil }
        guard session.policy.advanceMode != .manual else { return nil }

        guard let result = await completionMonitor.checkCompletion(
            session: session,
            workflowManager: workflowManager,
            context: context
        ), result.isComplete else {
            return nil
        }

        return (session, result)
    }

    func confirmAutoAdvance(
        pending: (session: CompanionActiveSession, result: CompanionStepCompletionResult)
    ) -> CompanionSessionOutcome? {
        guard !isAdvanceInProgress else { return nil }
        guard activeSession?.currentIndex == pending.session.currentIndex,
              activeSession?.awaitingAdvance == true else {
            return nil
        }

        print("🎬 Session auto-advance: \(pending.result.reason)")
        return attemptMoveToNextStep(
            from: pending.session,
            wasAutomatic: true,
            transition: pending.result.transitionPhrase
        )
    }

    func tryAutoAdvance(
        workflowManager: SkillManager,
        completionMonitor: CompanionSessionCompletionMonitor,
        context: CompanionCompletionCheckContext
    ) async -> CompanionSessionOutcome? {
        guard !isAdvanceInProgress else { return nil }

        guard let pending = await checkForAutoAdvance(
            workflowManager: workflowManager,
            completionMonitor: completionMonitor,
            context: context
        ) else {
            return nil
        }

        return confirmAutoAdvance(pending: pending)
    }

    func presentCurrentStep(prefix: String? = nil) -> CompanionSessionOutcome {
        guard let session = activeSession else {
            return .ended(spoken: "that walkthrough is already complete.")
        }

        guard session.currentStep != nil else {
            activeSession = nil
            return .ended(spoken: "that walkthrough is already complete.")
        }

        switch session.currentStep {
        case .some(.guide(let guideStep)):
            if guideStep.pointing == .none {
                return speakCurrentGuideStep(session: session, prefix: prefix)
            }
            return .executeGuideStep(session)

        case .some(.appAction):
            activeSession = nil
            return .ended(spoken: "that walkthrough step can't be presented yet.")

        case .none:
            activeSession = nil
            return .ended(spoken: "that walkthrough is already complete.")
        }
    }

    private func processActiveSession(
        transcript: String,
        session: CompanionActiveSession
    ) -> CompanionSessionOutcome? {
        if PinkyVoiceSessionPhrases.isCancel(transcript) {
            return endWalkthrough(reason: .cancel)
        }

        if PinkyVoiceSessionPhrases.isUserDone(transcript) {
            let remainder = PinkyVoiceSessionPhrases.commandAfterWalkthroughExit(in: transcript)
            if remainder != transcript, remainder.count >= 4 {
                activeSession = nil
                return .exitAndContinue(transcript: remainder)
            }
            return endWalkthrough(reason: .userDone)
        }

        if PinkyVoiceSessionPhrases.isSkipRemaining(transcript) {
            let remainder = PinkyVoiceSessionPhrases.commandAfterWalkthroughExit(in: transcript)
            if remainder != transcript, remainder.count >= 4 {
                activeSession = nil
                return .exitAndContinue(transcript: remainder)
            }
            return endWalkthrough(reason: .skipRemaining)
        }

        if PinkyVoiceSessionPhrases.isRestart(transcript) {
            var restarted = session
            restarted.currentIndex = 0
            restarted.awaitingAdvance = false
            restarted.hasShownAdvanceHint = false
            restarted.coachingMode = .leading
            restarted.consecutiveAutoAdvances = 0
            restarted.showSubsteps = false
            restarted.stepReadyAt = nil
            restarted.lastProgressAt = nil
            restarted.stuckNudgeShown = false
            activeSession = prepareForCurrentStep(restarted)
            return presentCurrentStep(prefix: "starting over.")
        }

        guard PinkyVoiceSessionContinuity.continuesWalkthrough(transcript, session: session) else {
            activeSession = nil
            print("🎬 Session: ending walkthrough — new request")
            return .exitAndContinue(transcript: transcript)
        }

        if PinkyVoiceSessionPhrases.isAdvance(transcript)
            || PinkyVoiceSessionContinuity.isStepAcknowledgment(transcript, session: session) {
            if let outcome = attemptMoveToNextStep(from: session, wasAutomatic: false, transition: nil) {
                return outcome
            }
            return .agentTurn(transcript: transcript, session: session)
        }

        if session.awaitingAdvance, PinkyVoiceSessionPhrases.isLikelyStepQuestion(transcript) {
            return .agentTurn(transcript: transcript, session: session)
        }

        if session.awaitingAdvance {
            return .agentTurn(transcript: transcript, session: session)
        }

        return nil
    }

    private func attemptMoveToNextStep(
        from session: CompanionActiveSession,
        wasAutomatic: Bool,
        transition: String?
    ) -> CompanionSessionOutcome? {
        guard !isAdvanceInProgress else {
            print("🎬 Session: advance skipped — already in progress")
            return nil
        }

        isAdvanceInProgress = true
        defer { isAdvanceInProgress = false }
        return moveToNextStep(from: session, wasAutomatic: wasAutomatic, transition: transition)
    }

    private func moveToNextStep(
        from session: CompanionActiveSession,
        wasAutomatic: Bool,
        transition: String?
    ) -> CompanionSessionOutcome {
        var updated = session
        updated.currentIndex += 1
        updated.awaitingAdvance = false
        updated.stepReadyAt = nil
        updated.showSubsteps = false
        updated.stuckNudgeShown = false

        if wasAutomatic {
            updated.consecutiveAutoAdvances += 1
            if updated.consecutiveAutoAdvances >= Self.shadowModeAutoAdvanceThreshold {
                updated.coachingMode = .shadowing
            }
            updated.lastProgressAt = Date()
        } else {
            updated.consecutiveAutoAdvances = 0
            updated.coachingMode = .leading
        }

        if updated.isComplete {
            activeSession = nil
            return .ended(spoken: "that's all the steps for \(session.plan.title).")
        }

        let (skippedSession, skippedCount) = CompanionSessionLookahead.skipAheadIfAlreadyComplete(updated)
        updated = skippedSession
        updated = prepareForCurrentStep(updated)

        if wasAutomatic, updated.coachingMode == .shadowing {
            updated = prepareAwaitingAdvance(updated)
            activeSession = updated
            print("🎬 Session shadow advance to step \(updated.currentIndex + 1)")
            return .autoAdvanced(transition: transition, session: updated)
        }

        activeSession = updated
        var prefixParts = [transition, CompanionSessionLookahead.skipBridgePrefix(skippedCount: skippedCount)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let prefix = prefixParts.isEmpty ? nil : prefixParts.joined(separator: " ")
        return presentCurrentStep(prefix: prefix)
    }

    private func speakCurrentGuideStep(
        session: CompanionActiveSession,
        prefix: String?
    ) -> CompanionSessionOutcome {
        var updated = prepareAwaitingAdvance(session)

        var spoken = "step \(updated.currentIndex + 1) of \(updated.plan.steps.count): \(updated.currentSpokenInstruction())"
        if let substepDetail = updated.spokenSubstepDetail() {
            spoken += " \(substepDetail)"
        }
        if let prefix, !prefix.isEmpty {
            spoken = "\(prefix) \(spoken)"
        }
        if let hint = CompanionSessionPromptFormatter.advanceHint(for: updated) {
            spoken += " \(hint)"
        }

        activeSession = updated
        return .speak(spoken, session: updated)
    }

    private func prepareForCurrentStep(_ session: CompanionActiveSession) -> CompanionActiveSession {
        var updated = session
        updated.stepContextSnapshot = ScreenContextCapture.captureCurrentContext()
        updated.awaitingAdvance = false
        updated.stepReadyAt = nil
        updated.showSubsteps = false
        updated.stuckNudgeShown = false
        updated.lastProgressAt = Date()
        return updated
    }

    private func prepareAwaitingAdvance(_ session: CompanionActiveSession) -> CompanionActiveSession {
        var updated = session
        updated.awaitingAdvance = true
        updated.stepReadyAt = Date()
        updated.stepContextSnapshot = ScreenContextCapture.captureCurrentContext()
        updated.lastProgressAt = Date()
        if CompanionSessionPromptFormatter.advanceHint(for: updated) != nil {
            updated.hasShownAdvanceHint = true
        }
        return updated
    }

    private func checkStuckAndNudge(session: CompanionActiveSession) -> CompanionSessionOutcome? {
        guard session.awaitingAdvance else { return nil }

        let reference = session.lastProgressAt ?? session.stepReadyAt ?? Date()
        guard Date().timeIntervalSince(reference) >= Self.stuckNudgeDelaySeconds else { return nil }
        guard !session.stuckNudgeShown else { return nil }

        var updated = session
        updated.stuckNudgeShown = true

        if updated.coachingMode == .shadowing {
            activeSession = updated
            if updated.currentGuideStep?.pointing == .ifOnScreen {
                return .executeGuideStep(updated)
            }
            return speakCurrentGuideStep(session: updated, prefix: "need a hand?")
        }

        if let substeps = updated.currentGuideStep?.substeps, substeps.count > 1, !updated.showSubsteps {
            updated.showSubsteps = true
            activeSession = updated
            return speakCurrentGuideStep(session: updated, prefix: "here's a bit more detail.")
        }

        activeSession = updated
        if updated.currentGuideStep?.pointing == .ifOnScreen {
            return .executeGuideStep(updated)
        }
        return speakCurrentGuideStep(session: updated, prefix: "still there?")
    }

    #if DEBUG
    func debugMoveToNextStep(
        from session: CompanionActiveSession,
        wasAutomatic: Bool,
        transition: String? = nil
    ) -> CompanionSessionOutcome {
        moveToNextStep(from: session, wasAutomatic: wasAutomatic, transition: transition)
    }
    #endif

    func markGuideStepPresented() {
        guard var session = activeSession else { return }
        session = prepareAwaitingAdvance(session)
        activeSession = session
    }
}
