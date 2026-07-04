//
//  PinkyURLActionParser.swift
//  leanring-buddy
//
//  Parses spoken web addresses and browser targets for app actions.
//

import Foundation

enum PinkyURLActionParser {

    static let browserNames: Set<String> = ["safari", "chrome", "arc", "firefox"]

    private static let spokenBrowsers: [(spoken: String, normalized: String)] = [
        ("google chrome", "chrome"),
        ("safari", "safari"),
        ("firefox", "firefox"),
        ("chrome", "chrome"),
        ("arc", "arc"),
    ]

    static let browserPattern =
        "(?:google\\s+chrome|safari|firefox|arc|chrome)"

    static func isBrowser(_ normalizedName: String) -> Bool {
        browserNames.contains(normalizedName)
    }

    static func normalizedBrowser(from raw: String) -> String? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        for entry in spokenBrowsers where entry.spoken == normalized {
            return entry.normalized
        }
        return isBrowser(normalized) ? normalized : nil
    }

    static func normalizedURL(from raw: String) -> URL? {
        var trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
            .replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: .regularExpression)

        trimmed = repairSpokenDomain(trimmed)

        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }

        if trimmed.lowercased().hasPrefix("www.") {
            return URL(string: "https://\(trimmed)")
        }

        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        return nil
    }

    /// ASR often drops the dot: "github com" → "github.com"
    private static func repairSpokenDomain(_ raw: String) -> String {
        let spokenTLDs = "com|org|net|io|app|dev|co|uk|de|fr|nl|ai|tv|me|us|edu|gov"
        let pattern = #"^([\w\-]+)\s+(\#(spokenTLDs))$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
            let hostRange = Range(match.range(at: 1), in: raw),
            let tldRange = Range(match.range(at: 2), in: raw)
        else {
            return raw
        }

        let host = String(raw[hostRange])
        let tld = String(raw[tldRange]).lowercased()
        return "\(host).\(tld)"
    }

    static func isLikelyURL(_ raw: String) -> Bool {
        normalizedURL(from: raw) != nil
    }

    /// Parses payloads like "github com in google chrome" or "a tab github com in chrome".
    static func parseURLAndBrowser(from raw: String) -> (url: URL, browser: String?)? {
        let stripped = stripTabPrefix(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let (target, browser) = extractBrowserSuffix(from: stripped)
        guard let url = normalizedURL(from: target) else { return nil }
        return (url, browser)
    }

    static func stripBrowserSuffix(from raw: String) -> (target: String, browser: String?) {
        extractBrowserSuffix(from: raw)
    }

    private static func extractBrowserSuffix(from raw: String) -> (target: String, browser: String?) {
        let lowered = raw.lowercased()
        for entry in spokenBrowsers {
            let marker = " in \(entry.spoken)"
            guard lowered.hasSuffix(marker) else { continue }
            let target = String(raw.dropLast(marker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (target, entry.normalized)
        }
        return (raw, nil)
    }

    private static func stripTabPrefix(from raw: String) -> String {
        let pattern = #"(?i)^(?:a\s+)?(?:new\s+)?tab(?:\s+with|\s+for|\s+to)?\s+"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
            let matchRange = Range(match.range, in: raw)
        else {
            return raw
        }
        return String(raw[matchRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isLikelyTabOrURLPayload(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        if lowered.contains(" tab ") || lowered.hasPrefix("tab ") || lowered.contains("new tab") {
            return true
        }
        for entry in spokenBrowsers where lowered.contains(" in \(entry.spoken)") {
            return true
        }
        return parseURLAndBrowser(from: raw) != nil || isLikelyURL(raw)
    }
}
