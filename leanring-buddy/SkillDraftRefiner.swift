//
//  SkillDraftRefiner.swift
//  leanring-buddy
//
//  Collapses noisy teaching capture into readable Agent Skill steps.
//

import Foundation

enum SkillDraftRefiner {

    private struct RefinedStepPayload: Decodable {
        let title: String
        let instruction: String
        let lookFor: String?
        let doneWhen: String?
        let sourceIndices: [Int]

        enum CodingKeys: String, CodingKey {
            case title, instruction
            case lookFor = "look_for"
            case doneWhen = "done_when"
            case sourceIndices = "source_indices"
        }
    }

    private struct RefinementPayload: Decodable {
        let steps: [RefinedStepPayload]
        let summary: String?
    }

    static func refine(
        draft: SkillDraft,
        artifact: TeachingArtifact,
        claudeAPI: ClaudeAPI
    ) async -> SkillDraft {
        guard draft.steps.count > 1 else { return draft }

        if let refined = await refineWithLLM(draft: draft, claudeAPI: claudeAPI) {
            return refined
        }

        return refineLocally(draft: draft)
    }

    // MARK: - LLM

    private static func refineWithLLM(
        draft: SkillDraft,
        claudeAPI: ClaudeAPI
    ) async -> SkillDraft? {
        let rawSteps = draft.steps.enumerated().map { index, step in
            let url = step.context.url ?? "none"
            let narration = step.narration.isEmpty ? "none" : step.narration
            return """
            \(index + 1). title=\(step.title)
               instruction=\(step.instruction)
               app=\(step.context.app) url=\(url)
               narration=\(narration)
            """
        }.joined(separator: "\n")

        let prompt = """
        Clean this recorded macOS workflow into an Agent Skill that another LLM can follow.

        Raw capture includes screenshot OCR noise, duplicate frames, and spoken teaching preamble.
        Produce 3-8 clear, imperative steps. Merge duplicates. Drop meta-narration ("I'm going to teach you", "okay clicky").

        Rules:
        - instruction: one actionable sentence ("Go to…", "Search for…", "Add … to basket")
        - title: short milestone name (3-6 words)
        - look_for: one UI label when obvious, else null
        - done_when: observable completion when clear, else null
        - source_indices: 1-based indices of raw steps this consolidates (at least one each)
        - Never copy OCR garbage tokens into instructions

        Raw steps:
        \(rawSteps)

        Reply with ONLY JSON:
        {"summary":"optional one-line summary","steps":[{"title":"…","instruction":"…","look_for":"…","done_when":"…","source_indices":[1,2]}]}
        """

        do {
            let raw = try await claudeAPI.sendVoiceRouteClassification(
                systemPrompt: "Reply with ONLY valid JSON.",
                userPrompt: prompt,
                model: "claude-haiku-4-5"
            )
            guard let payload = parsePayload(from: raw), !payload.steps.isEmpty else {
                return nil
            }
            return apply(payload, to: draft)
        } catch {
            print("⚠️ Skill draft refinement failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func parsePayload(from raw: String) -> RefinementPayload? {
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
            return nil
        }

        return try? JSONDecoder().decode(RefinementPayload.self, from: data)
    }

    private static func apply(_ payload: RefinementPayload, to draft: SkillDraft) -> SkillDraft {
        let refinedSteps = payload.steps.compactMap { refined -> SkillDraftStep? in
            let sourceSteps = refined.sourceIndices.compactMap { index -> SkillDraftStep? in
                guard index >= 1, index <= draft.steps.count else { return nil }
                return draft.steps[index - 1]
            }
            guard let anchor = sourceSteps.first else { return nil }

            let instruction = refined.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return nil }

            let title = refined.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let lookFor = refined.lookFor?.trimmingCharacters(in: .whitespacesAndNewlines)
            let doneWhen = refined.doneWhen?.trimmingCharacters(in: .whitespacesAndNewlines)

            return SkillDraftStep(
                title: title.isEmpty ? TeachingStepSynthesizer.stepTitle(from: instruction) : title,
                instruction: instruction,
                lookFor: lookFor?.isEmpty == false ? lookFor : nil,
                doneWhen: doneWhen?.isEmpty == false ? doneWhen : nil,
                context: sourceSteps.last?.context ?? anchor.context,
                keyframeID: sourceSteps.compactMap(\.keyframeID).first,
                narration: sourceSteps.map(\.narration).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard !refinedSteps.isEmpty else { return draft }

        let summary = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillDraft(
            suggestedName: draft.suggestedName,
            suggestedTitle: draft.suggestedTitle,
            summary: summary?.isEmpty == false ? summary! : draft.summary,
            tags: draft.tags,
            triggerPhrases: draft.triggerPhrases,
            steps: refinedSteps
        )
    }

    // MARK: - Local fallback

    private static func refineLocally(draft: SkillDraft) -> SkillDraft {
        var groups: [[SkillDraftStep]] = []
        var current: [SkillDraftStep] = []

        for step in draft.steps {
            let signature = localGroupSignature(for: step)
            if let last = current.last, localGroupSignature(for: last) != signature || !step.narration.isEmpty {
                groups.append(current)
                current = [step]
            } else if current.isEmpty {
                current = [step]
            } else {
                current.append(step)
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }

        let refinedSteps = groups.compactMap { group -> SkillDraftStep? in
            mergeGroup(group)
        }

        guard refinedSteps.count < draft.steps.count else { return draft }

        return SkillDraft(
            suggestedName: draft.suggestedName,
            suggestedTitle: draft.suggestedTitle,
            summary: draft.summary,
            tags: draft.tags,
            triggerPhrases: draft.triggerPhrases,
            steps: refinedSteps
        )
    }

    private static func localGroupSignature(for step: SkillDraftStep) -> String {
        if !step.narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "n|\(TeachingStepSynthesizer.cleanNarration(step.narration))"
        }
        return "c|\(TeachingStepSynthesizer.urlPathSignature(step.context.url) ?? step.context.signature)"
    }

    private static func mergeGroup(_ group: [SkillDraftStep]) -> SkillDraftStep? {
        guard let first = group.first else { return nil }

        if group.count == 1 {
            return first
        }

        let narrated = group.first { !$0.narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let narrated {
            let cleaned = TeachingStepSynthesizer.cleanNarration(narrated.narration)
            if !cleaned.isEmpty {
                return SkillDraftStep(
                    title: TeachingStepSynthesizer.stepTitle(from: cleaned),
                    instruction: cleaned,
                    lookFor: narrated.lookFor,
                    doneWhen: narrated.doneWhen,
                    context: group.last?.context ?? narrated.context,
                    keyframeID: group.compactMap(\.keyframeID).first,
                    narration: cleaned
                )
            }
        }

        return SkillDraftStep(
            title: first.title,
            instruction: first.instruction,
            lookFor: first.lookFor,
            doneWhen: first.doneWhen,
            context: group.last?.context ?? first.context,
            keyframeID: group.compactMap(\.keyframeID).first,
            narration: ""
        )
    }
}

private extension ScreenContext {
    var signature: String {
        [
            app.lowercased(),
            url?.lowercased() ?? "",
            windowTitle?.lowercased() ?? "",
        ].joined(separator: "|")
    }
}
