//
//  PlaybookMilestoneCompiler.swift
//  leanring-buddy
//
//  Groups atomic playbook steps into spoken milestones.
//

import Foundation

struct PlaybookMilestoneGroup: Equatable {
    let steps: [PlaybookStep]
}

enum PlaybookMilestoneCompiler {

    static func groups(from orderedSteps: [PlaybookStep]) -> [PlaybookMilestoneGroup] {
        guard !orderedSteps.isEmpty else { return [] }

        var grouped: [[PlaybookStep]] = []
        var current: [PlaybookStep] = [orderedSteps[0]]

        for step in orderedSteps.dropFirst() {
            if let last = current.last, sharesScreenContext(last, step) {
                current.append(step)
            } else {
                grouped.append(current)
                current = [step]
            }
        }
        grouped.append(current)

        return grouped.map { PlaybookMilestoneGroup(steps: $0) }
    }

    static func sharesScreenContext(_ a: PlaybookStep, _ b: PlaybookStep) -> Bool {
        screenContextKey(for: a) == screenContextKey(for: b)
    }

    static func screenContextKey(for step: PlaybookStep) -> String {
        [
            step.contextApp?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            step.contextURLPattern?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            step.contextWindowPattern?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        ].joined(separator: "|")
    }
}
