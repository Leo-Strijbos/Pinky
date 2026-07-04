//
//  CompanionSessionPlanningService.swift
//  leanring-buddy
//
//  Multi-phase session planning: topology → milestones → validation, with optional clarifications.
//

import Foundation

@MainActor
final class CompanionSessionPlanningService {
    private let claudeAPI: ClaudeAPI
    private let skillManager: SkillManager

    private(set) var pendingClarification: CompanionSessionPlanningClarification?
    private(set) var pendingRetryTranscript: String?

    init(claudeAPI: ClaudeAPI, skillManager: SkillManager) {
        self.claudeAPI = claudeAPI
        self.skillManager = skillManager
    }

    func clearPendingClarification() {
        pendingClarification = nil
    }

    func clearPendingRetry() {
        pendingRetryTranscript = nil
    }

    func markPendingRetry(transcript: String) {
        pendingRetryTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildPlan(transcript: String) async throws -> CompanionSessionPlanningResult {
        try await buildPlan(
            transcript: transcript,
            clarificationContext: nil,
            clarificationRound: 0
        )
    }

    func resumePendingPlan(with answerTranscript: String) async throws -> CompanionSessionPlanningResult {
        guard let pending = pendingClarification else {
            throw planningError("No pending planning clarification to resume.")
        }

        pendingClarification = nil

        let answers: String
        if CompanionSessionPlanningBriefFormatter.isProceedWithDefaults(answerTranscript) {
            answers = CompanionSessionPlanningBriefFormatter.defaultAnswers(from: pending.questions)
        } else {
            answers = answerTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let clarificationContext = """
        the user already answered planning questions. incorporate these answers and prefer status ready unless one critical detail is still missing.
        original request: \(pending.originalTranscript)
        assistant asked: \(pending.spokenPrompt)
        user answer: \(answers)
        """

        return try await buildPlan(
            transcript: pending.originalTranscript,
            clarificationContext: clarificationContext,
            clarificationRound: pending.clarificationRound + 1
        )
    }

    private func buildPlan(
        transcript: String,
        clarificationContext: String?,
        clarificationRound: Int
    ) async throws -> CompanionSessionPlanningResult {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw planningError("Planning transcript was empty.")
        }

        let taskHints = CompanionSessionTaskClassifier.hints(for: trimmedTranscript)
        let knowledgeAppendix = skillManager.plannerReferenceAppendix(for: trimmedTranscript)
        let taskArchetypeAppendix = CompanionAgentPrompt.taskArchetypeAppendix(for: taskHints.archetype)
        let webSearchAppendix = try await planningResearchAppendix(
            transcript: trimmedTranscript,
            taskHints: taskHints
        )

        print("🎬 Session planner: capturing screen for planning")
        let planningCapture = try await CompanionSessionPlanningContext.capture()
        let screenContextAppendix = CompanionSessionPlanningContext.screenContextAppendix(
            for: planningCapture.screenContext
        )

        print("🎬 Session planner: topology phase for \"\(trimmedTranscript)\"")

        let topologyParsed = try await runTopologyPhase(
            transcript: trimmedTranscript,
            planningCapture: planningCapture,
            knowledgeAppendix: knowledgeAppendix,
            taskArchetypeAppendix: taskArchetypeAppendix,
            screenContextAppendix: screenContextAppendix,
            webSearchAppendix: webSearchAppendix,
            clarificationContext: clarificationContext ?? "",
            taskHints: taskHints
        )

        if topologyParsed.status == .needsClarification,
           clarificationRound < CompanionAgentPrompt.maxPlanningClarificationRounds {
            let spokenPrompt = CompanionSessionPlanningBriefFormatter.spokenPrompt(
                questions: topologyParsed.questions,
                recommendedApproach: topologyParsed.recommendedApproach
            )
            let partialTopology = topologyParsed.orderedPhases.isEmpty
                ? nil
                : CompanionSessionPlanner.topology(from: topologyParsed)

            let clarification = CompanionSessionPlanningClarification(
                originalTranscript: trimmedTranscript,
                spokenPrompt: spokenPrompt,
                questions: topologyParsed.questions,
                recommendedApproach: topologyParsed.recommendedApproach,
                partialTopology: partialTopology,
                clarificationRound: clarificationRound
            )
            pendingClarification = clarification
            print("🎬 Session planner: needs clarification (\(topologyParsed.questions.count) question(s))")
            return .needsClarification(clarification)
        }

        let topology: CompanionSessionTopology
        if topologyParsed.status == .needsClarification {
            print("🎬 Session planner: clarification limit reached — proceeding with defaults")
            topology = topologyWithDefaults(from: topologyParsed)
        } else {
            topology = CompanionSessionPlanner.topology(from: topologyParsed)
        }
        pendingClarification = nil

        print("🎬 Session planner: milestone phase for \"\(topology.title)\"")

        let parsedPlan = try await runMilestonePhase(
            transcript: trimmedTranscript,
            planningCapture: planningCapture,
            topology: topology,
            knowledgeAppendix: knowledgeAppendix,
            taskArchetypeAppendix: taskArchetypeAppendix,
            taskHints: taskHints
        )

        print("🎬 Session planner: validating plan")

        let validated = try await runValidatorPhase(
            transcript: trimmedTranscript,
            topology: topology,
            parsedPlan: parsedPlan,
            taskHints: taskHints
        )

        guard let plan = CompanionSessionPlanBuilder.agentGeneratedPlan(
            title: validated.title,
            steps: validated.steps
        ) else {
            throw planningError("Planner returned an invalid step plan.")
        }

        print("🎬 Session planner: \"\(plan.title)\" with \(plan.steps.count) steps")
        pendingRetryTranscript = nil
        return .plan(plan)
    }

    private func runTopologyPhase(
        transcript: String,
        planningCapture: CompanionSessionPlanningCapture,
        knowledgeAppendix: String,
        taskArchetypeAppendix: String,
        screenContextAppendix: String,
        webSearchAppendix: String,
        clarificationContext: String,
        taskHints: CompanionSessionTaskHints
    ) async throws -> CompanionSessionPlanner.ParsedTopology {
        let systemPrompt = CompanionAgentPrompt.sessionTopologySystemPrompt(
            knowledgeAppendix: knowledgeAppendix,
            taskArchetypeAppendix: taskArchetypeAppendix,
            screenContextAppendix: screenContextAppendix,
            webSearchAppendix: webSearchAppendix,
            clarificationContext: clarificationContext
        )
        let userPrompt = CompanionAgentPrompt.planningUserPrompt(transcript: transcript)

        let model = taskHints.preferStrongerModel
            ? CompanionAgentPrompt.sessionPlannerStrongModel
            : CompanionAgentPrompt.sessionPlannerModel

        let labeledImage = planningCapture.labeledImage
        let (rawResponse, _) = try await claudeAPI.analyzeImage(
            images: [labeledImage],
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            maxTokens: 1024
        )

        do {
            return try CompanionSessionPlanner.parseTopologyResponse(rawResponse)
        } catch {
            print("⚠️ Session planner topology parse failed: \(error.localizedDescription)")
        }

        print("🎬 Session planner: retrying topology phase without screenshot")

        let textOnlyResponse = try await claudeAPI.sendStructuredJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            maxTokens: 1024
        )

        return try CompanionSessionPlanner.parseTopologyResponse(textOnlyResponse)
    }

