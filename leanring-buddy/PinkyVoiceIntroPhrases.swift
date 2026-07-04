//
//  PinkyVoiceIntroPhrases.swift
//  leanring-buddy
//
//  Detects meta / conversational intros that still use the lightweight Haiku path.
//

import Foundation

enum PinkyVoiceIntroPhrases {

    static func matches(transcript: String) -> Bool {
        let candidate = PinkySpokenCommandText.normalizedSpokenCommandText(
            PinkySpokenCommandText.normalizedCommandCandidate(from: transcript)
        )
        guard !candidate.isEmpty else { return false }

        if PinkyVoiceQuickLocalResponses.match(transcript: transcript) != nil {
            return false
        }

        let introPhrases = [
            "who are you",
            "what are you",
            "tell me about yourself",
            "introduce yourself",
            "how do you work",
            "what is pinky",
            "what's pinky",
            "whats pinky",
        ]

        if introPhrases.contains(where: { candidate.contains($0) }) {
            return true
        }

        return candidate.hasPrefix("what is ") || candidate.hasPrefix("what's ")
            ? candidate.contains("pinky") || candidate.contains("you")
            : false
    }
}
