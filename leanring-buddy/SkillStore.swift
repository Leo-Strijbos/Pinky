//
//  SkillStore.swift
//  leanring-buddy
//
//  File-based Agent Skills library under Application Support.
//

import Foundation

enum SkillStoreError: LocalizedError {
    case invalidSkill(String)
    case skillNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidSkill(let name):
            return "Invalid skill: \(name)"
        case .skillNotFound(let name):
            return "Skill not found: \(name)"
        }
    }
}

final class SkillStore {
    private let fileManager = FileManager.default

    init() throws {
        try fileManager.createDirectory(
            at: SkillPaths.skillsRootDirectory,
            withIntermediateDirectories: true
        )
    }

    func allSkills() throws -> [AgentSkill] {
        let directories = try fileManager.contentsOfDirectory(
            at: SkillPaths.skillsRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return try directories.compactMap { url -> AgentSkill? in
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return try? loadSkill(from: url)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func skill(named name: String) throws -> AgentSkill? {
        let directory = SkillPaths.skillDirectory(name: name)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        return try loadSkill(from: directory)
    }

    func deleteSkill(named name: String) throws {
        let directory = SkillPaths.skillDirectory(name: name)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw SkillStoreError.skillNotFound(name)
        }
        try fileManager.removeItem(at: directory)
    }

    func upsert(_ skill: AgentSkill) throws {
        // Skills are written atomically by SkillWriter; reload validates presence.
        guard fileManager.fileExists(atPath: skill.directoryURL.path) else {
            throw SkillStoreError.invalidSkill(skill.name)
        }
    }

    // MARK: - Loading

    private func loadSkill(from directory: URL) throws -> AgentSkill {
        let markdownURL = directory.appendingPathComponent("SKILL.md")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)

        guard let parsed = SkillFrontmatterParser.parse(from: markdown) else {
            throw SkillStoreError.invalidSkill(directory.lastPathComponent)
        }

        let metadata = parsed.frontmatter.metadata
        let kind = SkillKind(rawValue: metadata["pinky-kind"] ?? "") ?? inferKind(from: directory)
        let source = SkillSource(rawValue: metadata["pinky-source"] ?? "") ?? .written
        let summary = metadata["pinky-summary"] ?? firstParagraph(from: parsed.body)
        let tags = metadata["pinky-tags"]?.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? []

        let playbackSteps = try loadPlaybackSteps(from: directory, skillName: parsed.frontmatter.name)
        let referenceChunks = try loadReferenceChunks(from: directory, skillName: parsed.frontmatter.name, title: metadata["pinky-title"] ?? parsed.frontmatter.name)
        let sourceFilename = try? fileManager.contentsOfDirectory(at: SkillPaths.referencesDirectory(name: parsed.frontmatter.name), includingPropertiesForKeys: nil)
            .first { $0.pathExtension.lowercased() == "pdf" }?
            .lastPathComponent

        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        let modified = attributes[.modificationDate] as? Date ?? Date()
        let created = attributes[.creationDate] as? Date ?? modified

        return AgentSkill(
            name: parsed.frontmatter.name,
            description: parsed.frontmatter.description,
            summary: summary,
            tags: tags,
            kind: kind,
            source: source,
            bodyMarkdown: parsed.body,
            directoryURL: directory,
            playbackSteps: playbackSteps,
            referenceChunks: referenceChunks,
            sourceFilename: sourceFilename,
            createdAt: created,
            updatedAt: modified
        )
    }

    private func loadPlaybackSteps(from directory: URL, skillName: String) throws -> [SkillPlaybackStep] {
        let playbackURL = directory.appendingPathComponent("references/pinky-playback.json")
        guard fileManager.fileExists(atPath: playbackURL.path) else { return [] }

        let data = try Data(contentsOf: playbackURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let playback = try decoder.decode(SkillPlaybackFile.self, from: data)
        return playback.steps
    }

    private func loadReferenceChunks(from directory: URL, skillName: String, title: String) throws -> [SkillReferenceChunk] {
        let chunksURL = directory.appendingPathComponent("references/chunks.json")
        guard fileManager.fileExists(atPath: chunksURL.path) else { return [] }

        let data = try Data(contentsOf: chunksURL)
        return try JSONDecoder().decode([SkillReferenceChunk].self, from: data)
    }

    private func inferKind(from directory: URL) -> SkillKind {
        let playbackURL = directory.appendingPathComponent("references/pinky-playback.json")
        if fileManager.fileExists(atPath: playbackURL.path) {
            return .procedure
        }
        return .reference
    }

    private func firstParagraph(from body: String) -> String {
        body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .first ?? ""
    }
}