    private func runMilestonePhase(
        transcript: String,
        planningCapture: CompanionSessionPlanningCapture,
        topology: CompanionSessionTopology,
        knowledgeAppendix: String,
        taskArchetypeAppendix: String,
        taskHints: CompanionSessionTaskHints
    ) async throws -> (title: String, steps: [CompanionSessionPlanner.ParsedStep]) {
        let systemPrompt = CompanionAgentPrompt.sessionPlannerSystemPrompt(
            knowledgeAppendix: knowledgeAppendix,
            topologyAppendix: CompanionAgentPrompt.topologyAppendix(for: topology),
            taskArchetypeAppendix: taskArchetypeAppendix
        )
        let userPrompt = CompanionAgentPrompt.planningUserPrompt(transcript: transcript)
        let labeledImage = planningCapture.labeledImage

        let model = taskHints.preferStrongerModel
            ? CompanionAgentPrompt.sessionPlannerStrongModel
            : CompanionAgentPrompt.sessionPlannerModel

        let (rawResponse, _) = try await claudeAPI.analyzeImage(
            images: [labeledImage],
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            maxTokens: 1024
        )

        do {
            return try CompanionSessionPlanner.parseResponse(rawResponse)
        } catch {
            print("⚠️ Session planner milestone parse failed: \(error.localizedDescription)")
        }

        print("🎬 Session planner: retrying milestone phase without screenshot")

        let textOnlyPrompt = """
        \(userPrompt)

        the user can see their screen, but you cannot for this retry. use the task topology to produce concrete milestones anyway.
        """

        do {
            let retryResponse = try await claudeAPI.sendStructuredJSON(
                systemPrompt: systemPrompt,
                userPrompt: textOnlyPrompt,
                model: model,
                maxTokens: 1024
            )
            return try CompanionSessionPlanner.parseResponse(retryResponse)
        } catch {
            print("⚠️ Session planner milestone text retry failed: \(error.localizedDescription)")
        }

        if let fallback = CompanionSessionPlanner.planFromTopology(topology) {
            print("🎬 Session planner: using topology phases as milestone fallback")
            return fallback
        }

        throw planningError("Milestone planner returned unparseable JSON.")
    }

