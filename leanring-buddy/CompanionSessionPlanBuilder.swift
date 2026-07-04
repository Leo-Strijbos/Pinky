//
//  CompanionSessionPlanBuilder.swift
//  leanring-buddy
//
//  Builds session plans from stored skills and local compound commands.
//

import Foundation

enum CompanionSessionPlanBuilder {

    static func compoundSteps(from transcript: String) -> [CompanionSessionStep]? {
        PinkyVoiceCompoundCommandParser.parse(transcript: transcript)
    }

    static func storedProcedurePlan(
        transcript: String,
        skillManager: SkillManager
    ) -> CompanionSessionPlan? {
        guard PinkyProcedureQuery.isStepByStepIntent(transcript),
              let retrieval = skillManager.retrieveProcedure(for: transcript) else {
            return nil
        }

        guard !retrieval.steps.isEmpty else { return nil }
        return SkillSessionAdapter.sessionPlan(from: retrieval)
    }

    static func plan(forSkillName skillName: String, skillManager: SkillManager) -> CompanionSessionPlan? {
        guard let skill = skillManager.skill(named: skillName) else { return nil }
        let steps = skillManager.playbackSteps(forSkillName: skillName)
        guard !steps.isEmpty else { return nil }

        let retrieval = SkillRetrieval(skill: skill, steps: steps, relevanceScore: 1.0)
        return SkillSessionAdapter.sessionPlan(from: retrieval)
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
