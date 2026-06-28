//
//  ClickyVoiceCompoundCommandParser.swift
//  leanring-buddy
//
//  Splits compound local commands into ordered app-action steps.
//

import Foundation

enum ClickyVoiceCompoundCommandParser {

    private static let separators = [
        " and then ",
        " then ",
        ", then ",
        ", and ",
        " and ",
    ]

    static func parse(transcript: String) -> [CompanionSessionStep]? {
        let candidate = ClickySpokenCommandText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let segments = splitSegments(from: candidate)
        guard segments.count >= 2 else { return nil }

        var steps: [CompanionSessionStep] = []
        for (index, segment) in segments.enumerated() {
            guard let action = ClickyVoiceLocalAppActionParser.parse(transcript: segment) else {
                return nil
            }
            let bridge = index == 0 ? nil : bridgePhrase(for: action)
            steps.append(.appAction(action, bridge: bridge))
        }

        return steps.isEmpty ? nil : steps
    }

    private static func splitSegments(from candidate: String) -> [String] {
        var segments = [candidate]

        for separator in separators {
            var next: [String] = []
            for piece in segments {
                next.append(contentsOf: piece.components(separatedBy: separator))
            }
            segments = next
        }

        return segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func bridgePhrase(for action: ClickyAppAction) -> String {
        switch action {
        case .openApp(let appName):
            return "now opening \(ClickyKnownApplication.displayName(for: appName))."
        case .openURL(let url, _, _):
            let host = url.host ?? "that site"
            return "now opening \(host)."
        case .spotifySearchAndPlay:
            return "now playing that on spotify."
        case .spotifyPlaybackControl:
            return "okay."
        }
    }
}
