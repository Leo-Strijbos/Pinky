//
//  SkillPDFImporter.swift
//  leanring-buddy
//
//  Converts uploaded PDFs into Agent Skills.
//

import Foundation
import PDFKit

enum SkillPDFImporter {
    private static let parseModel = "claude-haiku-4-5"

    private struct StepPayload: Decodable {
        let title: String
        let instruction: String
    }

    private struct ParsedPayload: Decodable {
        let summary: String
        let tags: [String]
        let triggerPhrases: [String]
        let kind: String
        let steps: [StepPayload]

        enum CodingKeys: String, CodingKey {
            case summary, tags, steps, kind
            case triggerPhrases = "trigger_phrases"
        }
    }

    static func importPDF(
        from sourceURL: URL,
        preferredKind: SkillKind,
        claudeAPI: ClaudeAPI,
        existingNames: Set<String>
    ) async throws -> AgentSkill {
        guard let pdfDocument = PDFDocument(url: sourceURL) else {
            throw importError("Could not read PDF.")
        }

        let fullText = extractFullText(from: pdfDocument)
        guard !fullText.isEmpty else {
            throw importError("This PDF has no extractable text.")
        }

        let originalFilename = sourceURL.deletingPathExtension().lastPathComponent
        let title = originalFilename
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        let baseName = SkillNameFormatter.kebabCase(from: title)
        let skillName = SkillNameFormatter.uniqueName(base: baseName, existing: existingNames)

        let referencesDirectory = SkillPaths.referencesDirectory(name: skillName)
        try FileManager.default.createDirectory(at: referencesDirectory, withIntermediateDirectories: true)

        let destinationFilename = "\(skillName).pdf"
        let destinationURL = referencesDirectory.appendingPathComponent(destinationFilename)

        if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        let payload = try await parseContent(
            text: fullText,
            title: title,
            preferredKind: preferredKind,
            claudeAPI: claudeAPI
        )

        let resolvedKind = SkillKind(rawValue: payload.kind) ?? preferredKind
        let now = Date()

        let description = buildDescription(summary: payload.summary, triggerPhrases: payload.triggerPhrases, title: title)
        var bodyLines = [
            "# \(title)",
            "",
            payload.summary,
            "",
        ]

        if resolvedKind == .procedure, !payload.steps.isEmpty {
            bodyLines.append("## Steps")
            bodyLines.append("")
            for (index, step) in payload.steps.enumerated() {
                bodyLines.append("\(index + 1). **\(step.title)** — \(step.instruction)")
            }
            bodyLines.append("")
        } else {
            bodyLines.append(String(fullText.prefix(4000)))
            bodyLines.append("")
        }

        let body = bodyLines.joined(separator: "\n")
        let metadata: [String: String] = [
            "author": "pinky",
            "version": "1.0.0",
            "pinky-source": SkillSource.pdfImport.rawValue,
            "pinky-kind": resolvedKind.rawValue,
            "pinky-title": title,
            "pinky-tags": payload.tags.joined(separator: ","),
        ]

        let markdown = SkillFrontmatterParser.render(
            name: skillName,
            description: description,
            metadata: metadata,
            body: body
        )
        try markdown.write(to: SkillPaths.skillMarkdownURL(name: skillName), atomically: true, encoding: .utf8)

        let playbackSteps: [SkillPlaybackStep]
        if resolvedKind == .procedure, !payload.steps.isEmpty {
            playbackSteps = payload.steps.enumerated().map { index, step in
                SkillPlaybackStep(
                    id: "\(skillName)-step-\(index + 1)",
                    skillName: skillName,
                    index: index,
                    title: step.title,
                    instruction: step.instruction,
                    contextApp: nil,
                    contextURLPattern: nil,
                    contextWindowPattern: nil,
                    lookFor: step.title,
                    doneWhen: nil,
                    thumbnailFilename: nil,
                    capturedAt: now
                )
            }
            let playback = SkillPlaybackFile(steps: playbackSteps)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(playback).write(to: SkillPaths.playbackURL(name: skillName), options: .atomic)
        } else {
            playbackSteps = []
        }

        let chunks = buildChunks(skillName: skillName, title: title, pdfDocument: pdfDocument)
        if !chunks.isEmpty {
            let chunksURL = referencesDirectory.appendingPathComponent("chunks.json")
            try JSONEncoder().encode(chunks).write(to: chunksURL, options: .atomic)
        }

        return AgentSkill(
            name: skillName,
            description: description,
            summary: payload.summary,
            tags: payload.tags,
            kind: resolvedKind,
            source: .pdfImport,
            bodyMarkdown: body,
            directoryURL: SkillPaths.skillDirectory(name: skillName),
            playbackSteps: playbackSteps,
            referenceChunks: chunks,
            sourceFilename: destinationFilename,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func parseContent(
        text: String,
        title: String,
        preferredKind: SkillKind,
        claudeAPI: ClaudeAPI
    ) async throws -> ParsedPayload {
        let truncated = String(text.prefix(14_000))
        let prompt = """
        Transform this company document into an Agent Skill for internal use.
        Reply with ONLY valid JSON:
        {
          "summary": "one compelling sentence",
          "tags": ["topic1", "topic2"],
          "trigger_phrases": ["natural voice phrase to start this", "..."],
          "kind": "\(preferredKind.rawValue)",
          "steps": [
            { "title": "short step title", "instruction": "clear action for this step" }
          ]
        }

        Document title: \(title)
        Preferred kind: \(preferredKind.rawValue)
        Document text:
        \(truncated)

        Rules:
        - For procedure kind: extract ordered steps.
        - For reference kind: steps array should be empty.
        - tags: 2-4 lowercase topic labels.
        - trigger_phrases: 3-5 natural voice commands.
        """

        let raw = try await claudeAPI.sendVoiceRouteClassification(
            systemPrompt: "Reply with ONLY valid JSON, no markdown.",
            userPrompt: prompt,
            model: parseModel
        )

        return try parseJSON(from: raw)
    }

    private static func buildDescription(summary: String, triggerPhrases: [String], title: String) -> String {
        let triggers = triggerPhrases.prefix(3).joined(separator: "; ")
        if triggers.isEmpty {
            return "\(summary) Use when the user asks about \(title.lowercased())."
        }
        return "\(summary) Use when the user asks to \(triggers), or mentions \(title.lowercased())."
    }

    private static func buildChunks(skillName: String, title: String, pdfDocument: PDFDocument) -> [SkillReferenceChunk] {
        var chunks: [SkillReferenceChunk] = []
        let pageCount = pdfDocument.pageCount

        for pageIndex in 0..<pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pageText.isEmpty else { continue }

            for (chunkIndex, chunkText) in chunkText(pageText).enumerated() {
                chunks.append(
                    SkillReferenceChunk(
                        id: "\(skillName)-p\(pageIndex)-c\(chunkIndex)",
                        skillName: skillName,
                        skillTitle: title,
                        pageIndex: pageIndex,
                        chunkIndex: chunkIndex,
                        text: chunkText,
                        relevanceScore: 0
                    )
                )
            }
        }

        return chunks
    }

    private static func chunkText(_ text: String, maxLength: Int = 900) -> [String] {
        guard text.count > maxLength else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }

    private static func extractFullText(from document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
    }

    private static func parseJSON(from raw: String) throws -> ParsedPayload {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        guard
            let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            let data = String(text[start...end]).data(using: .utf8)
        else {
            throw importError("Could not parse PDF skill JSON.")
        }
        return try JSONDecoder().decode(ParsedPayload.self, from: data)
    }

    private static func importError(_ message: String) -> NSError {
        NSError(domain: "SkillPDFImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
