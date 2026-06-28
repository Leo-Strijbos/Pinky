//
//  CompanionSessionPlanBuilder.swift
//  leanring-buddy
//
//  Builds session plans from stored playbooks and local compound commands.
//

import Foundation

enum CompanionSessionPlanBuilder {

    static func compoundSteps(from transcript: String) -> [CompanionSessionStep]? {
        ClickyVoiceCompoundCommandParser.parse(transcript: transcript)
    }

    static func storedProcedurePlan(
        transcript: String,
        playbookManager: PlaybookManager
    ) -> CompanionSessionPlan? {
        guard ClickyProcedureQuery.isStepByStepIntent(transcript),
              let retrieval = playbookManager.retrieveProcedure(for: transcript) else {
            return nil
        }

        guard !retrieval.steps.isEmpty else { return nil }
        return PlaybookSessionAdapter.sessionPlan(from: retrieval)
    }

    static func plan(forPlaybookID playbookID: String, playbookManager: PlaybookManager) -> CompanionSessionPlan? {
        guard let playbook = playbookManager.playbook(withID: playbookID) else { return nil }
        let steps = playbookManager.steps(forPlaybookID: playbookID)
        guard !steps.isEmpty else { return nil }

        let retrieval = PlaybookRetrieval(playbook: playbook, steps: steps, relevanceScore: 1.0)
        return PlaybookSessionAdapter.sessionPlan(from: retrieval)
    }

    static func agentGeneratedPlan(
        title: String,
        steps: [CompanionSessionPlanner.ParsedStep]
    ) -> CompanionSessionPlan? {
        let guideSteps = steps.map { parsed in
            CompanionSessionStep.guide(agentGuideStep(from: parsed))
        }

        guard guideSteps.count >= 2 else { return nil }

        return CompanionSessionPlan(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            source: .agentGenerated,
            policy: .agentGenerated,
            steps: guideSteps
        )
    }

    private static func agentGuideStep(from parsed: CompanionSessionPlanner.ParsedStep) -> CompanionGuideStep {
        let completion: StepCompletionPolicy
        if let doneWhen = parsed.doneWhen, !doneWhen.isEmpty {
            completion = .visionCheck(description: doneWhen)
        } else {
            completion = .manual
        }

        return CompanionGuideStep(
            instruction: parsed.instruction,
            lookFor: parsed.lookFor,
            substeps: parsed.substeps,
            completion: completion,
            pointing: .ifOnScreen,
            skipPolicy: .ifAlreadyComplete
        )
    }
}
