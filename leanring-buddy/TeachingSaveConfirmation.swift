//
//  TeachingSaveConfirmation.swift
//  leanring-buddy
//
//  Lightweight parsing for voice confirmation of a pending playbook draft.
//

import Foundation

enum TeachingSaveConfirmation {
    private static let affirmativePhrases = [
        "yes", "yeah", "yep", "sure", "ok", "okay", "save it", "do it", "go ahead", "please",
    ]

    private static let negativePhrases = [
        "no", "nah", "nope", "cancel", "don't", "do not", "never mind", "nevermind", "discard",
    ]

    static func isAffirmative(_ normalizedTranscript: String) -> Bool {
        let trimmed = normalizedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return affirmativePhrases.contains { trimmed == $0 || trimmed.hasPrefix("\($0) ") }
    }

    static func isNegative(_ normalizedTranscript: String) -> Bool {
        let trimmed = normalizedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return negativePhrases.contains { trimmed == $0 || trimmed.hasPrefix("\($0) ") }
    }
}
