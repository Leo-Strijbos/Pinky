//
//  TeachingInterpreter.swift
//  leanring-buddy
//
//  Pluggable interpreters that turn TeachingArtifacts into SkillDrafts.
//

import Foundation

protocol TeachingInterpreter {
    func buildDraft(from artifact: TeachingArtifact, claudeAPI: ClaudeAPI) async throws -> SkillDraft
}

// MARK: - Default interpreter

struct NarrationPrimaryTeachingInterpreter: TeachingInterpreter {

    func buildDraft(from artifact: TeachingArtifact, claudeAPI: ClaudeAPI) async throws -> SkillDraft {
        guard !artifact.keyframes.isEmpty || !artifact.signals.isEmpty else {
            throw TeachingInterpreterError.emptyArtifact
        }

        let segments = TeachingSegmentBuilder.segments(from: artifact)
        guard !segments.isEmpty else {
            throw TeachingInterpreterError.emptyArtifact
        }

        let roughSteps = segments.map { segment in
            label(segment: segment, artifact: artifact)
        }

        let metadata = try await buildMetadata(
            steps: roughSteps,
            claudeAPI: claudeAPI
        )
        let suggestedTitle = resolveSuggestedTitle(
            metadata: metadata,
            steps: roughSteps,
            artifact: artifact
        )

        let suggestedName = SkillNameFormatter.kebabCase(from: suggestedTitle)

        let roughDraft = SkillDraft(
            suggestedName: suggestedName,
            suggestedTitle: suggestedTitle,
            summary: metadata.summary,
            tags: metadata.tags,
            triggerPhrases: metadata.triggerPhrases,
            steps: roughSteps
        )

        return await SkillDraftRefiner.refine(
            draft: roughDraft,
            artifact: artifact,
            claudeAPI: claudeAPI
        )
    }

