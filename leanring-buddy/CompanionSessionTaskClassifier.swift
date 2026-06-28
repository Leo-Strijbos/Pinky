//
//  CompanionSessionTaskClassifier.swift
//  leanring-buddy
//
//  Lightweight heuristics for session planning task archetypes.
//

import Foundation

enum CompanionSessionTaskClassifier {

    static func hints(for transcript: String) -> CompanionSessionTaskHints {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let archetype = classifyArchetype(normalized)
        let suggestWebSearch = shouldSuggestWebSearch(normalized, archetype: archetype)
        let preferStrongerModel = archetype == .crossAppAutomation

        return CompanionSessionTaskHints(
            archetype: archetype,
            suggestWebSearch: suggestWebSearch,
            preferStrongerModel: preferStrongerModel
        )
    }

    private static func classifyArchetype(_ normalized: String) -> CompanionSessionTaskArchetype {
        if matchesAutomation(normalized) {
            return .crossAppAutomation
        }

        if matchesInstallSetup(normalized) {
            return .installSetup
        }

        if matchesContentCreation(normalized) {
            return .contentCreation
        }

        if matchesInAppSettings(normalized) {
            return .inAppSettings
        }

        return .general
    }

    private static func matchesAutomation(_ normalized: String) -> Bool {
        let automationSignals = [
            "automation", "automate", "zapier", "make.com", " integromat", "n8n",
            "ifttt", "shortcut", "workflow", "when ", "whenever ", "trigger",
            "sync ", "syncs ", "syncing", "webhook", "integrate", "integration",
            "connect ", "connects ", "pipe ", "piping",
        ]

        let crossAppSignals = [
            "from gmail", "to spreadsheet", "to google sheets", "to airtable",
            "to notion", "to slack", "from slack", "from calendar", "to calendar",
            "incoming email", "new email", "add a row", "add to sheet",
        ]

        let hasAutomation = automationSignals.contains { normalized.contains($0) }
        let hasCrossApp = crossAppSignals.contains { normalized.contains($0) }
        let mentionsMultipleServices = countServiceMentions(normalized) >= 2

        return hasAutomation || (hasCrossApp && mentionsMultipleServices)
    }

    private static func matchesInstallSetup(_ normalized: String) -> Bool {
        let phrases = [
            "install ", "set up ", "setup ", "configure ", "connect account",
            "sign in to", "log in to", "login to", "authenticate",
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private static func matchesContentCreation(_ normalized: String) -> Bool {
        let phrases = [
            "write a", "draft a", "create a doc", "create a document",
            "compose an email", "write an email", "make a presentation",
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private static func matchesInAppSettings(_ normalized: String) -> Bool {
        let phrases = [
            "make private", "make public", "change setting", "turn on",
            "turn off", "enable ", "disable ", "preferences", "settings",
            "export as", "save as", "share link",
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private static func shouldSuggestWebSearch(
        _ normalized: String,
        archetype: CompanionSessionTaskArchetype
    ) -> Bool {
        guard archetype == .crossAppAutomation else { return false }

        let knownPlatforms = ["zapier", "make.com", " integromat", "n8n", "ifttt", "shortcuts"]
        let mentionsKnownPlatform = knownPlatforms.contains { normalized.contains($0) }
        return !mentionsKnownPlatform || countServiceMentions(normalized) >= 2
    }

    private static func countServiceMentions(_ normalized: String) -> Int {
        let services = [
            "gmail", "google sheets", "spreadsheet", "airtable", "notion", "slack",
            "calendar", "outlook", "hubspot", "salesforce", "trello", "asana",
            "zapier", "make", "n8n",
        ]
        return services.filter { normalized.contains($0) }.count
    }
}
