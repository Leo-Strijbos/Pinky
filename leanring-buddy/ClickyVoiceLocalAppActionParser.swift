//
//  ClickyVoiceLocalAppActionParser.swift
//  leanring-buddy
//
//  Deterministic local app / URL / Spotify parsing for voice commands.
//

import Foundation

enum ClickyVoiceLocalAppActionParser {

    static func parse(transcript: String) -> ClickyAppAction? {
        let candidate = ClickySpokenCommandText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        if let spotifyAction = spotifyAction(from: candidate) {
            return spotifyAction
        }
        if let webAction = webOpenAction(from: candidate) {
            return webAction
        }
        if let appAction = appOpenAction(from: candidate) {
            return appAction
        }
        if let bareAppAction = bareKnownAppOpenAction(from: candidate) {
            return bareAppAction
        }
        return nil
    }

    // MARK: - Spotify

    private static func spotifyAction(from candidate: String) -> ClickyAppAction? {
        let lowered = candidate.lowercased()

        if lowered == "spotify" || lowered == "open spotify" || lowered == "launch spotify" {
            return .openApp(appName: "spotify")
        }

        let transportPatterns: [(pattern: String, action: ClickySpotifyPlaybackControl)] = [
            (#"(?i)^(?:spotify\s+)?(?:pause|stop)(?:\s+spotify)?$"#, .pause),
            (#"(?i)^(?:spotify\s+)?(?:next|skip)(?:\s+(?:song|track))?(?:\s+spotify)?$"#, .next),
            (#"(?i)^(?:spotify\s+)?(?:previous|prev|back)(?:\s+(?:song|track))?(?:\s+spotify)?$"#, .previous),
            (#"(?i)^(?:spotify\s+)?(?:play\s*pause|toggle)(?:\s+spotify)?$"#, .playPause),
            (#"(?i)^(?:spotify\s+)?(?:resume|continue)(?:\s+spotify)?$"#, .play),
        ]

        for entry in transportPatterns {
            if matchesWholeString(candidate, pattern: entry.pattern) {
                return .spotifyPlaybackControl(entry.action)
            }
        }

        let openAndPlayPattern =
            #"(?i)^(?:open|launch|start)\s+(?:up\s+)?spotify\s+and\s+(?:play|start)\s+(.+)$"#
        if let query = captureGroup(candidate, pattern: openAndPlayPattern, group: 1),
           !query.isEmpty {
            return .spotifySearchAndPlay(query: query)
        }

        let playPatterns = [
            #"(?i)^(?:play|start)\s+(.+?)(?:\s+on\s+spotify|\s+in\s+spotify)?$"#,
            #"(?i)^spotify\s+(?:play|start)\s+(.+)$"#,
        ]

        for pattern in playPatterns {
            if let query = captureGroup(candidate, pattern: pattern, group: 1),
               !query.isEmpty {
                return .spotifySearchAndPlay(query: query)
            }
        }

        return nil
    }

    // MARK: - Web

    private static func webOpenAction(from candidate: String) -> ClickyAppAction? {
        let browserPatterns: [(pattern: String, browserGroup: Int, targetGroup: Int)] = [
            (
                #"(?i)^(?:open|launch|start|switch\s+to)\s+(?:the\s+)?(?:google\s+chrome|safari|chrome|arc|firefox)\s*(?:,|\band\b|\bthen\b)?\s*(?:go\s+to|visit|browse\s+to|navigate\s+to|pull\s+up|show|open)\s+(?:the\s+)?(.+?)(?:\s+for\s+me)?$"#,
                1,
                2
            ),
            (
                #"(?i)^(?:go\s+to|visit|browse\s+to|navigate\s+to|pull\s+up|show|open)\s+(?:the\s+)?(.+?)(?:\s+(?:website|web\s+site|webpage|web\s+page|url|site))?\s+(?:in|on|using|with)\s+(?:the\s+)?(?:google\s+chrome|safari|chrome|arc|firefox)(?:\s+for\s+me)?$"#,
                2,
                1
            ),
        ]

        for entry in browserPatterns {
            if let browserRaw = captureGroup(candidate, pattern: entry.pattern, group: entry.browserGroup),
               let targetRaw = captureGroup(candidate, pattern: entry.pattern, group: entry.targetGroup),
               let browser = ClickyURLActionParser.normalizedBrowser(from: browserRaw),
               let url = ClickyURLActionParser.normalizedURL(from: targetRaw) {
                return .openURL(url: url, browser: browser, newTab: true)
            }
        }

        let urlPatterns = [
            #"(?i)^(?:open|go\s+to|visit|browse\s+to|navigate\s+to|pull\s+up|show)\s+(?:the\s+)?(.+?)(?:\s+(?:website|web\s+site|webpage|web\s+page|url|site))?(?:\s+for\s+me)?$"#,
            #"(?i)^(?:the\s+)?(.+?)\s+(?:website|web\s+site|webpage|web\s+page|url|site)$"#,
        ]

        for pattern in urlPatterns {
            if let targetRaw = captureGroup(candidate, pattern: pattern, group: 1),
               let parsed = ClickyURLActionParser.parseURLAndBrowser(from: targetRaw) {
                return .openURL(url: parsed.url, browser: parsed.browser, newTab: true)
            }
            if let targetRaw = captureGroup(candidate, pattern: pattern, group: 1),
               let url = ClickyURLActionParser.normalizedURL(from: targetRaw) {
                return .openURL(url: url, browser: nil, newTab: true)
            }
        }

        return nil
    }

    // MARK: - Apps

    private static func appOpenAction(from candidate: String) -> ClickyAppAction? {
        let pattern =
            #"(?i)^(?:open|launch|start|switch\s+to)\s+(?:up\s+)?(.+?)(?:\s+for\s+me)?$"#
        guard let targetRaw = captureGroup(candidate, pattern: pattern, group: 1) else {
            return nil
        }

        let target = targetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        if ClickyURLActionParser.isLikelyTabOrURLPayload(target) {
            return nil
        }

        if let parsed = ClickyURLActionParser.parseURLAndBrowser(from: target) {
            return .openURL(url: parsed.url, browser: parsed.browser, newTab: true)
        }

        let normalizedApp = ClickyKnownApplication.normalizedName(from: target)
        if ClickyKnownApplication.isBrowser(normalizedApp),
           let url = ClickyURLActionParser.normalizedURL(from: stripBrowserPrefix(from: target)) {
            return .openURL(url: url, browser: normalizedApp, newTab: true)
        }

        return .openApp(appName: normalizedApp)
    }

    private static func bareKnownAppOpenAction(from candidate: String) -> ClickyAppAction? {
        let normalized = ClickyKnownApplication.normalizedName(from: candidate)
        guard bareKnownAppNames.contains(normalized) else { return nil }
        return .openApp(appName: normalized)
    }

    private static let bareKnownAppNames: Set<String> = [
        "spotify", "safari", "chrome", "arc", "firefox", "finder", "terminal",
        "xcode", "slack", "discord", "zoom", "notes", "mail", "messages",
        "calendar", "music", "photos", "maps", "reminders", "preview",
    ]

    // MARK: - Regex helpers

    private static func matchesWholeString(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return false }
        return match.range.location == 0 && match.range.length == range.length
    }

    private static func captureGroup(_ text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let groupRange = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[groupRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripBrowserPrefix(from target: String) -> String {
        let lowered = target.lowercased()
        for browser in ["google chrome", "safari", "chrome", "arc", "firefox"] {
            let prefixes = ["\(browser) ", "the \(browser) "]
            for prefix in prefixes where lowered.hasPrefix(prefix) {
                return String(target.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return target
    }
}
