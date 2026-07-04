//
//  SkillSessionAdapter.swift
//  leanring-buddy
//
//  Maps Agent Skills into voice walkthrough session plans.
//

import Foundation

enum SkillSessionAdapter {

    static func sessionPlan(
        from retrieval: SkillRetrieval,
        startIndex: Int = 0
    ) -> CompanionSessionPlan {
        let orderedSteps = retrieval.steps.sorted { $0.index < $1.index }
        let milestoneGroups = SkillMilestoneCompiler.groups(from: orderedSteps)
        let guideSteps = milestoneGroups.map { group in
            CompanionSessionStep.guide(guideStep(for: group, orderedSteps: orderedSteps))
        }

        return CompanionSessionPlan(
            title: retrieval.skill.title,
            source: .storedProcedure,
            policy: .storedProcedure,
            steps: guideSteps,
            skillName: retrieval.skill.name,
            skillSteps: orderedSteps,
            startIndex: startIndex
        )
    }

    static func guideStep(
        for group: SkillMilestoneGroup,
        orderedSteps: [SkillPlaybackStep]
    ) -> CompanionGuideStep {
        let steps = group.steps
        let lastStep = steps[steps.count - 1]
        let lastOffset = orderedSteps.firstIndex(where: { $0.id == lastStep.id }) ?? (orderedSteps.count - 1)

        let completion: StepCompletionPolicy
        if lastOffset + 1 < orderedSteps.count {
            completion = .skillStep(stepID: orderedSteps[lastOffset + 1].id)
        } else {
            completion = .manual
        }

        let substeps: [String]? = steps.count > 1
            ? steps.map { resolvedInstruction(for: $0) }
            : nil

        let instruction = resolvedInstruction(for: steps.count == 1 ? steps[0] : lastStep)
        let lookFor = lastStep.lookFor ?? lastStep.title

        return CompanionGuideStep(
            instruction: instruction,
            lookFor: lookFor,
            substeps: substeps,
            completion: completion,
            pointing: .ifOnScreen,
            skipPolicy: .ifAlreadyComplete,
            skillStepIDs: steps.map(\.id)
        )
    }

    static func procedureAppendix(
        retrieval: SkillRetrieval?,
        screenMatchIndex: Int?,
        pinnedSession: CompanionActiveSession?
    ) -> String {
        if let pinnedSession {
            return pinnedSession.stepAppendix()
        }

        if let screenMatchIndex, let retrieval {
            return retrieval.narrowPromptFragment(currentIndex: screenMatchIndex)
        }

        if let retrieval {
            return retrieval.narrowPromptFragment(currentIndex: 0)
        }

        return ""
    }

    private static func resolvedInstruction(for step: SkillPlaybackStep) -> String {
        let instruction = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return instruction.isEmpty ? step.title : instruction
    }
}
