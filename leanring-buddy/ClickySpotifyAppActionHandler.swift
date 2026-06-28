//
//  ClickySpotifyAppActionHandler.swift
//  leanring-buddy
//
//  Spotify playback and search via URL schemes and AppleScript.
//

import Foundation

struct ClickySpotifyAppActionHandler: ClickyAppActionHandling {
    func execute(_ action: ClickyAppAction) async -> String? {
        switch action {
        case .spotifySearchAndPlay(let query):
            return await Self.spotifySearchAndPlay(query: query)
        case .spotifyPlaybackControl(let control):
            return Self.spotifyPlaybackControl(control)
        default:
            return nil
        }
    }

    private static func spotifySearchAndPlay(query: String) async -> String {
        guard let spotifyURL = spotifySearchURL(for: query) else {
            return "i couldn't build a Spotify search for that."
        }

        guard ClickyOpenAppActionHandler.runOpenCommand(arguments: [spotifyURL.absoluteString]) else {
            return "i couldn't open Spotify search for \(query)."
        }

        print("🎵 Spotify search: \(query)")
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        _ = ClickyAppleScriptRunner.run("""
        tell application "Spotify" to activate
        delay 0.3
        tell application "System Events"
            key code 36
        end tell
        """)

        try? await Task.sleep(nanoseconds: 800_000_000)

        let verification = ClickyAppleScriptRunner.run("""
        tell application "Spotify"
            return player state as string
        end tell
        """)

        let playerState = verification.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if verification.succeeded, playerState == "playing" {
            print("🎵 Spotify playing: \(query)")
            return "playing \(query) on Spotify."
        }

        let retry = ClickyAppleScriptRunner.run("""
        tell application "Spotify"
            activate
            play
            delay 0.2
            return player state as string
        end tell
        """)

        let retryState = retry.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if retry.succeeded, retryState == "playing" {
            print("🎵 Spotify playing after retry: \(query)")
            return "playing \(query) on Spotify."
        }

        print("⚠️ Spotify search opened but playback did not start for: \(query)")
        return "i opened Spotify search for \(query), but it didn't start playing."
    }

    private static func spotifyPlaybackControl(_ control: ClickySpotifyPlaybackControl) -> String {
        let (command, acknowledgement): (String, String) = switch control {
        case .play:
            ("play", "playing Spotify.")
        case .pause:
            ("pause", "paused Spotify.")
        case .playPause:
            ("playpause", "toggled Spotify playback.")
        case .next:
            ("next track", "skipped to the next track on Spotify.")
        case .previous:
            ("previous track", "went back on Spotify.")
        }

        let result = ClickyAppleScriptRunner.run("""
        tell application "Spotify"
            \(command)
        end tell
        """)

        if result.succeeded {
            print("🎵 Spotify control: \(command)")
            return acknowledgement
        }

        if ClickyOpenAppActionHandler.runOpenCommand(arguments: ["-a", "Spotify"]) {
            let retry = ClickyAppleScriptRunner.run("""
            tell application "Spotify"
                \(command)
            end tell
            """)
            if retry.succeeded {
                print("🎵 Spotify control after launch: \(command)")
                return acknowledgement
            }
        }

        let errorText = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        print("⚠️ Spotify control failed: \(errorText.isEmpty ? command : errorText)")
        return "i couldn't control Spotify. check that Spotify is installed and automation is allowed for Clicky."
    }

    private static func spotifySearchURL(for query: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        guard !encoded.isEmpty else { return nil }
        return URL(string: "spotify:search:\(encoded)")
    }
}
