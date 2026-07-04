//
//  PinkyVoiceSessionPhrases.swift
//  leanring-buddy
//
//  Control phrases for active multi-step walkthrough sessions.
//

import Foundation

enum PinkyVoiceSessionPhrases {

    static func isAdvance(_ transcript: String) -> Bool {
        let candidate = normalizedCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let phrases = [
            "next", "next step", "continue", "go on", "go ahead", "keep going",
            "what's next", "whats next", "what is next", "done with this step",
            "ok next", "okay next", "move on", "and then",
            "what do i do next", "what do i do now", "what should i do next",
            "and now what", "what now",
        ]
        return phrases.contains(candidate)
            || phrases.contains(where: { candidate.hasSuffix($0) })
    }

    static func isExit(_ transcript: String) -> Bool {
        isCancel(transcript) || isUserDone(transcript) || isSkipRemaining(transcript)
    }

    static func isCancel(_ transcript: String) -> Bool {
        let candidate = normalizedCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let phrases = [
            "stop", "cancel", "exit", "quit", "never mind", "nevermind",
            "stop procedure", "stop the procedure", "end procedure",
            "cancel procedure", "exit procedure", "exit tutorial",
            "stop walkthrough", "end walkthrough",
        ]
        return phrases.contains(candidate) || candidate.hasPrefix("stop ")
    }

    static func isUserDone(_ transcript: String) -> Bool {
        matchesHandoffPhrase(
            transcript,
            phrases: [
                "i've got it", "ive got it", "i got it", "that's enough", "thats enough",
                "i'm good", "im good", "all good", "that's all i needed", "thats all i needed",
                "i've got it from here", "ive got it from here",
            ]
        )
    }

    static func isSkipRemaining(_ transcript: String) -> Bool {
        matchesHandoffPhrase(
            transcript,
            phrases: [
                "skip the rest", "skip remaining", "skip ahead", "i can take it from here",
                "i'll take it from here", "ill take it from here",
            ]
        )
    }

    static func isRestart(_ transcript: String) -> Bool {
        let candidate = normalizedCandidate(from: transcript)
        let phrases = [
            "start over", "from the beginning", "restart", "begin again", "start again",
        ]
        return phrases.contains(candidate)
    }

    static func isLikelyStepQuestion(_ transcript: String) -> Bool {
        if isAdvance(transcript) || isExit(transcript) || isRestart(transcript) {
            return false
        }

        let candidate = PinkySpokenCommandText.normalizedCommandCandidate(from: transcript)
        guard candidate.count >= 8 else { return false }

        if candidate.contains("?") {
            return true
        }

        let questionStarts = [
            "how ", "what ", "where ", "why ", "can you ", "could you ",
            "which ", "when ", "help me ", "show me ", "point to ",
        ]
        return questionStarts.contains { candidate.lowercased().hasPrefix($0) }
    }

    /// After ending a walkthrough, users often say an exit phrase and a new command
    /// in one utterance. Returns the actionable tail when present.
    static func commandAfterWalkthroughExit(in transcript: String) -> String {
        let normalized = normalizedCandidate(from: transcript)
        guard !normalized.isEmpty else { return transcript }

        let exitMarkers = [
            "i've got it from here",
            "ive got it from here",
            "i got it from here",
            "i'll take it from here",
            "ill take it from here",
            "i can take it from here",
            "that's enough",
            "thats enough",
            "that's all i needed",
            "thats all i needed",
            "i'm good",
            "im good",
            "all good",
        ]

        for marker in exitMarkers {
            guard let range = normalized.range(of: marker) else { continue }
            let remainder = String(normalized[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-–—…"))
            if remainder.count >= 4 {
                return remainder
            }
        }

        return transcript
    }

    private static func normalizedCandidate(from transcript: String) -> String {
        PinkySpokenCommandText.normalizedSpokenCommandText(
            PinkySpokenCommandText.normalizedCommandCandidate(from: transcript)
        )
    }

    private static func collapsedCandidate(from transcript: String) -> String {
        normalizedCandidate(from: transcript).replacingOccurrences(of: " ", with: "")
    }

    private static func matchesHandoffPhrase(_ transcript: String, phrases: [String]) -> Bool {
        let candidate = normalizedCandidate(from: transcript)
        if phrases.contains(candidate) {
            return true
        }

        let collapsed = collapsedCandidate(from: transcript)
        return phrases.contains { phrase in
            collapsed == phrase.replacingOccurrences(of: " ", with: "")
                || candidate == phrase
        }
    }
}