    private func runValidatorPhase(
        transcript: String,
        topology: CompanionSessionTopology,
        parsedPlan: (title: String, steps: [CompanionSessionPlanner.ParsedStep]),
        taskHints: CompanionSessionTaskHints
    ) async throws -> (title: String, steps: [CompanionSessionPlanner.ParsedStep]) {
        let planJSON = try encodePlanJSON(title: parsedPlan.title, steps: parsedPlan.steps)
        let userPrompt = CompanionAgentPrompt.planValidatorUserPrompt(
            transcript: transcript,
            topology: topology,
            planJSON: planJSON
        )

        let model = taskHints.preferStrongerModel
            ? CompanionAgentPrompt.sessionPlannerStrongModel
            : CompanionAgentPrompt.sessionPlannerModel

        let rawResponse = try await claudeAPI.sendStructuredJSON(
            systemPrompt: CompanionAgentPrompt.sessionPlanValidatorSystemPrompt(),
            userPrompt: userPrompt,
            model: model,
            maxTokens: 1024
        )

        do {
            return try CompanionSessionPlanner.parseResponse(rawResponse)
        } catch {
            print("⚠️ Session planner validator failed: \(error.localizedDescription) — using unvalidated plan")
            return parsedPlan
        }
    }

    private func planningResearchAppendix(
        transcript: String,
        taskHints: CompanionSessionTaskHints
    ) async throws -> String {
        guard taskHints.suggestWebSearch else { return "" }

        print("🎬 Session planner: researching setup order")

        do {
            let brief = try await claudeAPI.sendPlanningResearchBrief(
                systemPrompt: CompanionAgentPrompt.sessionPlanningResearchSystemPrompt(),
                userPrompt: transcript,
                model: CompanionAgentPrompt.sessionPlannerModel
            )
            guard !brief.isEmpty else { return "" }
            return "web research brief for planning (not for the user):\n\(brief)"
        } catch {
            print("⚠️ Session planner research failed: \(error.localizedDescription)")
            return ""
        }
    }

    private func encodePlanJSON(
        title: String,
        steps: [CompanionSessionPlanner.ParsedStep]
    ) throws -> String {
        let payloadSteps: [[String: Any]] = steps.map { step in
            var object: [String: Any] = ["instruction": step.instruction]
            if let lookFor = step.lookFor { object["lookFor"] = lookFor }
            if let doneWhen = step.doneWhen { object["doneWhen"] = doneWhen }
            if let substeps = step.substeps { object["substeps"] = substeps }
            return object
        }

        let payload: [String: Any] = [
            "title": title,
            "steps": payloadSteps,
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw planningError("Could not encode plan JSON.")
        }
        return json
    }

    private func topologyWithDefaults(
        from parsed: CompanionSessionPlanner.ParsedTopology
    ) -> CompanionSessionTopology {
        var assumptions = parsed.assumptions
        for question in parsed.questions {
            if let assumption = question.defaultAssumption, !assumption.isEmpty {
                assumptions.append(assumption)
            }
        }

        return CompanionSessionTopology(
            title: parsed.title,
            taskType: parsed.taskType,
            recommendedApproach: parsed.recommendedApproach,
            assumptions: assumptions,
            orderedPhases: parsed.orderedPhases,
            orchestrator: parsed.orchestrator,
            avoidFirst: parsed.avoidFirst,
            notes: parsed.notes
        )
    }

    private func planningError(_ message: String) -> NSError {
        NSError(domain: "CompanionSessionPlanningService", code: -1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
