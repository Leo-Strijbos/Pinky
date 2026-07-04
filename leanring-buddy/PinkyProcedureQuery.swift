//
//  PinkyProcedureQuery.swift
//  leanring-buddy
//
//  Detects procedural voice questions for workflow / PDF procedure retrieval.
//

import Foundation

struct CompanionWalkthroughRoutingContext {
    let recentExchanges: [(user: String, assistant: String)]
    let recentCopyableKind: PinkyCopyableContentPayload.Kind?

    static let empty = CompanionWalkthroughRoutingContext(
        recentExchanges: [],
        recentCopyableKind: nil
    )
}

enum PinkyProcedureQuery {

    /// Interactive step-by-step intent — routes into the session runner (stored plan or agent planner).
    /// Informational questions about uploaded policies/SOPs ("what's our onboarding policy?")
    /// are not step-by-step; those go through the normal agent turn with knowledge retrieval.
    static func isStepByStepIntent(_ query: String) -> Bool {
        isProcedural(query)
    }

    /// Whether a new walkthrough plan should be started (vs continuing with the agent).
    static func shouldStartWalkthroughPlanning(
        transcript: String,
        context: CompanionWalkthroughRoutingContext = .empty
    ) -> Bool {
        guard isProcedural(transcript) else { return false }
        if isScriptOrCodeExecutionQuery(transcript) { return false }
        if isContinuationOfPriorTurn(transcript, context: context) { return false }
        return true
    }

    static func isProcedural(_ query: String) -> Bool {
        let normalized = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return false }

        let phrases = [
            "how do i",
            "how do we",
            "how to ",
            "what's the next step",
            "whats the next step",
            "what is the next step",
            "next step",
            "walk me through",
            "step by step",
            "step-by-step",
            "what do i do",
            "what should i do",
            "where do i click",
            "where do i go",
            "help me with this",
            "show me how",
            "show me what to do",
            "guide me",
        ]

        return phrases.contains { normalized.contains($0) }
    }

    static func isExplicitStoredProcedureRequest(_ query: String) -> Bool {
        let normalized = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let phrases = [
            "my procedure", "our procedure", "the procedure", "uploaded procedure",
            "my workflow", "our workflow", "the sop", "our sop", "my sop",
            "from my upload", "from the upload",
        ]
        return phrases.contains { normalized.contains($0) }
    }

    // MARK: - Walkthrough routing guards

    static func isScriptOrCodeExecutionQuery(_ query: String) -> Bool {
        let normalized = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let executionPhrases = [
            "run it", "run this", "run that", "run the script", "run the code",
            "execute it", "execute this", "execute the script", "execute the code",
            "how do i run", "how to run", "where should i run", "where do i run",
            "how do i execute", "how to execute",
            "use this script", "use this code", "use the script", "use the code",
            "run this script", "run this code", "run python", "run bash",
            "in terminal", "in the terminal", "command line", "command-line",
        ]

        if executionPhrases.contains(where: { normalized.contains($0) }) {
            return true
        }

        let codeSignals = ["python", "script", "bash", "shell", "terminal", "npm ", "node "]
        let hasCodeSignal = codeSignals.contains { normalized.contains($0) }
        let asksHow = normalized.contains("how do i")
            || normalized.contains("how to ")
            || normalized.contains("where do i")
            || normalized.contains("where should i")
        return hasCodeSignal && asksHow
    }

    static func isContinuationOfPriorTurn(
        _ query: String,
        context: CompanionWalkthroughRoutingContext
    ) -> Bool {
        let normalized = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if hasDeicticReference(normalized) {
            return true
        }

        if PinkyVoiceSessionPhrases.isAdvance(query),
           context.hasRecentCodeOrCommandContext {
            return true
        }

        if context.recentCopyableKind != nil,
           isProceduralFollowUp(normalized) {
            return true
        }

        if context.hasRecentCodeOrCommandContext,
           isProceduralFollowUp(normalized) {
            return true
        }

        return false
    }

    private static func hasDeicticReference(_ normalized: String) -> Bool {
        let phrases = [
            " this", " that", " it now", " it?", " i've copied", " ive copied",
            " i copied", " the script", " the code", " this script", " this code",
            " that script", " that code", " with this", " with that",
            " use this", " use that", " run this", " run that",
        ]
        if phrases.contains(where: { normalized.contains($0) }) {
            return true
        }

        let tokens = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return tokens.contains("it") || tokens.contains("this") || tokens.contains("that")
    }

    private static func isProceduralFollowUp(_ normalized: String) -> Bool {
        let followUpPhrases = [
            "how do i", "how to ", "what do i do", "what should i do",
            "where do i", "where should i", "what's next", "whats next",
            "what now", "and now", "next step", "help me with",
        ]
        return followUpPhrases.contains { normalized.contains($0) }
    }
}

private extension CompanionWalkthroughRoutingContext {

    var hasRecentCodeOrCommandContext: Bool {
        if recentCopyableKind == .code || recentCopyableKind == .command {
            return true
        }

        let codeSignals = [
            "python", "script", "code", "terminal", "bash", "command",
            "filename", "rename", "copied",
        ]

        return recentExchanges.contains { exchange in
            let combined = "\(exchange.user) \(exchange.assistant)".lowercased()
            return codeSignals.contains { combined.contains($0) }
        }
    }
}
