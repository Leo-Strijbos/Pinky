//
//  PlaybookRetriever.swift
//  leanring-buddy
//
//  FTS retrieval and reference excerpt resolution for voice turns.
//

import Foundation

enum PlaybookRetriever {
    static let maxProcedureResults = 3
    static let maxReferenceChunks = 5

    static func retrieveProcedure(query: String, store: PlaybookStore) throws -> PlaybookRetrieval? {
        let results = try store.searchPlaybooks(query: query, kind: .procedure, limit: maxProcedureResults)
        return results.first
    }

    static func retrieveReference(query: String, store: PlaybookStore, playbookID: String? = nil) throws -> PlaybookReferenceRetrieval? {
        guard !shouldSkipReferenceSearch(for: query) else { return nil }

        let chunks = try store.searchReferenceChunks(
            query: query,
            playbookID: playbookID,
            limit: maxReferenceChunks
        )
        guard !chunks.isEmpty else { return nil }
        return PlaybookReferenceRetrieval(chunks: chunks)
    }

    static func isReferenceQuery(_ query: String) -> Bool {
        let normalized = query.lowercased()
        let words = [
            "sop", "policy", "policies", "document", "manual", "handbook",
            "guide", "playbook", "runbook", "reference", "uploaded",
        ]
        return words.contains { normalized.contains($0) }
    }

    static func shouldOpenDocument(for query: String) -> Bool {
        let normalized = query.lowercased()
        let openPhrases = ["open ", "show ", "pull up ", "view "]
        let docWords = ["sop", "document", "policy", "procedure", "manual", "playbook"]
        return openPhrases.contains { normalized.contains($0) }
            && docWords.contains { normalized.contains($0) }
    }

    static func shouldSkipReferenceSearch(for query: String) -> Bool {
        let normalized = query.lowercased()
        let skip = ["weather", "forecast", "stock price", "news about", "near me"]
        return skip.contains { normalized.contains($0) }
    }

    static func matchScreenContext(
        steps: [PlaybookStep],
        context: PlaybookScreenContext
    ) -> (stepIndex: Int, confidence: Double)? {
        guard let index = PlaybookContextMatcher.findMatchingStepIndex(steps: steps, context: context) else {
            return nil
        }
        guard let step = steps.first(where: { $0.index == index }) else { return nil }
        let confidence = PlaybookContextMatcher.matchScore(for: step, context: context)
        return (index, confidence)
    }
}
