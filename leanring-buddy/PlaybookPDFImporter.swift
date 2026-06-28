//
//  PlaybookPDFImporter.swift
//  leanring-buddy
//
//  Converts uploaded PDFs into structured playbooks with beautiful doc blocks.
//

import Foundation
import PDFKit

enum PlaybookPDFImporter {

    private static let parseModel = "claude-haiku-4-5"

    struct ImportResult: Equatable {
        let playbook: Playbook
        let steps: [PlaybookStep]
        let chunks: [PlaybookChunk]
    }

    private struct StepPayload: Decodable {
        let title: String
        let instruction: String
    }

    private struct BlockPayload: Decodable {
        let kind: String
        let title: String?
        let body: String?
        let items: [String]?

        enum CodingKeys: String, CodingKey {
            case kind, title, body, items
        }
    }

    private struct ParsedPayload: Decodable {
        let summary: String
        let tags: [String]
        let triggerPhrases: [String]
        let kind: String
        let steps: [StepPayload]
        let docBlocks: [BlockPayload]

        enum CodingKeys: String, CodingKey {
            case summary, tags, steps, kind
            case triggerPhrases = "trigger_phrases"
            case docBlocks = "doc_blocks"
        }
    }

    static func importPDF(
        from sourceURL: URL,
        preferredKind: PlaybookKind,
        claudeAPI: ClaudeAPI
    ) async throws -> ImportResult {
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

        let playbookID = slugify(title)
        let destinationFilename = "\(playbookID).pdf"
        let destinationURL = PlaybookPaths.documentsDirectory.appendingPathComponent(destinationFilename)

        try FileManager.default.createDirectory(
            at: PlaybookPaths.documentsDirectory,
            withIntermediateDirectories: true
        )

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

        let resolvedKind = PlaybookKind(rawValue: payload.kind) ?? preferredKind
        let now = Date()

        let docBlocks = payload.docBlocks.map { block in
            PlaybookDocBlock(
                kind: PlaybookDocBlockKind(rawValue: block.kind) ?? .paragraph,
                title: block.title,
                body: block.body,
                items: block.items
            )
        }

        let steps: [PlaybookStep]
        if resolvedKind == .procedure, !payload.steps.isEmpty {
            steps = payload.steps.enumerated().map { index, step in
                let stepTitle = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let instruction = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedTitle = stepTitle.isEmpty ? "Step \(index + 1)" : stepTitle

                return PlaybookStep(
                    id: "\(playbookID)-step-\(index + 1)",
                    playbookID: playbookID,
                    index: index,
                    title: resolvedTitle,
                    instruction: instruction.isEmpty ? resolvedTitle : instruction,
                    contextApp: nil,
                    contextURLPattern: nil,
                    contextWindowPattern: nil,
                    lookFor: resolvedTitle,
                    doneWhen: nil,
                    thumbnailFilename: nil,
                    capturedAt: now
                )
            }
        } else {
            steps = []
        }

        let finalDocBlocks = docBlocks.isEmpty
            ? fallbackDocBlocks(title: title, summary: payload.summary, steps: steps, fullText: fullText)
            : docBlocks

        let playbook = Playbook(
            id: playbookID,
            title: title,
            summary: payload.summary,
            tags: payload.tags,
            kind: resolvedKind,
            source: .pdfImport,
            sourceFilename: destinationFilename,
            stepCount: steps.count,
            triggerPhrases: payload.triggerPhrases,
            docBlocks: finalDocBlocks,
            createdAt: now,
            updatedAt: now
        )

        let chunks = buildChunks(
            playbookID: playbookID,
            title: title,
            pdfDocument: pdfDocument
        )

        return ImportResult(playbook: playbook, steps: steps, chunks: chunks)
    }

    private static func parseContent(
        text: String,
        title: String,
        preferredKind: PlaybookKind,
        claudeAPI: ClaudeAPI
    ) async throws -> ParsedPayload {
        let truncated = String(text.prefix(14_000))
        let prompt = """
        Transform this company document into a beautiful internal playbook.
        Reply with ONLY valid JSON:
        {
          "summary": "one compelling sentence",
          "tags": ["topic1", "topic2"],
          "trigger_phrases": ["natural voice phrase to start this", "..."],
          "kind": "\(preferredKind.rawValue)",
          "steps": [
            { "title": "short step title", "instruction": "clear action for this step" }
          ],
          "doc_blocks": [
            { "kind": "hero", "title": "document title", "body": "short subtitle" },
            { "kind": "heading", "title": "section name" },
            { "kind": "paragraph", "body": "readable prose" },
            { "kind": "steps", "title": "How to do it", "items": ["step one", "step two"] },
            { "kind": "callout", "title": "Important", "body": "key note" }
          ]
        }

        Document title: \(title)
        Preferred kind: \(preferredKind.rawValue)
        Document text:
        \(truncated)

        Rules:
        - doc_blocks should read like polished internal documentation, not raw PDF dump.
        - For procedure kind: extract ordered steps AND include a doc_blocks "steps" section.
        - For reference kind: steps array should be empty; focus on doc_blocks.
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

    private static func fallbackDocBlocks(
        title: String,
        summary: String,
        steps: [PlaybookStep],
        fullText: String
    ) -> [PlaybookDocBlock] {
        var blocks: [PlaybookDocBlock] = [
            PlaybookDocBlock(kind: .hero, title: title, body: summary),
        ]

        if !steps.isEmpty {
            blocks.append(PlaybookDocBlock(kind: .heading, title: "Steps"))
            blocks.append(
                PlaybookDocBlock(
                    kind: .steps,
                    items: steps.map { "\($0.title): \($0.instruction)" }
                )
            )
        } else {
            let preview = String(fullText.prefix(1200))
            blocks.append(PlaybookDocBlock(kind: .paragraph, body: preview))
        }

        return blocks
    }

    private static func buildChunks(
        playbookID: String,
        title: String,
        pdfDocument: PDFDocument
    ) -> [PlaybookChunk] {
        var chunks: [PlaybookChunk] = []
        let pageCount = pdfDocument.pageCount

        for pageIndex in 0..<pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pageText.isEmpty else { continue }

            for (chunkIndex, chunkText) in chunkText(pageText).enumerated() {
                chunks.append(
                    PlaybookChunk(
                        id: "\(playbookID)-p\(pageIndex)-c\(chunkIndex)",
                        playbookID: playbookID,
                        playbookTitle: title,
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

    private static func extractFullText(from pdfDocument: PDFDocument) -> String {
        var pages: [String] = []
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pageText.isEmpty else { continue }
            pages.append(pageText)
        }
        return pages.joined(separator: "\n\n")
    }

    private static func chunkText(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let maxLength = 900
        guard normalized.count > maxLength else { return [normalized] }

        var chunks: [String] = []
        var start = normalized.startIndex
        while start < normalized.endIndex {
            let end = normalized.index(start, offsetBy: maxLength, limitedBy: normalized.endIndex) ?? normalized.endIndex
            chunks.append(String(normalized[start..<end]))
            start = end
        }
        return chunks
    }

    private static func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        let slug = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return slug.isEmpty ? UUID().uuidString.lowercased() : slug
    }

    private static func parseJSON(from raw: String) throws -> ParsedPayload {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard
            let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            let data = String(text[start...end]).data(using: .utf8)
        else {
            throw importError("Could not parse AI response.")
        }

        return try JSONDecoder().decode(ParsedPayload.self, from: data)
    }

    private static func importError(_ message: String) -> NSError {
        NSError(domain: "PlaybookPDFImporter", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
