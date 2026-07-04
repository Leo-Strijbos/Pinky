//
//  PinkyVoiceSessionContinuity.swift
//  leanring-buddy
//
//  Decides whether speech during a walkthrough continues the current step
//  or should end the walkthrough and be handled as a normal request.
//

import Foundation

enum PinkyVoiceSessionContinuity {

    /// Returns true when the user is still working on the current walkthrough step.
    ///
    /// While a walkthrough is active, the default is to stay in it unless the user
    /// is clearly starting a different task.
    static func continuesWalkthrough(_ transcript: String, session: CompanionActiveSession) -> Bool {
        if PinkyVoiceSessionPhrases.isRestart(transcript) {
            return true
        }

        if PinkyVoiceSessionPhrases.isAdvance(transcript) {
            return true
        }

        if isStepAcknowledgment(transcript, session: session) {
            return true
        }

        if isClearlyNewRequest(transcript, session: session) {
            return false
        }

        if session.awaitingAdvance {
            return true
        }

        return sharesStepContext(transcript, session: session)
    }

    /// User reporting they completed the current step action.
    static func isStepAcknowledgment(_ transcript: String, session: CompanionActiveSession) -> Bool {
        let candidate = continuityCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let markers = [
            "ok ", "okay ", "done", "got it", "i clicked", "i've clicked", "ive clicked",
            "i have clicked", "i opened", "i've opened", "ive opened", "i selected",
            "i've selected", "ive selected", "that's done", "thats done", "did that",
            "finished that", "i did that",
        ]

        guard markers.contains(where: { candidate.contains($0) }) else { return false }
        return sharesStepContext(transcript, session: session) || candidate.count <= 48
    }

    private static func isClearlyNewRequest(
        _ transcript: String,
        session: CompanionActiveSession
    ) -> Bool {
        if isObviouslyOffTopic(transcript) {
            return true
        }

        if PinkyVoiceLocalAppActionParser.parse(transcript: transcript) != nil {
            return true
        }

        if PinkyProcedureQuery.isStepByStepIntent(transcript) {
            return !sharesStepContext(transcript, session: session)
        }

        return false
    }

    private static func sharesStepContext(_ transcript: String, session: CompanionActiveSession) -> Bool {
        let queryTokens = meaningfulTokens(from: transcript)
        guard !queryTokens.isEmpty else { return false }

        var stepTokens = meaningfulTokens(from: session.currentSpokenInstruction())
        if let lookFor = session.currentGuideStep?.lookFor {
            stepTokens.formUnion(meaningfulTokens(from: lookFor))
        }
        stepTokens.formUnion(meaningfulTokens(from: session.plan.title))

        let overlap = queryTokens.intersection(stepTokens)
        if overlap.count >= 2 { return true }
        if let token = overlap.first, token.count >= 5 { return true }
        return false
    }

    private static func isObviouslyOffTopic(_ transcript: String) -> Bool {
        let candidate = continuityCandidate(from: transcript)
        let phrases = [
            "weather", "who are you", "what time", "play music", "open spotify",
            "tell me a joke", "what's the news", "whats the news", "send an email",
        ]
        return phrases.contains { candidate.contains($0) }
    }

    private static func meaningfulTokens(from text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "the", "to", "on", "in", "at", "for", "of", "and", "or", "then",
            "i", "me", "my", "it", "this", "that", "is", "are", "do", "did", "just",
            "now", "please", "pinky", "hey", "ok", "okay", "step", "next",
        ]

        return Set(
            normalizedCandidate(from: text)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }

    /// Full spoken text normalized for continuity — does not strip leading "okay"/"hey".
    private static func continuityCandidate(from transcript: String) -> String {
        PinkySpokenCommandText.normalizedSpokenCommandText(
            transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Prefix-stripped normalization for command-style matching elsewhere.
    private static func normalizedCandidate(from transcript: String) -> String {
        PinkySpokenCommandText.normalizedSpokenCommandText(
            PinkySpokenCommandText.normalizedCommandCandidate(from: transcript)
        )
    }
}
