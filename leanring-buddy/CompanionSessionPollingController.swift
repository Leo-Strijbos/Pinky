//
//  CompanionSessionPollingController.swift
//  leanring-buddy
//
//  Background polling for step completion while a walkthrough is active.
//

import Foundation

@MainActor
final class CompanionSessionPollingController {
    private let completionMonitor: CompanionSessionCompletionMonitor
    private var pollingTask: Task<Void, Never>?

    private static let pollingIntervalSeconds: TimeInterval = 1.5

    init(completionMonitor: CompanionSessionCompletionMonitor) {
        self.completionMonitor = completionMonitor
    }

    func startPolling(
        sessionManager: CompanionSessionManager,
        workflowManager: SkillManager,
        shouldSkipAdvance: @escaping @MainActor () -> Bool = { false },
        onOutcome: @escaping @MainActor (CompanionSessionOutcome) -> Void
    ) {
        stopPolling()

        pollingTask = Task {
            await runPollCycle(
                sessionManager: sessionManager,
                workflowManager: workflowManager,
                shouldSkipAdvance: shouldSkipAdvance,
                onOutcome: onOutcome
            )

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollingIntervalSeconds))
                guard !Task.isCancelled else { return }

                await runPollCycle(
                    sessionManager: sessionManager,
                    workflowManager: workflowManager,
                    shouldSkipAdvance: shouldSkipAdvance,
                    onOutcome: onOutcome
                )
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func runPollCycle(
        sessionManager: CompanionSessionManager,
        workflowManager: SkillManager,
        shouldSkipAdvance: @escaping @MainActor () -> Bool,
        onOutcome: @escaping @MainActor (CompanionSessionOutcome) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        guard sessionManager.activeSession != nil else { return }
        guard !shouldSkipAdvance() else { return }

        guard let pending = await sessionManager.checkForAutoAdvance(
            workflowManager: workflowManager,
            completionMonitor: completionMonitor,
            context: .backgroundPoll
        ) else {
            return
        }

        guard !Task.isCancelled else { return }
        guard !shouldSkipAdvance() else {
            print("🎬 Walkthrough auto-advance deferred — voice interaction in progress")
            return
        }

        guard let outcome = sessionManager.confirmAutoAdvance(pending: pending) else {
            return
        }

        onOutcome(outcome)
    }
}
