//
//  ClickyAppActionModels.swift
//  leanring-buddy
//
//  Structured local app actions for voice commands.
//

import Foundation

enum ClickySpotifyPlaybackControl: Equatable {
    case play
    case pause
    case playPause
    case next
    case previous
}

enum ClickyAppAction: Equatable {
    case openApp(appName: String)
    case openURL(url: URL, browser: String?, newTab: Bool)
    case spotifySearchAndPlay(query: String)
    case spotifyPlaybackControl(ClickySpotifyPlaybackControl)
}

enum ClickyKnownApplication {
    static let bundleIdentifiers: [String: String] = [
        "spotify": "com.spotify.client",
        "safari": "com.apple.Safari",
        "chrome": "com.google.Chrome",
        "arc": "company.thebrowser.Browser",
        "firefox": "org.mozilla.firefox",
        "notes": "com.apple.Notes",
        "calendar": "com.apple.iCal",
        "messages": "com.apple.MobileSMS",
        "mail": "com.apple.mail",
        "music": "com.apple.Music",
        "finder": "com.apple.finder",
        "terminal": "com.apple.Terminal",
        "xcode": "com.apple.dt.Xcode",
        "slack": "com.tinyspeck.slackmacgap",
        "discord": "com.hnc.Discord",
        "zoom": "us.zoom.xos",
        "photos": "com.apple.Photos",
        "preview": "com.apple.Preview",
        "reminders": "com.apple.reminders",
        "maps": "com.apple.Maps",
    ]

    static func normalizedName(from rawName: String) -> String {
        let normalized = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return appAliases[normalized] ?? normalized
    }

    private static let appAliases: [String: String] = [
        "vs code": "visual studio code",
        "vscode": "visual studio code",
        "visual studio": "visual studio code",
        "google chrome": "chrome",
    ]

    static func displayName(for normalizedName: String) -> String {
        switch normalizedName {
        case "spotify": return "Spotify"
        case "safari": return "Safari"
        case "chrome": return "Chrome"
        case "arc": return "Arc"
        case "firefox": return "Firefox"
        case "notes": return "Notes"
        case "calendar": return "Calendar"
        case "messages": return "Messages"
        case "mail": return "Mail"
        case "music": return "Music"
        case "finder": return "Finder"
        case "terminal": return "Terminal"
        case "xcode": return "Xcode"
        case "slack": return "Slack"
        case "discord": return "Discord"
        case "zoom": return "Zoom"
        case "photos": return "Photos"
        case "preview": return "Preview"
        case "reminders": return "Reminders"
        case "maps": return "Maps"
        case "visual studio code": return "Visual Studio Code"
        default:
            return normalizedName.split(separator: " ").map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: " ")
        }
    }

    static func isKnownApp(_ normalizedName: String) -> Bool {
        bundleIdentifiers[normalizedName] != nil
    }

    static func isBrowser(_ normalizedName: String) -> Bool {
        ClickyURLActionParser.isBrowser(normalizedName)
    }
}
