//
//  ClickySpokenCommandText.swift
//  leanring-buddy
//
//  Spoken-transcript normalization for deterministic voice routing.
//

import Foundation

enum ClickySpokenCommandText {

    /// Lowercased, diacritic-folded, punctuation-stripped, single-spaced text for matching.
    static func normalizedSpokenCommandText(_ transcript: String) -> String {
        transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Strips leading filler ("hey clicky", "please") for command parsing.
    static func normalizedCommandCandidate(from transcript: String) -> String {
        var candidate = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixPatterns = [
            #"(?i)^\s*(?:hey|ok|okay|right|so)[\s,]+"#,
            #"(?i)^\s*(?:clicky)[\s,]+"#,
            #"(?i)^\s*(?:can|could|would|will)\s+you\s+"#,
            #"(?i)^\s*please\s+"#,
        ]

        var didStripPrefix = true
        while didStripPrefix {
            didStripPrefix = false
            for pattern in prefixPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                guard let match = regex.firstMatch(in: candidate, range: range),
                      let matchRange = Range(match.range, in: candidate) else {
                    continue
                }
                candidate.removeSubrange(matchRange)
                candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                didStripPrefix = true
            }
        }

        return candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-–—…"))
    }
}
