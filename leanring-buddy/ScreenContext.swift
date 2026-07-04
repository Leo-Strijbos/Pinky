//
//  ScreenContext.swift
//  leanring-buddy
//
//  Screen context capture and matching for walkthrough playback.
//

import AppKit
import Foundation

struct ScreenContext: Equatable {
    let app: String
    let url: String?
    let windowTitle: String?
}

enum ScreenContextMatcher {
    static func matches(_ pattern: String?, value: String?) -> Bool {
        guard let pattern, !pattern.isEmpty, let value, !value.isEmpty else {
            return false
        }

        let normalizedPattern = pattern.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedPattern.contains("*") {
            let escaped = NSRegularExpression.escapedPattern(for: normalizedPattern)
                .replacingOccurrences(of: "\\*", with: ".*")
            guard let regex = try? NSRegularExpression(pattern: "^\(escaped)$", options: .caseInsensitive) else {
                return false
            }
            let range = NSRange(normalizedValue.startIndex..<normalizedValue.endIndex, in: normalizedValue)
            return regex.firstMatch(in: normalizedValue, range: range) != nil
        }

        return normalizedValue.contains(normalizedPattern)
    }

    static func urlPattern(from rawURL: String?) -> String? {
        guard
            let rawURL,
            !rawURL.isEmpty,
            let url = URL(string: rawURL),
            let host = url.host?.lowercased()
        else {
            return nil
        }

        let pathComponents = url.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard let firstSegment = pathComponents.first else {
            return "\(host)*"
        }

        return "\(host)/\(firstSegment)*"
    }

    static func matchScore(for step: SkillPlaybackStep, context: ScreenContext) -> Double {
        var score = 0.0

        if let contextApp = step.contextApp, !contextApp.isEmpty {
            if context.app.lowercased().contains(contextApp.lowercased()) {
                score += 0.45
            } else {
                return 0
            }
        }

        if let urlPattern = step.contextURLPattern {
            if matches(urlPattern, value: context.url) {
                score += 0.35
            } else if !contextAppOrURLRequired(step) {
                score += 0.1
            } else {
                return score > 0 ? score * 0.5 : 0
            }
        }

        if let windowPattern = step.contextWindowPattern {
            if matches(windowPattern, value: context.windowTitle) {
                score += 0.2
            }
        }

        return min(score, 1.0)
    }

    static func findMatchingStepIndex(
        steps: [SkillPlaybackStep],
        context: ScreenContext,
        minimumScore: Double = 0.42
    ) -> Int? {
        let ordered = steps.sorted { $0.index < $1.index }
        var bestIndex: Int?
        var bestScore = minimumScore

        for step in ordered {
            let score = matchScore(for: step, context: context)
            if score >= bestScore {
                bestScore = score
                bestIndex = step.index
            }
        }

        return bestIndex
    }

    private static func contextAppOrURLRequired(_ step: SkillPlaybackStep) -> Bool {
        !(step.contextApp ?? "").isEmpty || !(step.contextURLPattern ?? "").isEmpty
    }
}

enum ScreenContextCapture {
    static func captureCurrentContext() -> ScreenContext {
        ScreenContext(
            app: frontmostAppName(),
            url: browserURL(forApp: frontmostAppName()),
            windowTitle: frontmostWindowTitle()
        )
    }

    private static func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
    }

    private static func frontmostWindowTitle() -> String? {
        let result = PinkyAppleScriptRunner.run("""
        tell application "System Events"
            if not (exists (first process whose frontmost is true)) then return ""
            tell (first process whose frontmost is true)
                if (count of windows) = 0 then return ""
                return name of front window
            end tell
        end tell
        """)
        let title = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func browserURL(forApp appName: String) -> String? {
        let lowered = appName.lowercased()
        let script: String? = switch lowered {
        case "google chrome", "chrome":
            #"tell application "Google Chrome" to get URL of active tab of front window"#
        case "safari":
            #"tell application "Safari" to get URL of current tab of front window"#
        case "arc":
            #"tell application "Arc" to get URL of active tab of front window"#
        case "firefox":
            #"tell application "Firefox" to get URL of active tab of front window"#
        default:
            nil
        }

        guard let script else { return nil }
        let result = PinkyAppleScriptRunner.run(script)
        let url = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }
}
