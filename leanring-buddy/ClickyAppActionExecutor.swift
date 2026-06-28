//
//  ClickyAppActionExecutor.swift
//  leanring-buddy
//
//  Dispatches structured app actions to registered handlers.
//

import Foundation

@MainActor
enum ClickyAppActionExecutor {
    static func execute(
        _ action: ClickyAppAction,
        context: CompanionCapabilityContext = .empty
    ) async -> String {
        switch action {
        case .openApp, .openURL:
            return await CompanionCapabilityRegistry.standard.executeAppAction(action, context: context)
        default:
            return await ClickyAppActionHandlerRegistry.execute(action)
        }
    }
}
