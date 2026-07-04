//
//  PinkyPanelDisplayText.swift
//  leanring-buddy
//
//  Formats spoken-response text for the notch panel — proper grammar on
//  screen while TTS can stay casual in the source string.
//

import Foundation

enum PinkyPanelDisplayText {
    static let maxVisibleLines = 3
    static let charactersPerLine = 38

    /// Applies sentence case and fixes common pronoun contractions.
    static func formatForDisplay(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var result = ""
        var capitalizeNext = true

        for character in trimmed {
            if capitalizeNext, character.isLetter {
                result.append(String(character).uppercased())
                capitalizeNext = false
            } else {
                result.append(character)
                if ".!?".contains(character) {
                    capitalizeNext = true
                } else if character.isLetter || character.isNumber {
                    capitalizeNext = false
                }
            }
        }

        return fixFirstPersonPronouns(in: result)
    }

    /// Returns only the trailing lines that fit in the panel window.
    static func visibleWindow(
        from raw: String,
        maxLines: Int = maxVisibleLines,
        charactersPerLine: Int = charactersPerLine
    ) -> String {
        let formatted = formatForDisplay(raw)
        guard !formatted.isEmpty else { return formatted }

        let lines = wrappedLines(for: formatted, charactersPerLine: charactersPerLine)
        if lines.count <= maxLines {
            return lines.joined(separator: "\n")
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private static func wrappedLines(for text: String, charactersPerLine: Int) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !words.isEmpty else { return [] }

        var lines: [String] = []
        var current = ""

        for word in words {
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count > charactersPerLine, !current.isEmpty {
                lines.append(current)
                current = word
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }

        return lines
    }

    private static func fixFirstPersonPronouns(in text: String) -> String {
        let replacements: [(String, String)] = [
            (#"(?i)\bi'm\b"#, "I'm"),
            (#"(?i)\bi've\b"#, "I've"),
            (#"(?i)\bi'll\b"#, "I'll"),
            (#"(?i)\bi'd\b"#, "I'd"),
            (#"(?i)\bi\b"#, "I"),
        ]

        var result = text
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}
