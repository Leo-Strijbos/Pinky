//
//  CompanionSessionModels.swift
//  leanring-buddy
//
//  Typed plans, policies, and active sessions for multi-step voice execution.
//

import Foundation

enum CompanionSessionPlanSource: String, Equatable {
    case storedProcedure
    case agentGenerated
}

enum AdvanceMode: String, Equatable {
    case manual
    case hybrid
}

enum PromptStyle: String, Equatable {
    case stepOnce
    case minimal
}

enum PointingPolicy: String, Equatable {
    case none
    case ifOnScreen
}

enum CoachingMode: String, Equatable {
    /// Point and instruct on each milestone.
    case leading
    /// Watch silently and only speak when the user seems stuck.
    case shadowing
}

enum SkipPolicy: Equatable {
    case never
    case ifAlreadyComplete
}

enum StepCompletionPolicy: Equatable {
    case manual
    case visionCheck(description: String)
    case playbookStep(stepID: String)
}

struct CompanionSessionPolicy: Equatable {
    var advanceMode: AdvanceMode
    var promptStyle: PromptStyle

    static let `default` = CompanionSessionPolicy(
        advanceMode: .manual,
        promptStyle: .minimal
    )

    static let storedProcedure = CompanionSessionPolicy(
        advanceMode: .hybrid,
        promptStyle: .stepOnce
    )

    static let agentGenerated = CompanionSessionPolicy(
        advanceMode: .hybrid,
        promptStyle: .minimal
    )
}

struct CompanionGuideStep: Equatable {
    let instruction: String
    let lookFor: String?
    let substeps: [String]?
    let completion: StepCompletionPolicy
    let pointing: PointingPolicy
    let skipPolicy: SkipPolicy
    let playbookStepIDs: [String]?

    init(
        instruction: String,
        lookFor: String?,
        substeps: [String]? = nil,
        completion: StepCompletionPolicy,
        pointing: PointingPolicy,
        skipPolicy: SkipPolicy = .ifAlreadyComplete,
        playbookStepIDs: [String]? = nil
    ) {
        self.instruction = instruction
        self.lookFor = lookFor
        self.substeps = substeps
        self.completion = completion
        self.pointing = pointing
        self.skipPolicy = skipPolicy
        self.playbookStepIDs = playbookStepIDs
    }
}

enum CompanionSessionStep: Equatable {
    case guide(CompanionGuideStep)
    case appAction(ClickyAppAction, bridge: String?)
}

struct CompanionSessionPlan: Equatable {
    let id: String
    let title: String
    let source: CompanionSessionPlanSource
    let policy: CompanionSessionPolicy
    let steps: [CompanionSessionStep]
    let playbookID: String?
    let playbookSteps: [PlaybookStep]?
    let startIndex: Int

    init(
        id: String = UUID().uuidString,
        title: String,
        source: CompanionSessionPlanSource,
        policy: CompanionSessionPolicy = .default,
        steps: [CompanionSessionStep],
        playbookID: String? = nil,
        playbookSteps: [PlaybookStep]? = nil,
        startIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.policy = policy
        self.steps = steps
        self.playbookID = playbookID
        self.playbookSteps = playbookSteps
        self.startIndex = startIndex
    }
}

struct CompanionActiveSession: Equatable {
    let plan: CompanionSessionPlan
    var currentIndex: Int
    var awaitingAdvance: Bool
    var stepContextSnapshot: PlaybookScreenContext?
    var stepReadyAt: Date?
    var hasShownAdvanceHint: Bool
    var coachingMode: CoachingMode
    var consecutiveAutoAdvances: Int
    var showSubsteps: Bool
    var lastProgressAt: Date?
    var stuckNudgeShown: Bool

