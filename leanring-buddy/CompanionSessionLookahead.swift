//
//  CompanionSessionLookahead.swift
//  leanring-buddy
//
//  Skips milestones the user has already completed on screen.
//

import Foundation

enum CompanionSessionLookahead {

    static func skipAheadIfAlreadyComplete(_ session: CompanionActiveSession) -> (session: CompanionActiveSession, skippedCount: Int) {
        var updated = session
        var skipped = 0

        while updated.currentIndex < updated.plan.steps.count {
            guard let guide = updated.currentGuideStep,
                  guide.skipPolicy == .ifAlreadyComplete,
                  isSynchronouslyComplete(guide: guide, session: updated) else {
                break
            }

            updated.currentIndex += 1
            skipped += 1
        }

        return (updated, skipped)
    }

    static func isSynchronouslyComplete(
        guide: CompanionGuideStep,
        session: CompanionActiveSession
    ) -> Bool {
        switch guide.completion {
        case .manual:
            return false

        case .visionCheck:
            return false

        case .skillStep(let stepID):
            guard let target = session.plan.skillSteps?.first(where: { $0.id == stepID }) else {
                return false
            }
            let context = ScreenContextCapture.captureCurrentContext()
            return ScreenContextMatcher.matchScore(for: target, context: context) >= 0.42
        }
    }

    static func skipBridgePrefix(skippedCount: Int) -> String? {
        guard skippedCount > 0 else { return nil }
        return skippedCount == 1
            ? "looks like you're already past that step."
            : "looks like you're already partway through."
    }
}
