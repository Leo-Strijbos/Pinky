//
//  PinkyAppActionExecutor.swift
//  leanring-buddy
//
//  Dispatches structured app actions to registered handlers.
//

import Foundation

@MainActor
enum PinkyAppActionExecutor {
    static func execute(
        _ action: PinkyAppAction,
        context: CompanionCapabilityContext = .empty
    ) async -> String {
        switch action {
        case .openApp, .openURL:
            return await CompanionCapabilityRegistry.standard.executeAppAction(action, context: context)
        default:
            return await PinkyAppActionHandlerRegistry.execute(action)
        }
    }
}
