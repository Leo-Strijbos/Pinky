//
//  CompanionAgentActionSpeech.swift
//  leanring-buddy
//
//  Generates natural spoken summaries when the model acts without text.
//

import Foundation

struct CompanionExecutedAction: Equatable {
    let capabilityName: String
    let resultContent: String
    let pointLabel: String?
}

enum CompanionAgentActionSpeech {

    private static let syntheticFallbackPhrases = [
        "i couldn't find a clear answer",
        "i couldn't complete that action",
    ]

    static func isSyntheticFallback(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return syntheticFallbackPhrases.contains { normalized.contains($0) }
    }

    static func isObserveCapability(_ name: String) -> Bool {
        name == "read_pdf" || name == "read_file"
    }

    static func spokenSummary(for actions: [CompanionExecutedAction]) -> String? {
        let actActions = actions.filter { !isObserveCapability($0.capabilityName) }
        guard !actActions.isEmpty else { return nil }

        var phrases: [String] = []
        for action in actActions {
            guard let phrase = phrase(for: action) else { continue }
            if !phrases.contains(phrase) {
                phrases.append(phrase)
            }
        }

        guard !phrases.isEmpty else { return nil }
        return phrases.prefix(2).joined(separator: " ")
    }

    static func resolveSpokenText(
        modelText: String,
        executedActions: [CompanionExecutedAction],
        effects: CompanionTurnEffects
    ) -> String {
        let trimmed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !isSyntheticFallback(trimmed) {
            return trimmed
        }

        if let actionSpeech = spokenSummary(for: executedActions) {
            return actionSpeech
        }

        if effects.pointTarget != nil {
            if let label = effects.pointTarget?.label, !label.isEmpty, label.lowercased() != "element" {
                return "right here — \(label)"
            }
            return "right here"
        }

        if effects.panelPayload != nil {
            return "pulling that up for you"
        }

        if effects.copyableContent != nil {
            return "i'm pulling that up in a new window for you to copy"
        }

        return ""
    }

    private static func phrase(for action: CompanionExecutedAction) -> String? {
        switch action.capabilityName {
        case "open_url":
            return spokenOpenURL(from: action.resultContent)

        case "open_app":
            let content = action.resultContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.lowercased().hasPrefix("opening"), !content.lowercased().contains("couldn't") {
                return content
            }
            return "opening that app"

        case "point_at_element":
            if let label = action.pointLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty,
               label.lowercased() != "element" {
                return "right here — \(label)"
            }
            return "right here"

        case "show_panel":
            return "pulling that up for you"

        case "present_document":
            let content = action.resultContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.lowercased().hasPrefix("opened"), !content.isEmpty {
                return content
            }
            return "opening the document"

        case "present_copyable_content":
            return "i'm pulling that up in a new window for you to copy"

        case "read_pdf", "read_file":
            return nil

        default:
            return nil
        }
    }

    private static func spokenOpenURL(from resultContent: String) -> String? {
        let content = resultContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !content.lowercased().contains("couldn't") else { return nil }
        if content.lowercased().hasPrefix("opening") {
            return content
        }
        return "opening that page"
    }
}
