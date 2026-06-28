//
//  CompanionSessionPromptFormatter.swift
//  leanring-buddy
//
//  Formats spoken session prompts based on policy.
//

import Foundation

enum CompanionSessionPromptFormatter {

    static func advanceHint(for session: CompanionActiveSession) -> String? {
        switch session.policy.promptStyle {
        case .minimal:
            return nil
        case .stepOnce:
            return session.hasShownAdvanceHint ? nil : defaultAdvanceHint(for: session)
        }
    }

    static func sessionIntro(for session: CompanionActiveSession) -> String? {
        switch session.plan.source {
        case .storedProcedure:
            return "starting \(session.plan.title)."
        case .agentGenerated:
            return "here's how to \(session.plan.title.lowercased())."
        }
    }

    static func exitMessage(for reason: CompanionSessionExitReason) -> String {
        switch reason {
        case .cancel:
            return "okay, stopping the walkthrough."
        case .userDone:
            return "got it, I'll step back. shout if you need me again."
        case .skipRemaining:
            return "no problem, you're good from here."
        }
    }

    private static func defaultAdvanceHint(for session: CompanionActiveSession) -> String {
        switch session.policy.advanceMode {
        case .manual:
            return "say next when you're ready for the following step."
        case .hybrid:
            return "say next anytime, or I'll move on when this step looks done."
        }
    }
}

enum CompanionSessionExitReason: Equatable {
    case cancel
    case userDone
    case skipRemaining
}
