//
//  PinkyFilePathResolver.swift
//  leanring-buddy
//
//  Resolves spoken or model-provided file paths for read/present capabilities.
//

import Foundation

enum PinkyFilePathResolver {

    static func resolve(_ rawPath: String) -> URL? {
        var trimmed = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("~") {
            trimmed = (trimmed as NSString).expandingTildeInPath
        }

        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            return url.isFileURL ? url : nil
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let relativeURL = cwd.appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: relativeURL.path) {
            return relativeURL
        }

        let homeRelative = URL(fileURLWithPath: (("~/" + trimmed) as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: homeRelative.path) {
            return homeRelative
        }

        return nil
    }
}
