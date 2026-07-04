//
//  SkillWriter.swift
//  leanring-buddy
//
//  Writes Agent Skills format from teaching drafts and PDF imports.
//

import Foundation

enum SkillWriter {

    static func writeSkill(
        from draft: SkillDraft,
        artifact: TeachingArtifact,
        name: String,
        title: String
    ) throws -> AgentSkill {
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? draft.suggestedName
            : SkillNameFormatter.kebabCase(from: name)
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? draft.suggestedTitle
            : title

        let skillDirectory = SkillPaths.skillDirectory(name: resolvedName)
        let assetsDirectory = SkillPaths.assetsDirectory(name: resolvedName)
        let referencesDirectory = SkillPaths.referencesDirectory(name: resolvedName)

        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: referencesDirectory, withIntermediateDirectories: true)

        let now = Date()
        let steps = try buildPlaybackSteps(
            from: draft,
            artifact: artifact,
            skillName: resolvedName,
            assetsDirectory: assetsDirectory,
            capturedAt: artifact.startedAt
        )

        let body = buildSkillBody(title: resolvedTitle, summary: draft.summary, steps: draft.steps)
        let description = buildDescription(
            summary: draft.summary,
            triggerPhrases: draft.triggerPhrases,
            title: resolvedTitle
        )

        let metadata: [String: String] = [
            "author": "pinky",
            "version": "1.0.0",
            "pinky-source": SkillSource.recorded.rawValue,
            "pinky-kind": SkillKind.procedure.rawValue,
            "pinky-title": resolvedTitle,
            "pinky-tags": draft.tags.joined(separator: ","),
            "pinky-recorded-at": ISO8601DateFormatter().string(from: now),
        ]

        let markdown = SkillFrontmatterParser.render(
            name: resolvedName,
            description: description,
            metadata: metadata,
            body: body
        )

        try markdown.write(to: SkillPaths.skillMarkdownURL(name: resolvedName), atomically: true, encoding: .utf8)

        let playback = SkillPlaybackFile(steps: steps)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let playbackData = try encoder.encode(playback)
        try playbackData.write(to: SkillPaths.playbackURL(name: resolvedName), options: .atomic)

        return AgentSkill(
            name: resolvedName,
            description: description,
            summary: draft.summary,
            tags: draft.tags,
            kind: .procedure,
            source: .recorded,
            bodyMarkdown: body,
            directoryURL: skillDirectory,
            playbackSteps: steps,
            referenceChunks: [],
            sourceFilename: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    static func writeReferenceSkill(
        name: String,
        title: String,
        description: String,
        summary: String,
        tags: [String],
        body: String,
        sourceFilename: String?,
        referenceChunks: [SkillReferenceChunk]
    ) throws -> AgentSkill {
        let skillDirectory = SkillPaths.skillDirectory(name: name)
        let referencesDirectory = SkillPaths.referencesDirectory(name: name)
        try FileManager.default.createDirectory(at: referencesDirectory, withIntermediateDirectories: true)

        let now = Date()
        let metadata: [String: String] = [
            "author": "pinky",
            "version": "1.0.0",
            "pinky-source": SkillSource.pdfImport.rawValue,
            "pinky-kind": SkillKind.reference.rawValue,
            "pinky-title": title,
            "pinky-tags": tags.joined(separator: ","),
        ]

        let markdown = SkillFrontmatterParser.render(
            name: name,
            description: description,
            metadata: metadata,
            body: body
        )

        try markdown.write(to: SkillPaths.skillMarkdownURL(name: name), atomically: true, encoding: .utf8)

        if !referenceChunks.isEmpty {
            let chunksURL = referencesDirectory.appendingPathComponent("chunks.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(referenceChunks).write(to: chunksURL, options: .atomic)
        }

        return AgentSkill(
            name: name,
            description: description,
            summary: summary,
            tags: tags,
            kind: .reference,
            source: .pdfImport,
            bodyMarkdown: body,
            directoryURL: skillDirectory,
            playbackSteps: [],
            referenceChunks: referenceChunks,
            sourceFilename: sourceFilename,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func buildPlaybackSteps(
        from draft: SkillDraft,
        artifact: TeachingArtifact,
        skillName: String,
        assetsDirectory: URL,
        capturedAt: Date
    ) throws -> [SkillPlaybackStep] {
        try draft.steps.enumerated().map { index, step in
            let stepID = "\(skillName)-step-\(index + 1)"
            var thumbnailFilename: String?

            if let keyframeID = step.keyframeID,
               let keyframe = artifact.keyframes.first(where: { $0.id == keyframeID }) {
                thumbnailFilename = "step-\(index + 1).jpg"
                try keyframe.jpegData.write(
                    to: assetsDirectory.appendingPathComponent(thumbnailFilename!),
                    options: .atomic
                )
            }

            return SkillPlaybackStep(
                id: stepID,
                skillName: skillName,
                index: index,
                title: step.title,
                instruction: step.instruction,
                contextApp: step.context.app,
                contextURLPattern: ScreenContextMatcher.urlPattern(from: step.context.url),
                contextWindowPattern: windowPattern(from: step.context.windowTitle, app: step.context.app),
                lookFor: step.lookFor,
                doneWhen: step.doneWhen,
                thumbnailFilename: thumbnailFilename,
                capturedAt: capturedAt
            )
        }
    }

    private static func buildSkillBody(title: String, summary: String, steps: [SkillDraftStep]) -> String {
        var lines = [
            "# \(title)",
            "",
            summary,
            "",
            "## Steps",
            "",
        ]

        for (index, step) in steps.enumerated() {
            lines.append("\(index + 1). **\(step.title)** — \(step.instruction)")
            if let doneWhen = step.doneWhen, !doneWhen.isEmpty {
                lines.append("   Done when: \(doneWhen)")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func buildDescription(
        summary: String,
        triggerPhrases: [String],
        title: String
    ) -> String {
        let triggers = triggerPhrases.prefix(3).joined(separator: "; ")
        let base = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if triggers.isEmpty {
            return "\(base) Use when the user asks about \(title.lowercased()) or wants a walkthrough."
        }
        return "\(base) Use when the user asks to \(triggers), or mentions \(title.lowercased())."
    }

    private static func windowPattern(from raw: String?, app: String) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        for suffix in [" - \(app)", " — \(app)", " – \(app)"] {
            if title.lowercased().hasSuffix(suffix.lowercased()) {
                title = String(title.dropLast(suffix.count))
                break
            }
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return title.count > 64 ? String(title.prefix(64)) : title
    }
}
