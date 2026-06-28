//
//  ClickyOpenURLActionHandler.swift
//  leanring-buddy
//
//  Opens URLs in the default browser or a named browser (new tab when possible).
//

import AppKit
import Foundation

struct ClickyOpenURLActionHandler: ClickyAppActionHandling {
    func execute(_ action: ClickyAppAction) async -> String? {
        guard case .openURL(let url, let browser, let newTab) = action else { return nil }
        return Self.openURL(url, browser: browser, newTab: newTab)
    }

    static func openURL(_ url: URL, browser: String?, newTab: Bool) -> String {
        let urlString = url.absoluteString

        if let browser, ClickyKnownApplication.isBrowser(browser) {
            if newTab, openURLInBrowserTab(urlString: urlString, browser: browser) {
                let browserName = ClickyKnownApplication.displayName(for: browser)
                print("🌐 Opened URL in new \(browserName) tab: \(urlString)")
                return "opening \(spokenSiteName(for: url)) in a new \(browserName) tab."
            }

            if openURLWithBundleIdentifier(url, browser: browser) {
                let browserName = ClickyKnownApplication.displayName(for: browser)
                print("🌐 Opened URL in \(browserName): \(urlString)")
                return "opening \(spokenSiteName(for: url)) in \(browserName)."
            }
        }

        if NSWorkspace.shared.open(url) {
            print("🌐 Opened URL: \(urlString)")
            if newTab {
                return "opening \(spokenSiteName(for: url)) in a new tab."
            }
            return "opening \(spokenSiteName(for: url))."
        }

        print("⚠️ Could not open URL: \(urlString)")
        return "i couldn't open that link."
    }

    private static func openURLWithBundleIdentifier(_ url: URL, browser: String) -> Bool {
        if let bundleIdentifier = ClickyKnownApplication.bundleIdentifiers[browser] {
            return ClickyOpenAppActionHandler.runOpenCommand(arguments: [
                "-b",
                bundleIdentifier,
                url.absoluteString,
            ])
        }

        return ClickyOpenAppActionHandler.runOpenCommand(arguments: [
            "-a",
            ClickyKnownApplication.displayName(for: browser),
            url.absoluteString,
        ])
    }

    private static func openURLInBrowserTab(urlString: String, browser: String) -> Bool {
        let escapedURL = urlString.replacingOccurrences(of: "\"", with: "\\\"")

        let script: String? = switch browser {
        case "safari":
            """
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document
                end if
                tell window 1
                    set current tab to (make new tab with properties {URL:"\(escapedURL)"})
                end tell
            end tell
            """
        case "chrome":
            """
            tell application "Google Chrome"
                activate
                if (count of windows) = 0 then
                    make new window
                end if
                tell window 1
                    make new tab with properties {URL:"\(escapedURL)"}
                end tell
            end tell
            """
        case "arc":
            """
            tell application "Arc"
                activate
                tell front window
                    make new tab with properties {URL:"\(escapedURL)"}
                end tell
            end tell
            """
        case "firefox":
            """
            tell application "Firefox"
                activate
                tell window 1
                    make new tab with properties {URL:"\(escapedURL)"}
                end tell
            end tell
            """
        default:
            nil
        }

        guard let script else { return false }

        let result = ClickyAppleScriptRunner.run(script)
        if result.succeeded {
            return true
        }

        print("⚠️ Browser tab AppleScript failed for \(browser): \(result.errorOutput)")
        return false
    }

    private static func spokenSiteName(for url: URL) -> String {
        if let host = url.host?.replacingOccurrences(of: "www.", with: ""), !host.isEmpty {
            return host
        }
        return "that page"
    }
}
