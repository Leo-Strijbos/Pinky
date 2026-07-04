//
//  PinkyVoiceQuickLocalResponses.swift
//  leanring-buddy
//
//  Zero-LLM canned replies for common voice checks and acknowledgements.
//

import Foundation

enum PinkyVoiceQuickLocalResponses {

    static func match(transcript: String) -> String? {
        let candidate = PinkySpokenCommandText.normalizedSpokenCommandText(
            PinkySpokenCommandText.normalizedCommandCandidate(from: transcript)
        )
        guard !candidate.isEmpty else { return nil }

        let acknowledgementChecks = [
            "yes", "yeah", "yep", "no", "nope", "ok", "okay",
            "ok then", "okay then", "alright", "all right",
            "sounds good", "fair enough", "thanks", "thank you", "thank you pinky",
        ]
        if acknowledgementChecks.contains(candidate) {
            return candidate.hasPrefix("thank") ? "you're welcome." : "okay."
        }

        let hearingChecks = [
            "can you hear me", "can you hear us", "do you hear me", "do you hear us",
            "are you hearing me", "are you hearing us",
        ]
        if hearingChecks.contains(candidate) {
            return "yes, i can hear you."
        }

        let availabilityChecks = [
            "are you there", "are you still there", "are you listening",
            "are you awake", "you there", "hello", "hello there", "hi", "hey",
            "pinky",
        ]
        if availabilityChecks.contains(candidate) {
            return "i'm here."
        }

        let capabilityChecks = [
            "what can you do", "what can you do for me", "what do you do",
            "what are you able to do", "what can pinky do",
        ]
        if capabilityChecks.contains(candidate) {
            return """
            i can look at your screen, answer questions, walk you through procedures, \
            open apps and sites, and search the web when you need current info.
            """
        }

        let voiceControlChecks = [
            "test test", "testing", "testing one two three", "test one two three",
            "checking voice", "just checking voice", "mic check", "microphone check",
        ]
        if voiceControlChecks.contains(candidate) {
            return "voice is working."
        }

        return nil
    }
}
