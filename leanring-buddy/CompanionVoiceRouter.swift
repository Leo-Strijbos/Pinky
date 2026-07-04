//
//  CompanionVoiceRouter.swift
//  leanring-buddy
//
//  Deterministic voice routing: ordered handlers, agent turn as fallback.
//

import Foundation

enum CompanionVoiceRoute: String {
    case quickLocal
    case intro
    case appAction
    case agent
}

struct CompanionVoiceRouteDecision: Equatable {
    let route: CompanionVoiceRoute
    let reason: String
    let confidence: Double
    let appAction: PinkyAppAction?
    let cannedResponse: String?
}

struct CompanionVoiceRouteContext {
    let uploadedDocumentCount: Int
    let workflowScreenCount: Int
}

enum CompanionVoiceRouter {

    /// Runs registered handlers in priority order. First match wins; otherwise agent.
    static func resolve(
        transcript: String,
        context: CompanionVoiceRouteContext = CompanionVoiceRouteContext(
            uploadedDocumentCount: 0,
            workflowScreenCount: 0
        )
    ) -> CompanionVoiceRouteDecision {
        _ = context

        if let canned = PinkyVoiceQuickLocalResponses.match(transcript: transcript) {
            return CompanionVoiceRouteDecision(
                route: .quickLocal,
                reason: "quick-local",
                confidence: 1.0,
                appAction: nil,
                cannedResponse: canned
            )
        }

        if let appAction = PinkyVoiceLocalAppActionParser.parse(transcript: transcript) {
            return CompanionVoiceRouteDecision(
                route: .appAction,
                reason: appActionReason(appAction),
                confidence: 0.95,
                appAction: appAction,
                cannedResponse: nil
            )
        }

        if PinkyVoiceIntroPhrases.matches(transcript: transcript) {
            return CompanionVoiceRouteDecision(
                route: .intro,
                reason: "intro-meta",
                confidence: 0.9,
                appAction: nil,
                cannedResponse: nil
            )
        }

        return CompanionVoiceRouteDecision(
            route: .agent,
            reason: "default-agent",
            confidence: 0.5,
            appAction: nil,
            cannedResponse: nil
        )
    }

    private static func appActionReason(_ action: PinkyAppAction) -> String {
        switch action {
        case .openApp(let appName):
            return "app-action.open-app.\(appName)"
        case .openURL(let url, let browser, _):
            let browserLabel = browser ?? "default"
            return "app-action.open-url.\(browserLabel).\(url.host ?? "url")"
        case .spotifySearchAndPlay:
            return "app-action.spotify-play"
        case .spotifyPlaybackControl(let control):
            return "app-action.spotify.\(control)"
        }
    }
}
