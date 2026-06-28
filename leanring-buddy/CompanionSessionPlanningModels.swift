//
//  CompanionSessionPlanningModels.swift
//  leanring-buddy
//
//  Types for multi-phase session planning, topology, and clarifications.
//

import Foundation

enum CompanionSessionTaskArchetype: String, Equatable, Codable {
    case inAppSettings
    case crossAppAutomation
    case installSetup
    case contentCreation
    case general
}

struct CompanionSessionTaskHints: Equatable {
    let archetype: CompanionSessionTaskArchetype
    let suggestWebSearch: Bool
    let preferStrongerModel: Bool
}

struct CompanionSessionPlanningQuestion: Equatable {
    let question: String
    let defaultAssumption: String?
}

struct CompanionSessionTopology: Equatable {
    let title: String
    let taskType: String
    let recommendedApproach: String?
    let assumptions: [String]
    let orderedPhases: [String]
    let orchestrator: String?
    let avoidFirst: [String]
    let notes: String?
}

struct CompanionSessionPlanningClarification: Equatable {
    let originalTranscript: String
    let spokenPrompt: String
    let questions: [CompanionSessionPlanningQuestion]
    let recommendedApproach: String?
    let partialTopology: CompanionSessionTopology?
    let clarificationRound: Int
}

enum CompanionSessionPlanningResult: Equatable {
    case plan(CompanionSessionPlan)
    case needsClarification(CompanionSessionPlanningClarification)
}

enum CompanionSessionPlanningBriefFormatter {

    static func spokenPrompt(
        questions: [CompanionSessionPlanningQuestion],
        recommendedApproach: String?
    ) -> String {
        guard !questions.isEmpty else {
            return recommendedApproach ?? "before we start, can you share a bit more detail?"
        }

        var parts: [String] = []

        if let recommendedApproach, !recommendedApproach.isEmpty {
            parts.append(recommendedApproach)
        }

        if questions.count == 1, let only = questions.first {
            parts.append(only.question)
            if let assumption = only.defaultAssumption, !assumption.isEmpty {
                parts.append("if you'd rather not decide, i'll assume \(assumption).")
            }
            return parts.joined(separator: " ")
        }

        parts.append("quick questions before we start.")
        for (index, question) in questions.enumerated() {
            parts.append(question.question)
            if index == questions.count - 1,
               questions.contains(where: { ($0.defaultAssumption ?? "").isEmpty == false }) {
                let defaults = questions.compactMap(\.defaultAssumption).joined(separator: ", ")
                if !defaults.isEmpty {
                    parts.append("or say go ahead and i'll use \(defaults).")
                }
            }
        }

        return parts.joined(separator: " ")
    }

    static func isProceedWithDefaults(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let phrases = [
            "go ahead", "just do it", "use the default", "use your best guess",
            "whatever you think", "your call", "sounds good", "that works",
            "sure", "yes", "yep", "ok", "okay", "fine", "proceed",
        ]

        return phrases.contains { normalized == $0 || normalized.hasPrefix("\($0) ") }
    }

    static func shouldRetryFailedPlanning(_ transcript: String) -> Bool {
        if isProceedWithDefaults(transcript) {
            return true
        }

        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let phrases = [
            "please do that", "do that", "yeah please", "yes please",
            "show me what to do", "what do i do now", "what should i do now",
            "walk me through it", "guide me through", "let's do it", "lets do it",
            "start the walkthrough", "start walkthrough",
        ]

        return phrases.contains { normalized.contains($0) }
    }

    static func defaultAnswers(from questions: [CompanionSessionPlanningQuestion]) -> String {
        questions.enumerated().map { index, question in
            let answer = question.defaultAssumption ?? "no preference"
            return "question \(index + 1): \(question.question) → \(answer)"
        }.joined(separator: "\n")
    }

    static func shouldAbandonPendingClarification(
        _ transcript: String,
        pending: CompanionSessionPlanningClarification
    ) -> Bool {
        if ClickyVoiceLocalAppActionParser.parse(transcript: transcript) != nil {
            return true
        }

        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let offTopicPhrases = [
            "weather", "who are you", "what time", "play music", "open spotify",
            "tell me a joke", "what's the news", "whats the news",
        ]
        if offTopicPhrases.contains(where: { normalized.contains($0) }) {
            return true
        }

        guard ClickyProcedureQuery.isStepByStepIntent(transcript) else {
            return false
        }

        let pendingTokens = meaningfulTokens(from: pending.originalTranscript)
        let queryTokens = meaningfulTokens(from: transcript)
        let overlap = pendingTokens.intersection(queryTokens)
        return overlap.count < 2
    }

    private static func meaningfulTokens(from text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "the", "to", "on", "in", "at", "for", "of", "and", "or", "then",
            "how", "what", "where", "when", "why", "walk", "through", "step", "show",
            "i", "me", "my", "it", "this", "that", "do", "did", "please", "clicky",
        ]

        return Set(
            text
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }
}
