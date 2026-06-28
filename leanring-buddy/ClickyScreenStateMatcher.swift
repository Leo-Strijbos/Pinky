//
//  ClickyScreenStateMatcher.swift
//  leanring-buddy
//
//  Matches the user's current screen against recorded workflow screen states.
//

import Foundation

enum ClickyScreenStateMatcher {

    private static let matchThreshold = 0.42
    private static let confidentMatchThreshold = 0.50

    static func matchScore(
        for state: ClickyWorkflowScreenState,
        context: ClickyWorkflowScreenContext
    ) -> Double {
        score(state: state, context: context, preferCoreStates: true).score
    }

    /// Returns the top match and whether OCR disambiguation is likely needed.
    static func evaluateMatch(
        context: ClickyWorkflowScreenContext,
        states: [ClickyWorkflowScreenState],
        workflowsByID: [String: ClickyWorkflow],
        preferCoreStates: Bool = true
    ) -> (match: ClickyWorkflowMatch?, needsOCR: Bool) {
        var scored: [(state: ClickyWorkflowScreenState, score: Double, reason: String)] = []

        for state in states where workflowsByID[state.workflowID] != nil {
            let result = score(state: state, context: context, preferCoreStates: preferCoreStates)
            if result.score > 0 {
                scored.append((state, result.score, result.reason))
            }
        }

        scored.sort { $0.score > $1.score }

        guard let best = scored.first, best.score >= matchThreshold,
              let workflow = workflowsByID[best.state.workflowID] else {
            return (nil, !scored.isEmpty)
        }

        let needsOCR: Bool
        if best.score >= confidentMatchThreshold {
            needsOCR = false
        } else if scored.count >= 2 {
            let secondScore = scored[1].score
            needsOCR = (best.score - secondScore) < 0.12
        } else {
            needsOCR = best.score < confidentMatchThreshold
        }

        let match = buildMatch(for: best.state, score: best.score, reason: best.reason, workflow: workflow, states: states)
        return (match, needsOCR)
    }

    static func bestMatch(
        context: ClickyWorkflowScreenContext,
        states: [ClickyWorkflowScreenState],
        workflowsByID: [String: ClickyWorkflow],
        preferCoreStates: Bool = true
    ) -> ClickyWorkflowMatch? {
        evaluateMatch(
            context: context,
            states: states,
            workflowsByID: workflowsByID,
            preferCoreStates: preferCoreStates
        ).match
    }

    private static func buildMatch(
        for state: ClickyWorkflowScreenState,
        score: Double,
        reason: String,
        workflow: ClickyWorkflow,
        states: [ClickyWorkflowScreenState]
    ) -> ClickyWorkflowMatch {
        let upcoming = states
            .filter { $0.workflowID == state.workflowID && $0.stepIndex > state.stepIndex && $0.isCoreState }
            .sorted { $0.stepIndex < $1.stepIndex }
            .prefix(2)

        return ClickyWorkflowMatch(
            state: state,
            workflow: workflow,
            confidence: min(score, 1.0),
            matchReason: reason,
            upcomingSteps: Array(upcoming)
        )
    }

    private static func score(
        state: ClickyWorkflowScreenState,
        context: ClickyWorkflowScreenContext,
        preferCoreStates: Bool
    ) -> (score: Double, reason: String) {
        var score = 0.0
        var reasons: [String] = []

        if !state.app.isEmpty, appsMatch(state.app, context.app) {
            score += 0.15
            reasons.append("app")
        }

        if ClickyWorkflowPatternMatcher.matches(state.urlPattern, value: context.url) {
            score += 0.35
            reasons.append("url")
        }

        if ClickyWorkflowPatternMatcher.matches(state.windowTitlePattern, value: context.windowTitle) {
            score += 0.15
            reasons.append("window")
        }

        if !state.ocrTerms.isEmpty, !context.ocrTerms.isEmpty {
            let stateTerms = Set(state.ocrTerms.map { $0.lowercased() })
            let liveTerms = Set(context.ocrTerms.map { $0.lowercased() })
            let overlap = stateTerms.intersection(liveTerms)
            if !overlap.isEmpty {
                let unionCount = max(stateTerms.union(liveTerms).count, 1)
                let jaccard = Double(overlap.count) / Double(unionCount)
                let ocrScore = min(0.35, jaccard * 0.5 + Double(overlap.count) * 0.03)
                score += ocrScore
                reasons.append("ocr")
            }
        }

        if preferCoreStates && state.isEntryState {
            score *= 0.35
            if !reasons.isEmpty {
                reasons.append("entry-discount")
            }
        }

        return (score, reasons.joined(separator: "+"))
    }

    private static func appsMatch(_ recorded: String, _ live: String) -> Bool {
        let a = recorded.lowercased()
        let b = live.lowercased()
        return a == b || a.contains(b) || b.contains(a)
    }
}
