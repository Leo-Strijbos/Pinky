//
//  ClickyAppActionHandling.swift
//  leanring-buddy
//
//  Handler protocol and registry for local app actions.
//

import Foundation

protocol ClickyAppActionHandling {
    func execute(_ action: ClickyAppAction) async -> String?
}

enum ClickyAppActionHandlerRegistry {
    private static let handlers: [ClickyAppActionHandling] = [
        ClickyOpenURLActionHandler(),
        ClickySpotifyAppActionHandler(),
        ClickyOpenAppActionHandler(),
    ]

    static func execute(_ action: ClickyAppAction) async -> String {
        for handler in handlers {
            if let result = await handler.execute(action) {
                return result
            }
        }
        return "i couldn't do that."
    }

    static func executeLegacy(_ action: ClickyAppAction) async -> String {
        await execute(action)
    }
}
