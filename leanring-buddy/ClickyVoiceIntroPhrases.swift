//
//  ClickyVoiceIntroPhrases.swift
//  leanring-buddy
//
//  Detects meta / conversational intros that still use the lightweight Haiku path.
//

import Foundation

enum ClickyVoiceIntroPhrases {

    static func matches(transcript: String) -> Bool {
        let candidate = ClickySpokenCommandText.normalizedSpokenCommandText(
            ClickySpokenCommandText.normalizedCommandCandidate(from: transcript)
        )
        guard !candidate.isEmpty else { return false }

        if ClickyVoiceQuickLocalResponses.match(transcript: transcript) != nil {
            return false
        }

        let introPhrases = [
            "who are you",
            "what are you",
            "tell me about yourself",
            "introduce yourself",
            "how do you work",
            "what is clicky",
            "what's clicky",
            "whats clicky",
        ]

        if introPhrases.contains(where: { candidate.contains($0) }) {
            return true
        }

        return candidate.hasPrefix("what is ") || candidate.hasPrefix("what's ")
            ? candidate.contains("clicky") || candidate.contains("you")
            : false
    }
}
