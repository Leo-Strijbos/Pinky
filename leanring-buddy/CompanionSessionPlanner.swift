//
//  CompanionSessionPlanner.swift
//  leanring-buddy
//
//  Parses structured step plans from the session planner LLM response.
//

import Foundation

enum CompanionSessionPlanner {

    enum TopologyStatus: String, Equatable {
        case ready
        case needsClarification = "needs_clarification"
    }

    struct ParsedStep: Equatable {
        let instruction: String
        let lookFor: String?
        let doneWhen: String?
        let substeps: [String]?
    }

    struct ParsedTopology: Equatable {
        let status: TopologyStatus
        let title: String
        let taskType: String
        let recommendedApproach: String?
        let assumptions: [String]
        let orderedPhases: [String]
        let orchestrator: String?
        let avoidFirst: [String]
        let notes: String?
        let questions: [CompanionSessionPlanningQuestion]
    }

    private struct TopologyQuestionJSON: Decodable {
        let question: String?
        let defaultAssumption: String?
    }

    private struct TopologyJSON: Decodable {
        let status: String?
        let title: String?
        let taskType: String?
        let recommendedApproach: String?
        let assumptions: [String]?
        let orderedPhases: [String]?
        let partialOrderedPhases: [String]?
        let orchestrator: String?
        let avoidFirst: [String]?
        let notes: String?
        let questions: [TopologyQuestionJSON]?
    }

    private struct PlannerStepJSON: Decodable {
        let instruction: String?
        let goal: String?
        let lookFor: String?
        let doneWhen: String?
        let substeps: [String]?
    }

    private struct PlannerJSON: Decodable {
        let title: String
        let steps: [PlannerStepPayload]
    }

    private enum PlannerStepPayload: Decodable {
        case string(String)
        case object(PlannerStepJSON)

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let value = try? single.decode(String.self) {
                self = .string(value)
                return
            }
            self = .object(try PlannerStepJSON(from: decoder))
        }
    }

    static func parseTopologyResponse(_ raw: String) throws -> ParsedTopology {
        let parsed = try parseJSON(from: raw) as TopologyJSON

        let statusRaw = parsed.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let status = TopologyStatus(rawValue: statusRaw ?? "") ?? .ready

        let title = parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            throw plannerError("Topology planner returned an empty title.")
        }

        let phases = (parsed.orderedPhases ?? parsed.partialOrderedPhases ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let questions = (parsed.questions ?? []).compactMap { item -> CompanionSessionPlanningQuestion? in
            guard let question = item.question?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty else {
                return nil
            }
            let assumption = item.defaultAssumption?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CompanionSessionPlanningQuestion(
                question: question,
                defaultAssumption: assumption?.isEmpty == false ? assumption : nil
            )
        }

        if status == .ready, phases.count < 2 {
            throw plannerError("Topology planner returned too few ordered phases.")
        }

        if status == .needsClarification, questions.isEmpty {
            throw plannerError("Topology planner requested clarification without questions.")
        }

        return ParsedTopology(
            status: status,
            title: title,
            taskType: parsed.taskType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "general",
            recommendedApproach: parsed.recommendedApproach?.trimmingCharacters(in: .whitespacesAndNewlines),
            assumptions: parsed.assumptions ?? [],
            orderedPhases: phases,
            orchestrator: parsed.orchestrator?.trimmingCharacters(in: .whitespacesAndNewlines),
            avoidFirst: parsed.avoidFirst ?? [],
            notes: parsed.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            questions: questions
        )
    }

    static func topology(from parsed: ParsedTopology) -> CompanionSessionTopology {
        CompanionSessionTopology(
            title: parsed.title,
            taskType: parsed.taskType,
            recommendedApproach: parsed.recommendedApproach,
            assumptions: parsed.assumptions,
            orderedPhases: parsed.orderedPhases,
            orchestrator: parsed.orchestrator,
            avoidFirst: parsed.avoidFirst,
            notes: parsed.notes
        )
    }

    static func parseResponse(_ raw: String) throws -> (title: String, steps: [ParsedStep]) {
        let parsed = try parseJSON(from: raw) as PlannerJSON
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = parsed.steps.compactMap { payload -> ParsedStep? in
            switch payload {
            case .string(let value):
                let instruction = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instruction.isEmpty else { return nil }
                return ParsedStep(instruction: instruction, lookFor: nil, doneWhen: nil, substeps: nil)

            case .object(let step):
                let instruction = resolvedInstruction(from: step)
                guard !instruction.isEmpty else { return nil }
                let substeps = step.substeps?
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return ParsedStep(
                    instruction: instruction,
                    lookFor: step.lookFor?.trimmingCharacters(in: .whitespacesAndNewlines),
                    doneWhen: step.doneWhen?.trimmingCharacters(in: .whitespacesAndNewlines),
                    substeps: substeps?.isEmpty == false ? substeps : nil
                )
            }
        }

        guard !title.isEmpty, steps.count >= 2 else {
            throw plannerError("Planner returned too few steps.")
        }

        return (title: title, steps: steps)
    }

    /// Builds a minimal milestone plan from an approved topology when milestone JSON parsing fails.
    static func planFromTopology(_ topology: CompanionSessionTopology) -> (title: String, steps: [ParsedStep])? {
        guard topology.orderedPhases.count >= 2 else { return nil }

        let steps = topology.orderedPhases.map { phase in
            ParsedStep(instruction: phase, lookFor: nil, doneWhen: nil, substeps: nil)
        }
        return (title: topology.title, steps: steps)
    }

    private static func resolvedInstruction(from step: PlannerStepJSON) -> String {
        if let instruction = step.instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            return instruction
        }
        return step.goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func parseJSON<T: Decodable>(from raw: String) throws -> T {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard
            let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            let data = String(text[start...end]).data(using: .utf8)
        else {
            throw plannerError("Could not parse session planner JSON.")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let snippet = String(text.prefix(240))
            print("⚠️ Session planner JSON decode failed: \(error.localizedDescription)")
            print("⚠️ Session planner raw snippet: \(snippet)")
            throw plannerError("Could not decode session planner JSON: \(error.localizedDescription)")
        }
    }

    private static func plannerError(_ message: String) -> NSError {
        NSError(domain: "CompanionSessionPlanner", code: -1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