    init(
        plan: CompanionSessionPlan,
        currentIndex: Int,
        awaitingAdvance: Bool,
        stepContextSnapshot: PlaybookScreenContext?,
        stepReadyAt: Date?,
        hasShownAdvanceHint: Bool,
        coachingMode: CoachingMode = .leading,
        consecutiveAutoAdvances: Int = 0,
        showSubsteps: Bool = false,
        lastProgressAt: Date? = nil,
        stuckNudgeShown: Bool = false
    ) {
        self.plan = plan
        self.currentIndex = currentIndex
        self.awaitingAdvance = awaitingAdvance
        self.stepContextSnapshot = stepContextSnapshot
        self.stepReadyAt = stepReadyAt
        self.hasShownAdvanceHint = hasShownAdvanceHint
        self.coachingMode = coachingMode
        self.consecutiveAutoAdvances = consecutiveAutoAdvances
        self.showSubsteps = showSubsteps
        self.lastProgressAt = lastProgressAt
        self.stuckNudgeShown = stuckNudgeShown
    }

    var policy: CompanionSessionPolicy { plan.policy }

    var currentStep: CompanionSessionStep? {
        guard currentIndex >= 0, currentIndex < plan.steps.count else { return nil }
        return plan.steps[currentIndex]
    }

    var currentGuideStep: CompanionGuideStep? {
        guard case .guide(let step) = currentStep else { return nil }
        return step
    }

    var isComplete: Bool {
        currentIndex >= plan.steps.count
    }

    func currentSpokenInstruction() -> String {
        currentGuideStep?.instruction ?? plan.title
    }

    func spokenSubstepDetail() -> String? {
        guard showSubsteps,
              let substeps = currentGuideStep?.substeps,
              substeps.count > 1 else {
            return nil
        }

        return substeps.enumerated().map { index, step in
            index == 0 ? "First, \(step)" : "Then, \(step)"
        }.joined(separator: " ")
    }

    func stepAppendix() -> String {
        let instruction = currentSpokenInstruction()
        var lines = [
            "active step-by-step guidance session:",
            "task: \(plan.title)",
            "plan source: \(plan.source.rawValue)",
            "coaching mode: \(coachingMode.rawValue)",
            "current step \(currentIndex + 1) of \(plan.steps.count): \(instruction)",
        ]

        if let lookFor = currentGuideStep?.lookFor, !lookFor.isEmpty {
            lines.append("look for: \(lookFor)")
        }

        if showSubsteps, let substeps = currentGuideStep?.substeps, !substeps.isEmpty {
            lines.append("substeps: \(substeps.joined(separator: " → "))")
        }

        if let playbookID = plan.playbookID, plan.source == .storedProcedure {
            lines.insert("matched company playbook id: \(playbookID)", at: 1)
        }

        if let milestoneSteps = milestonePlaybookSteps(), let last = milestoneSteps.last {
            lines.append("playbook step: \(last.title)")
        } else if let playbookStep = plan.playbookSteps?[safe: currentIndex] {
            lines.append("playbook step: \(playbookStep.title)")
        }

        if currentIndex + 1 < plan.steps.count,
           case .guide(let nextGuide) = plan.steps[currentIndex + 1] {
            lines.append("next step preview: \(nextGuide.instruction)")
        }

        lines.append("answer about the current step only. point at on-screen UI when helpful.")
        return lines.joined(separator: "\n")
    }

    func milestonePlaybookSteps() -> [PlaybookStep]? {
        guard let ids = currentGuideStep?.playbookStepIDs,
              let allSteps = plan.playbookSteps else {
            return nil
        }

        return ids.compactMap { id in
            allSteps.first(where: { $0.id == id })
        }
    }
}

enum CompanionSessionOutcome: Equatable {
    case speak(String, session: CompanionActiveSession?)
    case executeGuideStep(CompanionActiveSession)
    case runCompoundSteps([CompanionSessionStep])
    case agentTurn(transcript: String, session: CompanionActiveSession)
    case ended(spoken: String)
    case needsPlan(transcript: String)
    case autoAdvanced(transition: String?, session: CompanionActiveSession)
    case exitAndContinue(transcript: String)
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
