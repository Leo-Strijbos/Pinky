//
//  ClickyWorkflowModels.swift
//  leanring-buddy
//
//  Models for recorded workflow screen states.
//

import Foundation

enum ClickyWorkflowSource: String, Equatable, Codable {
    case recorded
    case pdf
}

struct ClickyWorkflow: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var summary: String
    var goal: String
    var triggerPhrases: [String]
    let recordedAt: Date
    var stateCount: Int
    var source: ClickyWorkflowSource
    var sourceDocumentID: String?

    init(
        id: String,
        name: String,
        summary: String,
        goal: String,
        triggerPhrases: [String],
        recordedAt: Date,
        stateCount: Int,
        source: ClickyWorkflowSource = .recorded,
        sourceDocumentID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.goal = goal
        self.triggerPhrases = triggerPhrases
        self.recordedAt = recordedAt
        self.stateCount = stateCount
        self.source = source
        self.sourceDocumentID = sourceDocumentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        goal = try container.decode(String.self, forKey: .goal)
        triggerPhrases = try container.decode([String].self, forKey: .triggerPhrases)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        stateCount = try container.decode(Int.self, forKey: .stateCount)
        source = try container.decodeIfPresent(ClickyWorkflowSource.self, forKey: .source) ?? .recorded
        sourceDocumentID = try container.decodeIfPresent(String.self, forKey: .sourceDocumentID)
    }
}

struct ClickyWorkflowScreenState: Identifiable, Equatable, Codable {
    let id: String
    let workflowID: String
    let stepIndex: Int
    var name: String
    var app: String
    var urlPattern: String?
    var windowTitlePattern: String?
    var meaning: String
    var userIntent: String
    var spokenDescription: String
    var isEntryState: Bool
    var ocrTerms: [String]
    var commonQuestions: [String]
    var relatedSOPIDs: [String]
    var visualFingerprint: String
    let thumbnailFilename: String
    let capturedAt: Date

    var thumbnailURL: URL {
        ClickyWorkflowPaths.thumbnailsDirectory.appendingPathComponent(thumbnailFilename)
    }

    var isCoreState: Bool {
        !isEntryState
    }
}

struct ClickyWorkflowRawSnapshot: Equatable {
    let imageData: Data
    let app: String
    let url: String?
    let windowTitle: String?
    let capturedAt: Date
    let visualFingerprint: String
    var spokenDescription: String
    var isEntryState: Bool
}

struct ClickyWorkflowScreenContext: Equatable {
    let app: String
    let url: String?
    let windowTitle: String?
    let ocrTerms: [String]
    let visualFingerprint: String?
}

struct ClickyWorkflowMatch: Equatable {
    let state: ClickyWorkflowScreenState
    let workflow: ClickyWorkflow
    let confidence: Double
    let matchReason: String
    let upcomingSteps: [ClickyWorkflowScreenState]

    func promptFragment() -> String {
        let sourceLabel = workflow.source == .pdf ? "uploaded procedure" : "recorded workflow"
        var lines = [
            "matched \(sourceLabel) (confidence \(Int(confidence * 100))%, via \(matchReason)):",
            "procedure: \(workflow.name)",
            "current step \(state.stepIndex + 1) of \(workflow.stateCount): \(state.name)",
        ]

        let stepText = !state.spokenDescription.isEmpty ? state.spokenDescription : state.meaning
        if !stepText.isEmpty {
            lines.append("instruction: \(stepText)")
        }

        if !upcomingSteps.isEmpty {
            lines.append("next:")
            for step in upcomingSteps.prefix(2) {
                let preview = !step.spokenDescription.isEmpty ? step.spokenDescription : step.meaning
                lines.append("  step \(step.stepIndex + 1): \(step.name) — \(preview)")
            }
        }

        lines.append("guide the user from the current step. point at on-screen UI when helpful.")
        return lines.joined(separator: "\n")
    }
}

struct ClickyWorkflowRetrieval: Equatable {
    let workflow: ClickyWorkflow
    let steps: [ClickyWorkflowScreenState]
    let relevanceScore: Double

