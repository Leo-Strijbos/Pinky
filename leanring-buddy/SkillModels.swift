//
//  SkillModels.swift
//  leanring-buddy
//
//  Agent Skills format — portable company knowledge for Pinky and other agents.
//

import Foundation

enum SkillKind: String, Equatable, Codable {
    case procedure
    case reference
}

enum SkillSource: String, Equatable, Codable {
    case recorded
    case pdfImport
    case written
}

struct SkillPlaybackStep: Identifiable, Equatable, Codable {
    let id: String
    let skillName: String
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

    func thumbnailURL(in skillDirectory: URL) -> URL? {
        guard let thumbnailFilename else { return nil }
        return skillDirectory.appendingPathComponent("assets/\(thumbnailFilename)")
    }
}

struct SkillReferenceChunk: Identifiable, Equatable, Codable {
    let id: String
    let skillName: String
    let skillTitle: String
    let pageIndex: Int
    let chunkIndex: Int
    let text: String
    let relevanceScore: Double
}

/// Loaded Agent Skill from disk.
struct AgentSkill: Identifiable, Equatable {
    let name: String
    let description: String
    let summary: String
    let tags: [String]
    let kind: SkillKind
    let source: SkillSource
    let bodyMarkdown: String
    let directoryURL: URL
    let playbackSteps: [SkillPlaybackStep]
    let referenceChunks: [SkillReferenceChunk]
    let sourceFilename: String?
    let createdAt: Date
    let updatedAt: Date

    var id: String { name }
    var title: String { humanTitle(from: name) }

    var sourceFileURL: URL? {
        guard let sourceFilename else { return nil }
        return directoryURL.appendingPathComponent("references/\(sourceFilename)")
    }

    private func humanTitle(from name: String) -> String {
        name.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}

struct SkillRetrieval: Equatable {
    let skill: AgentSkill
    let steps: [SkillPlaybackStep]
    let relevanceScore: Double

    func narrowPromptFragment(currentIndex: Int = 0) -> String {
        let ordered = steps.sorted { $0.index < $1.index }
        guard !ordered.isEmpty else {
            return """
            matched skill: \(skill.name)
            description: \(skill.description)
            """
        }

        let idx = min(max(currentIndex, 0), ordered.count - 1)
        var lines = [
            "matched company skill: \(skill.name)",
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

    func overviewPromptFragment() -> String {
        let ordered = steps.sorted { $0.index < $1.index }
        var lines = [
            "matched company skill: \(skill.name)",
            "description: \(skill.description)",
        ]

        if !skill.bodyMarkdown.isEmpty {
            lines.append("")
            lines.append(skill.bodyMarkdown)
        }

        guard !ordered.isEmpty else {
            lines.append("use this skill when answering questions about the workflow the user taught.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("recorded steps (\(ordered.count)):")
        for step in ordered {
            lines.append("\(step.index + 1). \(step.title): \(step.instruction)")
        }
        lines.append("answer from these recorded steps. do not invent steps that were not captured.")
        return lines.joined(separator: "\n")
    }
}

struct SkillReferenceRetrieval: Equatable {
    let chunks: [SkillReferenceChunk]

    var isEmpty: Bool { chunks.isEmpty }

    func promptFragment() -> String {
        guard !chunks.isEmpty else { return "" }

        var lines = [
            "relevant excerpts from company skills:",
            "",
        ]

        for chunk in chunks {
            lines.append("[\(chunk.skillTitle)]: \(chunk.text)")
            lines.append("")
        }

        lines.append("use these excerpts when answering. do not invent policy details beyond them.")
        return lines.joined(separator: "\n")
    }
}

struct SkillSourceDocument: Equatable {
    let skillName: String
    let title: String
    let fileURL: URL
    let pageIndex: Int
}

enum SkillPaths {
    static var applicationSupportDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("Pinky", isDirectory: true)
    }

    static var skillsRootDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("skills", isDirectory: true)
    }

    static func skillDirectory(name: String) -> URL {
        skillsRootDirectory.appendingPathComponent(name, isDirectory: true)
    }

    static func skillMarkdownURL(name: String) -> URL {
        skillDirectory(name: name).appendingPathComponent("SKILL.md")
    }

    static func playbackURL(name: String) -> URL {
        skillDirectory(name: name).appendingPathComponent("references/pinky-playback.json")
    }

    static func assetsDirectory(name: String) -> URL {
        skillDirectory(name: name).appendingPathComponent("assets", isDirectory: true)
    }

    static func referencesDirectory(name: String) -> URL {
        skillDirectory(name: name).appendingPathComponent("references", isDirectory: true)
    }
}

// MARK: - Playback sidecar (Pinky extension — other agents ignore)

struct SkillPlaybackFile: Codable {
    let steps: [SkillPlaybackStep]
}

// MARK: - Draft types (interpreter output, pre-persistence)

struct SkillDraftStep: Sendable, Equatable {
    let title: String
    let instruction: String
    let lookFor: String?
    let doneWhen: String?
    let context: ScreenContext
    let keyframeID: String?
    let narration: String
}

struct SkillDraft: Sendable, Equatable {
    let suggestedName: String
    let suggestedTitle: String
    let summary: String
    let tags: [String]
    let triggerPhrases: [String]
    let steps: [SkillDraftStep]
}
