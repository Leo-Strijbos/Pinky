//
//  ClickyWorkflowContextCapture.swift
//  leanring-buddy
//
//  Reads frontmost app, window title, and browser URL for workflow snapshots.
//

import AppKit
import Foundation

enum ClickyWorkflowContextCapture {

    static func captureCurrentContext() -> ClickyWorkflowScreenContext {
        let app = frontmostAppName()
        let windowTitle = frontmostWindowTitle()
        let url = browserURL(forApp: app)
        return ClickyWorkflowScreenContext(
            app: app,
            url: url,
            windowTitle: windowTitle,
            ocrTerms: [],
            visualFingerprint: nil
        )
    }

    static func signature(for context: ClickyWorkflowScreenContext, visualFingerprint: String) -> String {
        [
            context.app.lowercased(),
            context.url?.lowercased() ?? "",
            context.windowTitle?.lowercased() ?? "",
            visualFingerprint,
        ].joined(separator: "|")
    }

    private static func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
    }

    private static func frontmostWindowTitle() -> String? {
        let result = ClickyAppleScriptRunner.run("""
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
        let result = ClickyAppleScriptRunner.run(script)
        let url = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }
}
