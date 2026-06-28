//
//  CompanionSessionRunner.swift
//  leanring-buddy
//
//  Executes typed session steps (local app actions).
//

import Foundation

enum CompanionSessionRunner {

    static func executeCompoundSteps(_ steps: [CompanionSessionStep]) async -> String {
        var lines: [String] = []

        for step in steps {
            switch step {
            case .guide(let guideStep):
                lines.append(guideStep.instruction)

            case .appAction(let action, let bridge):
                if let bridge, !bridge.isEmpty {
                    lines.append(bridge)
                }
                let result = await ClickyAppActionExecutor.execute(action)
                lines.append(result)
            }
        }

        return lines.joined(separator: " ")
    }
}
