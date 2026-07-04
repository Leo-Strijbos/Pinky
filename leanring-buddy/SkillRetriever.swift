//
//  SkillRetriever.swift
//  leanring-buddy
//
//  Keyword retrieval over the Agent Skills library.
//

import Foundation

enum SkillRetriever {
    static let maxProcedureResults = 3
    static let maxReferenceChunks = 5

    static func retrieveProcedure(query: String, skills: [AgentSkill]) -> SkillRetrieval? {
        let results = searchProcedures(query: query, skills: skills, limit: maxProcedureResults)
        return results.first
    }

    static func retrieveReference(
        query: String,
        skills: [AgentSkill],
        skillName: String? = nil
    ) -> SkillReferenceRetrieval? {
        guard !shouldSkipReferenceSearch(for: query) else { return nil }

        let candidates = skills.filter { skill in
            if let skillName { return skill.name == skillName }
            return skill.kind == .reference
        }

        let normalizedQuery = normalize(query)
        let queryTokens = tokens(from: normalizedQuery)

        var scored: [(SkillReferenceChunk, Double)] = []
        for skill in candidates {
            for chunk in skill.referenceChunks {
                let score = relevanceScore(queryTokens: queryTokens, text: chunk.text, title: skill.title)
                if score > 0 {
                    scored.append((
                        SkillReferenceChunk(
                            id: chunk.id,
                            skillName: chunk.skillName,
                            skillTitle: chunk.skillTitle,
                            pageIndex: chunk.pageIndex,
                            chunkIndex: chunk.chunkIndex,
                            text: chunk.text,
                            relevanceScore: score
                        ),
                        score
                    ))
                }
            }

            if skill.referenceChunks.isEmpty, !skill.bodyMarkdown.isEmpty {
                let score = relevanceScore(queryTokens: queryTokens, text: skill.bodyMarkdown, title: skill.title)
                if score > 0 {
                    scored.append((
                        SkillReferenceChunk(
                            id: "\(skill.name)-body",
                            skillName: skill.name,
                            skillTitle: skill.title,
                            pageIndex: 0,
                            chunkIndex: 0,
                            text: String(skill.bodyMarkdown.prefix(1200)),
                            relevanceScore: score
                        ),
                        score
                    ))
                }
            }
        }

        let chunks = scored
            .sorted { $0.1 > $1.1 }
            .prefix(maxReferenceChunks)
            .map(\.0)

        guard !chunks.isEmpty else { return nil }
        return SkillReferenceRetrieval(chunks: Array(chunks))
    }

    static func searchProcedures(query: String, skills: [AgentSkill], limit: Int) -> [SkillRetrieval] {
        let normalizedQuery = normalize(query)
        let queryTokens = tokens(from: normalizedQuery)

        let scored: [(AgentSkill, [SkillPlaybackStep], Double)] = skills
            .filter { $0.kind == .procedure && !$0.playbackSteps.isEmpty }
            .compactMap { skill in
                let score = procedureScore(skill: skill, queryTokens: queryTokens, normalizedQuery: normalizedQuery)
                guard score > 0 else { return nil }
                return (skill, skill.playbackSteps, score)
            }
            .sorted { $0.2 > $1.2 }

        return scored.prefix(limit).map { skill, steps, score in
            SkillRetrieval(skill: skill, steps: steps, relevanceScore: score)
        }
    }

    static func isReferenceQuery(_ query: String) -> Bool {
        let normalized = query.lowercased()
        let words = [
            "sop", "policy", "policies", "document", "manual", "handbook",
            "guide", "skill", "runbook", "reference", "uploaded",
        ]
        return words.contains { normalized.contains($0) }
    }

    static func shouldOpenDocument(for query: String) -> Bool {
        let normalized = query.lowercased()
        let openPhrases = ["open ", "show ", "pull up ", "view "]
        let docWords = ["sop", "document", "policy", "skill", "manual"]
        return openPhrases.contains { normalized.contains($0) }
            && docWords.contains { normalized.contains($0) }
    }

    static func shouldSkipReferenceSearch(for query: String) -> Bool {
        let normalized = query.lowercased()
        let skip = ["weather", "forecast", "stock price", "news about", "near me"]
        return skip.contains { normalized.contains($0) }
    }

    static func matchScreenContext(
        steps: [SkillPlaybackStep],
        context: ScreenContext
    ) -> (stepIndex: Int, confidence: Double)? {
        guard let index = ScreenContextMatcher.findMatchingStepIndex(steps: steps, context: context) else {
            return nil
        }
        guard let step = steps.first(where: { $0.index == index }) else { return nil }
        let confidence = ScreenContextMatcher.matchScore(for: step, context: context)
        return (index, confidence)
    }

    // MARK: - Private

    private static func procedureScore(skill: AgentSkill, queryTokens: [String], normalizedQuery: String) -> Double {
        var score = 0.0
        let haystacks = [
            skill.name,
            skill.description,
            skill.summary,
            skill.title,
            skill.tags.joined(separator: " "),
            skill.bodyMarkdown,
        ].map { normalize($0) }

        for token in queryTokens where token.count > 2 {
            for haystack in haystacks where haystack.contains(token) {
                score += 1.0
            }
            for step in skill.playbackSteps {
                let stepText = normalize("\(step.title) \(step.instruction)")
                if stepText.contains(token) { score += 0.5 }
            }
        }

        if normalizedQuery.contains(skill.name.replacingOccurrences(of: "-", with: " ")) {
            score += 2.0
        }

        return score
    }

    private static func relevanceScore(queryTokens: [String], text: String, title: String) -> Double {
        let normalizedText = normalize(text)
        let normalizedTitle = normalize(title)
        var score = 0.0

        for token in queryTokens where token.count > 2 {
            if normalizedTitle.contains(token) { score += 1.5 }
            if normalizedText.contains(token) { score += 1.0 }
        }

        return score
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(from text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }
}
