//
//  ClickyWorkflowIndexer.swift
//  leanring-buddy
//
//  Labels workflow snapshots into structured screen states.
//  Narration is the primary label source; vision fills in only when the user didn't narrate.
//

import Foundation

enum ClickyWorkflowIndexer {

    private static let labelModel = "claude-haiku-4-5"

    struct WorkflowMetadata: Equatable {
        let goal: String
        let triggerPhrases: [String]
        let summary: String
    }

    private struct StepLabelContent {
        let name: String
        let meaning: String
        let userIntent: String
        let commonQuestions: [String]
        let ocrTerms: [String]
    }

    static func buildScreenStates(
        workflowID: String,
        snapshots: [ClickyWorkflowRawSnapshot],
        claudeAPI: ClaudeAPI
    ) async throws -> [ClickyWorkflowScreenState] {
        var states: [ClickyWorkflowScreenState] = []

        for (index, snapshot) in snapshots.enumerated() {
            let ocrTerms = ClickyWorkflowOCR.recognizeTerms(from: snapshot.imageData)
            let label: StepLabelContent

            if !snapshot.spokenDescription.isEmpty {
                label = labelFromNarration(snapshot: snapshot, ocrTerms: ocrTerms, stepIndex: index)
                print("🎬 Step \(index + 1) labeled from narration: \(label.name)")
            } else {
                label = labelFromHeuristics(snapshot: snapshot, ocrTerms: ocrTerms, stepIndex: index)
                print("🎬 Step \(index + 1) labeled from heuristics: \(label.name)")
            }

            let stateID = "\(workflowID)-step-\(index + 1)"
            let thumbnailFilename = "\(stateID).jpg"
            let thumbnailURL = ClickyWorkflowPaths.thumbnailsDirectory.appendingPathComponent(thumbnailFilename)
            try snapshot.imageData.write(to: thumbnailURL, options: .atomic)

            states.append(
                ClickyWorkflowScreenState(
                    id: stateID,
                    workflowID: workflowID,
                    stepIndex: index,
                    name: label.name,
                    app: snapshot.app,
                    urlPattern: ClickyWorkflowPatternMatcher.urlPattern(from: snapshot.url),
                    windowTitlePattern: ClickyWorkflowPatternMatcher.windowTitlePattern(
                        from: snapshot.windowTitle,
                        app: snapshot.app
                    ),
                    meaning: label.meaning,
                    userIntent: label.userIntent,
                    spokenDescription: snapshot.spokenDescription,
                    isEntryState: snapshot.isEntryState,
                    ocrTerms: label.ocrTerms,
                    commonQuestions: label.commonQuestions,
                    relatedSOPIDs: [],
                    visualFingerprint: snapshot.visualFingerprint,
                    thumbnailFilename: thumbnailFilename,
                    capturedAt: snapshot.capturedAt
                )
            )
        }

        return states
    }

    static func buildWorkflowMetadata(
        name: String,
        states: [ClickyWorkflowScreenState],
        claudeAPI: ClaudeAPI
    ) async throws -> WorkflowMetadata {
        let narrations = states
            .filter { !$0.spokenDescription.isEmpty }
            .map { "step \($0.stepIndex + 1): \($0.spokenDescription)" }
            .joined(separator: "\n")

        let stepSummaries = states.map { step in
            var line = "\(step.stepIndex + 1). \(step.name): \(step.meaning)"
            if step.isEntryState { line += " [entry]" }
            return line
        }.joined(separator: "\n")

        let prompt = """
        Build workflow metadata from this recorded macOS workflow.
        Reply with ONLY valid JSON:
        {
          "goal": "one sentence describing what this workflow accomplishes",
          "summary": "one sentence summary",
          "trigger_phrases": ["short phrase users might say to start this workflow", "..."]
        }

        Workflow name: \(name)
        Steps:
        \(stepSummaries)
        User narrations during recording:
        \(narrations.isEmpty ? "none" : narrations)

        trigger_phrases should be 3-6 natural voice commands derived from the narrations and steps.
        """

        let raw = try await claudeAPI.sendVoiceRouteClassification(
            systemPrompt: "Reply with ONLY valid JSON, no markdown.",
            userPrompt: prompt,
            model: labelModel
        )

        let payload = try parseMetadataPayload(from: raw)
        return WorkflowMetadata(
            goal: payload.goal,
            triggerPhrases: payload.triggerPhrases,
            summary: payload.summary
        )
    }

    private static func labelFromNarration(
        snapshot: ClickyWorkflowRawSnapshot,
        ocrTerms: [String],
        stepIndex: Int
    ) -> StepLabelContent {
        let narration = snapshot.spokenDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = stepName(from: narration, fallbackIndex: stepIndex + 1)
        let questions = buildQuestions(from: narration)

        return StepLabelContent(
            name: name,
            meaning: narration,
            userIntent: narration,
            commonQuestions: questions,
            ocrTerms: ocrTerms
        )
    }

    private static func labelFromHeuristics(
        snapshot: ClickyWorkflowRawSnapshot,
        ocrTerms: [String],
        stepIndex: Int
    ) -> StepLabelContent {
        let fallbackName = snapshot.windowTitle.map {
            ClickyWorkflowPatternMatcher.windowTitlePattern(from: $0, app: snapshot.app) ?? $0
        } ?? "Step \(stepIndex + 1)"

        let visibleHint = ocrTerms.prefix(8).joined(separator: ", ")
        let meaning: String
        if visibleHint.isEmpty {
            meaning = "Continue the workflow on \(snapshot.app)."
        } else {
            meaning = "On \(snapshot.app), look for: \(visibleHint)."
        }

        return StepLabelContent(
            name: fallbackName,
            meaning: meaning,
            userIntent: meaning,
            commonQuestions: [
                "what do I do on \(fallbackName.lowercased())",
                "how do I continue this workflow",
            ],
            ocrTerms: ocrTerms
        )
    }

    private static func stepName(from narration: String, fallbackIndex: Int) -> String {
        let trimmed = narration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Step \(fallbackIndex)" }
        if trimmed.count <= 48 { return trimmed }

        var result = ""
        for word in trimmed.split(separator: " ") {
            let next = result.isEmpty ? String(word) : "\(result) \(word)"
            if next.count > 48 { break }
            result = next
        }
        return result.isEmpty ? "Step \(fallbackIndex)" : result
    }

    private static func buildQuestions(from narration: String) -> [String] {
        let lowered = narration.lowercased()
        var questions = [
            "how do I \(lowered)",
            "what do I do for \(lowered)",
            lowered,
        ]
        if !lowered.hasPrefix("how") {
            questions.append("how do I \(lowered)")
        }
        var seen: Set<String> = []
        return questions.filter { question in
            let key = question.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }.prefix(4).map { $0 }
    }

    private struct MetadataPayload: Decodable {
        let goal: String
        let summary: String
        let triggerPhrases: [String]

        enum CodingKeys: String, CodingKey {
            case goal, summary
            case triggerPhrases = "trigger_phrases"
        }
    }

    private static func parseMetadataPayload(from raw: String) throws -> MetadataPayload {
        try parseJSON(from: raw)
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
            throw IndexerError.invalidJSON
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private enum IndexerError: Error {
        case invalidJSON
    }
}
