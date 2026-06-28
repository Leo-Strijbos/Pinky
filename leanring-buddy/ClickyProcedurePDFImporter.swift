//
//  ClickyProcedurePDFImporter.swift
//  leanring-buddy
//
//  Parses step-by-step procedures from uploaded PDFs into synthetic workflows.
//

import Foundation
import PDFKit

enum ClickyProcedurePDFImporter {

    private static let parseModel = "claude-haiku-4-5"
    private static let placeholderThumbnail = "__pdf_procedure__.jpg"

    struct ParsedProcedure: Equatable {
        let workflow: ClickyWorkflow
        let steps: [ClickyWorkflowScreenState]
    }

    private struct StepPayload: Decodable {
        let name: String
        let instruction: String
    }

    private struct ProcedurePayload: Decodable {
        let goal: String
        let summary: String
        let triggerPhrases: [String]
        let steps: [StepPayload]

        enum CodingKeys: String, CodingKey {
            case goal, summary, steps
            case triggerPhrases = "trigger_phrases"
        }
    }

    static func buildProcedure(
        document: ClickyKnowledgeDocument,
        claudeAPI: ClaudeAPI
    ) async throws -> ParsedProcedure {
        let fullText = try extractFullText(from: document.fileURL)
        guard !fullText.isEmpty else {
            throw importerError("This PDF has no extractable text.")
        }

        let payload = try await parseSteps(from: fullText, documentTitle: document.title, claudeAPI: claudeAPI)
        guard !payload.steps.isEmpty else {
            throw importerError("No procedure steps were found in this PDF.")
        }

        let workflowID = "pdf-\(document.id)"
        let capturedAt = Date()
        let steps = payload.steps.enumerated().map { index, step in
            let instruction = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = step.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = name.isEmpty ? "Step \(index + 1)" : name

            return ClickyWorkflowScreenState(
                id: "\(workflowID)-step-\(index + 1)",
                workflowID: workflowID,
                stepIndex: index,
                name: resolvedName,
                app: "",
                urlPattern: nil,
                windowTitlePattern: nil,
                meaning: instruction.isEmpty ? resolvedName : instruction,
                userIntent: instruction.isEmpty ? resolvedName : instruction,
                spokenDescription: instruction,
                isEntryState: index == 0,
                ocrTerms: [],
                commonQuestions: buildQuestions(from: resolvedName, instruction: instruction),
                relatedSOPIDs: [document.id],
                visualFingerprint: "",
                thumbnailFilename: placeholderThumbnail,
                capturedAt: capturedAt
            )
        }

        let workflow = ClickyWorkflow(
            id: workflowID,
            name: document.title,
            summary: payload.summary,
            goal: payload.goal,
            triggerPhrases: payload.triggerPhrases,
            recordedAt: capturedAt,
            stateCount: steps.count,
            source: .pdf,
            sourceDocumentID: document.id
        )

        return ParsedProcedure(workflow: workflow, steps: steps)
    }

    static func extractFullText(from pdfURL: URL) throws -> String {
        guard let pdfDocument = PDFDocument(url: pdfURL) else {
            throw importerError("Could not read PDF.")
        }

        var pages: [String] = []
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pageText.isEmpty else { continue }
            pages.append(pageText)
        }

        return pages.joined(separator: "\n\n")
    }

    private static func parseSteps(
        from text: String,
        documentTitle: String,
        claudeAPI: ClaudeAPI
    ) async throws -> ProcedurePayload {
        let truncated = String(text.prefix(12_000))
        let prompt = """
        Extract a step-by-step procedure from this document text.
        Reply with ONLY valid JSON:
        {
          "goal": "one sentence describing what this procedure accomplishes",
          "summary": "one sentence summary",
          "trigger_phrases": ["short voice phrase", "..."],
          "steps": [
            { "name": "short step title", "instruction": "what to do in this step" }
          ]
        }

        Document title: \(documentTitle)
        Document text:
        \(truncated)

        Rules:
        - Preserve the original step order.
        - Each step should be one clear action.
        - trigger_phrases: 3-6 natural voice commands someone might use to start this procedure.
        - If the text is not a procedure, return an empty steps array.
        """

        let raw = try await claudeAPI.sendVoiceRouteClassification(
            systemPrompt: "Reply with ONLY valid JSON, no markdown.",
            userPrompt: prompt,
            model: parseModel
        )

        return try parseJSON(from: raw)
    }

    private static func buildQuestions(from name: String, instruction: String) -> [String] {
        let base = instruction.isEmpty ? name : instruction
        let lowered = base.lowercased()
        return [
            "how do I \(lowered)",
            "what is step \(name.lowercased())",
            lowered,
        ]
    }

    private static func parseJSON<T: Decodable>(from raw: String) throws -> T {
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
            throw importerError("Could not parse procedure JSON.")
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func importerError(_ message: String) -> NSError {
        NSError(domain: "ClickyProcedurePDFImporter", code: -1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
