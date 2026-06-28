//
//  ClickyWorkflowRetriever.swift
//  leanring-buddy
//
//  Question-based workflow retrieval and query classification.
//

import Foundation

enum ClickyWorkflowRetriever {

    static func retrieve(query: String, store: ClickyWorkflowStore) throws -> ClickyWorkflowRetrieval? {
        let hits = try store.search(query: query, limit: 8)
        guard let topHit = hits.first else { return nil }

        guard let workflow = try store.workflow(withID: topHit.workflowID) else { return nil }
        let steps = try store.screenStates(forWorkflowID: workflow.id)

        let normalizedScore = min(1.0, max(0.0, -topHit.relevanceScore / 10.0))
        let minimumScore = ClickyProcedureQuery.isProcedural(query) ? 0.12 : 0.2
        guard normalizedScore >= minimumScore else { return nil }

        return ClickyWorkflowRetrieval(
            workflow: workflow,
            steps: steps,
            relevanceScore: normalizedScore
        )
    }

    /// Strong match for starting a stored-procedure session (not general how-to planning).
    static func retrieveStoredProcedure(
        query: String,
        store: ClickyWorkflowStore
    ) throws -> ClickyWorkflowRetrieval? {
        guard let retrieval = try retrieve(query: query, store: store) else { return nil }

        if ClickyProcedureQuery.isExplicitStoredProcedureRequest(query) {
            return retrieval
        }

        let normalizedQuery = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let triggerHit = retrieval.workflow.triggerPhrases.contains { phrase in
            let normalizedPhrase = phrase
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalizedPhrase.isEmpty && normalizedQuery.contains(normalizedPhrase)
        }

        let normalizedTitle = retrieval.workflow.name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let titleHit = !normalizedTitle.isEmpty && normalizedQuery.contains(normalizedTitle)
        let strongScore = retrieval.relevanceScore >= 0.35

        guard strongScore || triggerHit || titleHit else { return nil }
        return retrieval
    }
}

struct ClickyWorkflowSearchHit: Equatable {
    let workflowID: String
    let stateID: String?
    let kind: String
    let searchText: String
    let relevanceScore: Double
}