    private func label(segment: TeachingSegment, artifact: TeachingArtifact) -> SkillDraftStep {
        let synthesized = TeachingStepSynthesizer.label(segment: segment, artifact: artifact)
        let narration = segment.narrations
            .map { TeachingStepSynthesizer.cleanNarration($0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let context = segment.context?.screenContext ?? ScreenContext(app: "Unknown", url: nil, windowTitle: nil)

        return SkillDraftStep(
            title: synthesized.title,
            instruction: synthesized.instruction,
            lookFor: synthesized.lookFor,
            doneWhen: synthesized.doneWhen,
            context: context,
            keyframeID: segment.keyframeID,
            narration: narration
        )
    }

    private func stepTitle(from narration: String) -> String {
        let trimmed = narration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Step" }
        if let dot = trimmed.firstIndex(of: ".") {
            return String(trimmed[..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.count <= 48 { return trimmed }
        return String(trimmed.prefix(48)) + "…"
    }

    private func defaultTitle(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Procedure \(formatter.string(from: date))"
    }

    private struct MetadataPayload: Decodable {
        let title: String?
        let summary: String
        let tags: [String]
        let triggerPhrases: [String]

        enum CodingKeys: String, CodingKey {
            case title, summary, tags
            case triggerPhrases = "trigger_phrases"
        }
    }

    private func resolveSuggestedTitle(
        metadata: MetadataPayload,
        steps: [SkillDraftStep],
        artifact: TeachingArtifact
    ) -> String {
        if let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        if let narratedTitle = steps
            .compactMap({ step -> String? in
                let narration = step.narration.trimmingCharacters(in: .whitespacesAndNewlines)
                return narration.isEmpty ? nil : stepTitle(from: narration)
            })
            .first,
           !narratedTitle.isEmpty {
            return narratedTitle
        }

        let appCounts = steps.reduce(into: [String: Int]()) { counts, step in
            let app = step.context.app.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty, app.lowercased() != "unknown" else { return }
            counts[app, default: 0] += 1
        }
        if let dominantApp = appCounts.max(by: { $0.value < $1.value })?.key {
            return "\(dominantApp) workflow"
        }

        return defaultTitle(from: artifact.startedAt)
    }

    private func buildMetadata(
        steps: [SkillDraftStep],
        claudeAPI: ClaudeAPI
    ) async throws -> MetadataPayload {
        let stepList = steps.enumerated().map { index, step in
            "\(index + 1). \(step.title): \(step.instruction)"
        }.joined(separator: "\n")

        let narrations = steps
            .filter { !$0.narration.isEmpty }
            .map { "step: \($0.narration)" }
            .joined(separator: "\n")

        let prompt = """
        Summarize this recorded macOS workflow the user just taught Pinky.
        Infer a short, specific title from what they actually did — not a generic date label.
        Reply with ONLY JSON: {"title":"short descriptive name","summary":"one sentence","tags":["tag1"],"trigger_phrases":["voice phrase"]}

        Steps:
        \(stepList)
        User narrations:
        \(narrations.isEmpty ? "none — infer the goal from app names, window titles, and on-screen hints in the steps" : narrations)
        """

        let raw = try await claudeAPI.sendVoiceRouteClassification(
            systemPrompt: "Reply with ONLY valid JSON.",
            userPrompt: prompt,
            model: "claude-haiku-4-5"
        )

        return parseMetadataPayload(from: raw) ?? MetadataPayload(
            title: nil,
            summary: "Recorded procedure with \(steps.count) steps.",
            tags: ["procedure"],
            triggerPhrases: ["walk me through this workflow", "teach me this workflow"]
        )
    }

    private func parseMetadataPayload(from raw: String) -> MetadataPayload? {
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

        return try? JSONDecoder().decode(MetadataPayload.self, from: data)
    }
}

enum TeachingInterpreterError: LocalizedError {
    case emptyArtifact

    var errorDescription: String? {
        switch self {
        case .emptyArtifact:
            return "No steps were captured during teaching."
        }
    }
}

// MARK: - Segmentation

struct TeachingSegment: Equatable {
    let startTime: Date
    let endTime: Date
    let context: ContextSnapshot?
    let narrations: [String]
    let clickCount: Int
    let keyframeID: String?
}

enum TeachingSegmentBuilder {

    static func segments(from artifact: TeachingArtifact) -> [TeachingSegment] {
        let milestones = segmentsFromMilestones(artifact)
        if !milestones.isEmpty {
            return attachKeyframes(to: milestones, artifact: artifact)
        }
        if artifact.keyframes.isEmpty {
            return segmentsFromSignalsOnly(artifact.signals)
        }
        return attachKeyframes(to: segmentsFromKeyframes(artifact), artifact: artifact)
    }

    private static func segmentsFromMilestones(_ artifact: TeachingArtifact) -> [TeachingSegment] {
        guard !artifact.signals.isEmpty else { return [] }

        struct Pending {
            var startTime: Date
            var endTime: Date
            var context: ContextSnapshot?
            var narrations: [String]
            var clickCount: Int
        }

        var segments: [TeachingSegment] = []
        var pending: Pending?
        var lastURLSignature: String?

        func flush(endTime: Date) {
            guard let current = pending else { return }

            let hasNarration = !current.narrations.isEmpty
            let hasClick = current.clickCount > 0
            let hasContext = current.context != nil

            guard hasNarration || hasClick || hasContext else { return }

            if !hasNarration,
               !hasClick,
               let last = segments.last,
               last.narrations.isEmpty,
               last.clickCount == 0,
               last.context?.signature == current.context?.signature {
                return
            }

            segments.append(
                TeachingSegment(
                    startTime: current.startTime,
                    endTime: endTime,
                    context: current.context,
                    narrations: current.narrations,
                    clickCount: current.clickCount,
                    keyframeID: nil
                )
            )
            pending = nil
        }

        for entry in artifact.signals {
            switch entry.signal {
            case .speech(let transcript):
                flush(endTime: entry.timestamp)
                pending = Pending(
                    startTime: entry.timestamp,
                    endTime: entry.timestamp,
                    context: pending?.context,
                    narrations: [transcript.text],
                    clickCount: 0
                )

            case .pointer(let event) where event.kind == .click:
                if pending == nil {
                    pending = Pending(
                        startTime: entry.timestamp,
                        endTime: entry.timestamp,
                        context: nil,
                        narrations: [],
                        clickCount: 1
                    )
                } else {
                    pending?.clickCount += 1
                    pending?.endTime = entry.timestamp
                }
                flush(endTime: entry.timestamp)

            case .context(let context):
                let urlSignature = TeachingStepSynthesizer.urlPathSignature(context.url)
                let contextChanged = context.signature != pending?.context?.signature
                let urlChanged = urlSignature != lastURLSignature

                if urlChanged || (contextChanged && pending?.narrations.isEmpty != false) {
                    flush(endTime: entry.timestamp)
                    pending = Pending(
                        startTime: entry.timestamp,
                        endTime: entry.timestamp,
                        context: context,
                        narrations: [],
                        clickCount: 0
                    )
                    lastURLSignature = urlSignature
                } else if pending == nil {
                    pending = Pending(
                        startTime: entry.timestamp,
                        endTime: entry.timestamp,
                        context: context,
                        narrations: [],
                        clickCount: 0
                    )
                    lastURLSignature = urlSignature
                } else {
                    pending?.context = context
                    pending?.endTime = entry.timestamp
                    lastURLSignature = urlSignature ?? lastURLSignature
                }

            case .frame, .pointer:
                break
            }
        }

        flush(endTime: artifact.finishedAt)
        return segments
    }

    private static func attachKeyframes(
        to segments: [TeachingSegment],
        artifact: TeachingArtifact
    ) -> [TeachingSegment] {
        guard !artifact.keyframes.isEmpty else { return segments }

        return segments.map { segment in
            guard segment.keyframeID == nil else { return segment }

            let keyframe = artifact.keyframes.first {
                $0.timestamp >= segment.startTime && $0.timestamp <= segment.endTime.addingTimeInterval(1.5)
            } ?? artifact.keyframes.first {
                $0.timestamp >= segment.startTime
            }

            return TeachingSegment(
                startTime: segment.startTime,
                endTime: segment.endTime,
                context: segment.context,
                narrations: segment.narrations,
                clickCount: segment.clickCount,
                keyframeID: keyframe?.id
            )
        }
    }

    private static func segmentsFromKeyframes(_ artifact: TeachingArtifact) -> [TeachingSegment] {
        var segments: [TeachingSegment] = []

        for (index, keyframe) in artifact.keyframes.enumerated() {
            let nextTimestamp = artifact.keyframes[safe: index + 1]?.timestamp ?? artifact.finishedAt
            let windowSignals = artifact.signals.filter {
                $0.timestamp >= keyframe.timestamp && $0.timestamp < nextTimestamp
            }

            let narrations = windowSignals.compactMap { entry -> String? in
                guard case .speech(let segment) = entry.signal else { return nil }
                return segment.text
            }

            let clickCount = windowSignals.reduce(into: 0) { count, entry in
                if case .pointer(let event) = entry.signal, event.kind == .click {
                    count += 1
                }
            }

            segments.append(
                TeachingSegment(
                    startTime: keyframe.timestamp,
                    endTime: nextTimestamp,
                    context: keyframe.context,
                    narrations: narrations,
                    clickCount: clickCount,
                    keyframeID: keyframe.id
                )
            )
        }

        return mergeAdjacentSilentSegments(segments)
    }

    private static func segmentsFromSignalsOnly(_ signals: [TimestampedSignal]) -> [TeachingSegment] {
        guard !signals.isEmpty else { return [] }

        var segments: [TeachingSegment] = []
        var currentContext: ContextSnapshot?
        var currentNarrations: [String] = []
        var currentClicks = 0
        var segmentStart = signals[0].timestamp

        func flush(endTime: Date) {
            guard currentContext != nil || !currentNarrations.isEmpty || currentClicks > 0 else { return }
            segments.append(
                TeachingSegment(
                    startTime: segmentStart,
                    endTime: endTime,
                    context: currentContext,
                    narrations: currentNarrations,
                    clickCount: currentClicks,
                    keyframeID: nil
                )
            )
            currentNarrations = []
            currentClicks = 0
        }

        for entry in signals {
            switch entry.signal {
            case .context(let context):
                if context.signature != currentContext?.signature {
                    flush(endTime: entry.timestamp)
                    segmentStart = entry.timestamp
                    currentContext = context
                }
            case .speech(let transcript):
                currentNarrations.append(transcript.text)
            case .pointer(let event) where event.kind == .click:
                currentClicks += 1
                flush(endTime: entry.timestamp)
                segmentStart = entry.timestamp
            case .frame, .pointer:
                break
            }
        }

        flush(endTime: signals.last?.timestamp ?? Date())
        return segments
    }

    private static func mergeAdjacentSilentSegments(_ segments: [TeachingSegment]) -> [TeachingSegment] {
        guard segments.count > 1 else { return segments }

        var merged: [TeachingSegment] = []

        for segment in segments {
            let isSilent = segment.narrations.isEmpty && segment.clickCount == 0
            if isSilent,
               var last = merged.popLast(),
               last.narrations.isEmpty,
               last.clickCount == 0,
               last.context?.signature == segment.context?.signature {
                last = TeachingSegment(
                    startTime: last.startTime,
                    endTime: segment.endTime,
                    context: last.context ?? segment.context,
                    narrations: [],
                    clickCount: 0,
                    keyframeID: last.keyframeID ?? segment.keyframeID
                )
                merged.append(last)
            } else {
                merged.append(segment)
            }
        }

        return merged
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
