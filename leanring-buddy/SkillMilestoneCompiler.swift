//
//  SkillMilestoneCompiler.swift
//  leanring-buddy
//
//  Groups atomic skill playback steps into spoken milestones.
//

import Foundation

struct SkillMilestoneGroup: Equatable {
    let steps: [SkillPlaybackStep]
}

enum SkillMilestoneCompiler {

    static func groups(from orderedSteps: [SkillPlaybackStep]) -> [SkillMilestoneGroup] {
        guard !orderedSteps.isEmpty else { return [] }

        var grouped: [[SkillPlaybackStep]] = []
        var current: [SkillPlaybackStep] = [orderedSteps[0]]

        for step in orderedSteps.dropFirst() {
            if let last = current.last, sharesScreenContext(last, step) {
                current.append(step)
            } else {
                grouped.append(current)
                current = [step]
            }
        }
        grouped.append(current)

        return grouped.map { SkillMilestoneGroup(steps: $0) }
    }

    static func sharesScreenContext(_ a: SkillPlaybackStep, _ b: SkillPlaybackStep) -> Bool {
        screenContextKey(for: a) == screenContextKey(for: b)
    }

    static func screenContextKey(for step: SkillPlaybackStep) -> String {
        [
            step.contextApp?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            step.contextURLPattern?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            step.contextWindowPattern?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        ].joined(separator: "|")
    }
}
