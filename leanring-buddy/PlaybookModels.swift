//
//  PlaybookModels.swift
//  leanring-buddy
//
//  Unified company knowledge: procedures and reference docs in one model.
//

import AppKit
import Foundation

enum PlaybookKind: String, Equatable, Codable {
    case procedure
    case reference
}

enum PlaybookSource: String, Equatable, Codable {
    case recorded
    case pdfImport
    case written
}

enum PlaybookDocBlockKind: String, Equatable, Codable {
    case hero
    case heading
    case paragraph
    case steps
    case callout
    case divider
}

struct PlaybookDocBlock: Identifiable, Equatable, Codable {
    let id: String
    var kind: PlaybookDocBlockKind
    var title: String?
    var body: String?
    var items: [String]?

    init(
        id: String = UUID().uuidString.lowercased(),
        kind: PlaybookDocBlockKind,
        title: String? = nil,
        body: String? = nil,
        items: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.items = items
    }
}

struct Playbook: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    var summary: String
    var tags: [String]
    var kind: PlaybookKind
    var source: PlaybookSource
    var sourceFilename: String?
    var stepCount: Int
    var triggerPhrases: [String]
    var docBlocks: [PlaybookDocBlock]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        title: String,
        summary: String,
        tags: [String] = [],
        kind: PlaybookKind,
        source: PlaybookSource,
        sourceFilename: String? = nil,
        stepCount: Int = 0,
        triggerPhrases: [String] = [],
        docBlocks: [PlaybookDocBlock] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.tags = tags
        self.kind = kind
        self.source = source
        self.sourceFilename = sourceFilename
        self.stepCount = stepCount
        self.triggerPhrases = triggerPhrases
        self.docBlocks = docBlocks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var sourceFileURL: URL? {
        guard let sourceFilename else { return nil }
        return PlaybookPaths.documentsDirectory.appendingPathComponent(sourceFilename)
    }
}

struct PlaybookStep: Identifiable, Equatable, Codable {
    let id: String
    let playbookID: String
    let index: Int
    var title: String
    var instruction: String
    var contextApp: String?
    var contextURLPattern: String?
    var contextWindowPattern: String?
    var lookFor: String?
    var doneWhen: String?
    var thumbnailFilename: String?
    let capturedAt: Date?

    var thumbnailURL: URL? {
        guard let thumbnailFilename else { return nil }
        return PlaybookPaths.thumbnailsDirectory.appendingPathComponent(thumbnailFilename)
    }
}

struct PlaybookChunk: Identifiable, Equatable {
    let id: String
    let playbookID: String
    let playbookTitle: String
    let pageIndex: Int
    let chunkIndex: Int
    let text: String
    let relevanceScore: Double
}

struct PlaybookRetrieval: Equatable {
    let playbook: Playbook
    let steps: [PlaybookStep]
    let relevanceScore: Double

    func narrowPromptFragment(currentIndex: Int = 0) -> String {
        let ordered = steps.sorted { $0.index < $1.index }
        guard !ordered.isEmpty else {
            return """
            matched playbook: \(playbook.title)
            summary: \(playbook.summary)
            """
        }

        let idx = min(max(currentIndex, 0), ordered.count - 1)
        var lines = [
            "matched company playbook: \(playbook.title)",
            "current step \(idx + 1) of \(ordered.count): \(ordered[idx].title)",
            "instruction: \(ordered[idx].instruction)",
        ]

        if idx + 1 < ordered.count {
            let next = ordered[idx + 1]
            lines.append("next: \(next.title) — \(next.instruction)")
        }

        lines.append("guide the user through the current step. point at on-screen UI when helpful.")
        return lines.joined(separator: "\n")
    }
}

struct PlaybookReferenceRetrieval: Equatable {
    let chunks: [PlaybookChunk]

    var isEmpty: Bool { chunks.isEmpty }

    func promptFragment() -> String {
        guard !chunks.isEmpty else { return "" }

        var lines = [
            "relevant excerpts from company playbooks:",
            "",
        ]

        for chunk in chunks {
            lines.append("[\(chunk.playbookTitle)]: \(chunk.text)")
            lines.append("")
        }

        lines.append("use these excerpts when answering. do not invent policy details beyond them.")
        return lines.joined(separator: "\n")
    }
}

struct PlaybookScreenContext: Equatable {
    let app: String
    let url: String?
    let windowTitle: String?
}

struct PlaybookSourceDocument: Equatable {
    let playbookID: String
    let title: String
    let fileURL: URL
    let pageIndex: Int
}

enum PlaybookPaths {
    static var applicationSupportDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("Clicky", isDirectory: true)
    }

    static var playbookRootDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("playbooks", isDirectory: true)
    }

    static var documentsDirectory: URL {
        playbookRootDirectory.appendingPathComponent("documents", isDirectory: true)
    }

    static var thumbnailsDirectory: URL {
        playbookRootDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    }

    static var catalogURL: URL {
        playbookRootDirectory.appendingPathComponent("catalog.json")
    }

    static var databaseURL: URL {
        playbookRootDirectory.appendingPathComponent("playbooks.sqlite")
    }

    static func deleteAssets(forPlaybookID playbookID: String) {
        let fileManager = FileManager.default
        let prefix = "\(playbookID)-"

        if let thumbnailFiles = try? fileManager.contentsOfDirectory(
            at: thumbnailsDirectory,
            includingPropertiesForKeys: nil
        ) {
            for fileURL in thumbnailFiles where fileURL.lastPathComponent.hasPrefix(prefix) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }
}

enum PlaybookContextMatcher {
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

    static func matchScore(for step: PlaybookStep, context: PlaybookScreenContext) -> Double {
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
        steps: [PlaybookStep],
        context: PlaybookScreenContext,
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

    private static func contextAppOrURLRequired(_ step: PlaybookStep) -> Bool {
        !(step.contextApp ?? "").isEmpty || !(step.contextURLPattern ?? "").isEmpty
    }
}

enum PlaybookScreenContextCapture {
    static func captureCurrentContext() -> PlaybookScreenContext {
        PlaybookScreenContext(
            app: frontmostAppName(),
            url: browserURL(forApp: frontmostAppName()),
            windowTitle: frontmostWindowTitle()
        )
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