    func narrowPromptFragment() -> String {
        let sourceLabel = workflow.source == .pdf ? "uploaded procedure" : "recorded workflow"
        var lines = [
            "matched \(sourceLabel) by question (relevance \(Int(relevanceScore * 100))%):",
            "procedure: \(workflow.name)",
        ]

        if !workflow.goal.isEmpty {
            lines.append("goal: \(workflow.goal)")
        }

        let orderedSteps = steps.sorted { $0.stepIndex < $1.stepIndex }
        let coreSteps = orderedSteps.filter(\.isCoreState)
        let stepsToShow = coreSteps.isEmpty ? orderedSteps : coreSteps

        if let first = stepsToShow.first {
            let instruction = !first.spokenDescription.isEmpty ? first.spokenDescription : first.meaning
            lines.append("start at step \(first.stepIndex + 1): \(first.name) — \(instruction)")
        }

        if stepsToShow.count > 1, let second = stepsToShow.dropFirst().first {
            let instruction = !second.spokenDescription.isEmpty ? second.spokenDescription : second.meaning
            lines.append("then step \(second.stepIndex + 1): \(second.name) — \(instruction)")
        }

        lines.append("the user may not be on the matching screen yet — begin from step 1 unless they say otherwise.")
        return lines.joined(separator: "\n")
    }
}

struct ClickyWorkflowContextResult: Equatable {
    let retrieval: ClickyWorkflowRetrieval?
    let screenMatch: ClickyWorkflowMatch?

    var hasProcedureContext: Bool {
        retrieval != nil || screenMatch != nil
    }

    func promptAppendix() -> String {
        if let screenMatch {
            return screenMatch.promptFragment()
        }
        if let retrieval {
            return retrieval.narrowPromptFragment()
        }
        return ""
    }
}

enum ClickyWorkflowPaths {
    static var applicationSupportDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("Clicky", isDirectory: true)
    }

    static var workflowRootDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("workflows", isDirectory: true)
    }

    static var thumbnailsDirectory: URL {
        workflowRootDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    }

    static var catalogURL: URL {
        workflowRootDirectory.appendingPathComponent("catalog.json")
    }

    static var databaseURL: URL {
        workflowRootDirectory.appendingPathComponent("workflows.sqlite")
    }

    /// Removes all on-disk screenshot files for a workflow, matched by ID prefix.
    static func deleteAssets(forWorkflowID workflowID: String) {
        let fileManager = FileManager.default
        let prefix = "\(workflowID)-"

        if let thumbnailFiles = try? fileManager.contentsOfDirectory(
            at: thumbnailsDirectory,
            includingPropertiesForKeys: nil
        ) {
            for fileURL in thumbnailFiles where fileURL.lastPathComponent.hasPrefix(prefix) {
                removeFile(at: fileURL)
            }
        }

        let workflowDirectory = workflowRootDirectory.appendingPathComponent(workflowID, isDirectory: true)
        if fileManager.fileExists(atPath: workflowDirectory.path) {
            removeFile(at: workflowDirectory)
        }
    }

    private static func removeFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            print("🎬 Deleted workflow asset: \(url.lastPathComponent)")
        } catch {
            print("⚠️ Could not delete workflow asset \(url.path): \(error.localizedDescription)")
        }
    }

    static func removeWorkflowAsset(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        removeFile(at: url)
    }
}

enum ClickyWorkflowPatternMatcher {
    static func matches(_ pattern: String?, value: String?) -> Bool {
        guard let pattern, !pattern.isEmpty, let value, !value.isEmpty else {
            return false
        }

        let normalizedPattern = pattern.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedPattern.contains("*") {
            let escaped = NSRegularExpression.escapedPattern(for: normalizedPattern)
                .replacingOccurrences(of: "\\*", with: ".*")
            guard let regex = try? NSRegularExpression(pattern: "^\(escaped)$", options: .caseInsensitive) else {
                return false
            }
            let range = NSRange(normalizedValue.startIndex..<normalizedValue.endIndex, in: normalizedValue)
            return regex.firstMatch(in: normalizedValue, range: range) != nil
        }

        return normalizedValue.contains(normalizedPattern)
    }

    /// Broad host-only pattern for matching — ignores query strings and deep paths.
    static func urlPattern(from rawURL: String?) -> String? {
        guard
            let rawURL,
            !rawURL.isEmpty,
            let url = URL(string: rawURL),
            let host = url.host?.lowercased()
        else {
            return nil
        }

        let pathComponents = url.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard let firstSegment = pathComponents.first else {
            return "\(host)*"
        }

        return "\(host)/\(firstSegment)*"
    }

    /// Stable window title substring for matching — strips app suffix noise.
    static func windowTitlePattern(from raw: String?, app: String) -> String? {
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
