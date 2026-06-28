//
//  PlaybookRecorder.swift
//  leanring-buddy
//
//  Simplified procedure recording — app/url + narration per step, no per-step AI.
//

import Foundation

@MainActor
final class PlaybookRecorder {
    private var pollTask: Task<Void, Never>?
    private var snapshots: [RecordedSnapshot] = []
    private var lastSignature: String?
    private var lastCaptureAt: Date?
    private let pollIntervalNanoseconds: UInt64 = 1_500_000_000
    private let minimumCaptureGapNanoseconds: UInt64 = 2_000_000_000

    struct RecordedSnapshot: Equatable {
        let app: String
        let url: String?
        let windowTitle: String?
        let thumbnailFilename: String?
        let capturedAt: Date
        var narration: String
    }

    var snapshotCount: Int { snapshots.count }
    var isActive: Bool { pollTask != nil }

    func start() {
        guard pollTask == nil else { return }
        snapshots = []
        lastSignature = nil
        lastCaptureAt = nil

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureIfNeeded()
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanoseconds ?? 1_500_000_000)
            }
        }

        print("📘 Playbook recording started")
    }

    func stop() -> [RecordedSnapshot] {
        pollTask?.cancel()
        pollTask = nil
        let captured = snapshots
        snapshots = []
        lastSignature = nil
        lastCaptureAt = nil
        print("📘 Playbook recording stopped (\(captured.count) steps)")
        return captured
    }

    func attachNarration(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !snapshots.isEmpty else { return }

        let index = snapshots.count - 1
        if snapshots[index].narration.isEmpty {
            snapshots[index].narration = trimmed
        } else {
            snapshots[index].narration += " \(trimmed)"
        }
    }

    func resetFromHere() async {
        snapshots.removeAll()
        lastSignature = nil
        lastCaptureAt = nil
        await captureIfNeeded(force: true)
    }

    private func captureIfNeeded(force: Bool = false) async {
        let context = PlaybookScreenContextCapture.captureCurrentContext()
        let signature = [
            context.app.lowercased(),
            context.url?.lowercased() ?? "",
            context.windowTitle?.lowercased() ?? "",
        ].joined(separator: "|")

        let now = Date()
        if !force, signature == lastSignature { return }
        if !force,
           let lastCaptureAt,
           now.timeIntervalSince(lastCaptureAt) < Double(minimumCaptureGapNanoseconds) / 1_000_000_000 {
            return
        }

        lastSignature = signature
        lastCaptureAt = now

        snapshots.append(
            RecordedSnapshot(
                app: context.app,
                url: context.url,
                windowTitle: context.windowTitle,
                thumbnailFilename: nil,
                capturedAt: now,
                narration: ""
            )
        )
    }
}

enum PlaybookRecordingBuilder {

    static func buildPlaybook(
        from snapshots: [PlaybookRecorder.RecordedSnapshot],
        title: String,
        claudeAPI: ClaudeAPI
    ) async throws -> (Playbook, [PlaybookStep]) {
        guard !snapshots.isEmpty else {
            throw NSError(domain: "PlaybookRecordingBuilder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No steps were recorded.",
            ])
        }

        let playbookID = UUID().uuidString.lowercased()
        let now = Date()

        let steps = snapshots.enumerated().map { index, snapshot in
            let narration = snapshot.narration.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleText = narration.isEmpty ? "Step \(index + 1)" : firstSentence(from: narration)
            let instruction = narration.isEmpty ? "Complete this step in \(snapshot.app)." : narration

            return PlaybookStep(
                id: "\(playbookID)-step-\(index + 1)",
                playbookID: playbookID,
                index: index,
                title: titleText,
                instruction: instruction,
                contextApp: snapshot.app,
                contextURLPattern: PlaybookContextMatcher.urlPattern(from: snapshot.url),
                contextWindowPattern: windowPattern(from: snapshot.windowTitle, app: snapshot.app),
                lookFor: titleText,
                doneWhen: nil,
                thumbnailFilename: snapshot.thumbnailFilename,
                capturedAt: snapshot.capturedAt
            )
        }

        let metadata = try await buildMetadata(title: title, steps: steps, claudeAPI: claudeAPI)

        let docBlocks: [PlaybookDocBlock] = [
            PlaybookDocBlock(kind: .hero, title: title, body: metadata.summary),
            PlaybookDocBlock(kind: .heading, title: "Steps"),
            PlaybookDocBlock(
                kind: .steps,
                items: steps.map { "\($0.title): \($0.instruction)" }
            ),
        ]

        let playbook = Playbook(
            id: playbookID,
            title: title,
            summary: metadata.summary,
            tags: metadata.tags,
            kind: .procedure,
            source: .recorded,
            sourceFilename: nil,
            stepCount: steps.count,
            triggerPhrases: metadata.triggerPhrases,
            docBlocks: docBlocks,
            createdAt: now,
            updatedAt: now
        )

        return (playbook, steps)
    }

    private struct MetadataPayload: Decodable {
        let summary: String
        let tags: [String]
        let triggerPhrases: [String]

        enum CodingKeys: String, CodingKey {
            case summary, tags
            case triggerPhrases = "trigger_phrases"
        }
    }

    private static func buildMetadata(
        title: String,
        steps: [PlaybookStep],
        claudeAPI: ClaudeAPI
    ) async throws -> MetadataPayload {
        let stepList = steps.map { "\($0.index + 1). \($0.title): \($0.instruction)" }.joined(separator: "\n")
        let prompt = """
        Summarize this recorded company procedure.
        Reply with ONLY JSON: {"summary":"one sentence","tags":["tag1"],"trigger_phrases":["voice phrase"]}

        Title: \(title)
        Steps:
        \(stepList)
        """

        let raw = try await claudeAPI.sendVoiceRouteClassification(
            systemPrompt: "Reply with ONLY valid JSON.",
            userPrompt: prompt,
            model: "claude-haiku-4-5"
        )

        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard
            let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            let data = String(text[start...end]).data(using: .utf8)
        else {
            return MetadataPayload(summary: "Recorded procedure with \(steps.count) steps.", tags: [], triggerPhrases: [])
        }

        if let decoded = try? JSONDecoder().decode(MetadataPayload.self, from: data) {
            return decoded
        }
        return MetadataPayload(
            summary: "Recorded procedure with \(steps.count) steps.",
            tags: ["procedure"],
            triggerPhrases: ["walk me through \(title.lowercased())"]
        )
    }

    private static func firstSentence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = trimmed.firstIndex(of: ".") {
            return String(trimmed[..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.count > 48 {
            return String(trimmed.prefix(48)) + "…"
        }
        return trimmed
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
