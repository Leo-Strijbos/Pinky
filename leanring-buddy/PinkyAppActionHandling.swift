//
//  PinkyAppActionHandling.swift
//  leanring-buddy
//
//  Handler protocol and registry for local app actions.
//

import Foundation

protocol PinkyAppActionHandling {
    func execute(_ action: PinkyAppAction) async -> String?
}

enum PinkyAppActionHandlerRegistry {
    private static let handlers: [PinkyAppActionHandling] = [
        PinkyOpenURLActionHandler(),
        PinkySpotifyAppActionHandler(),
        PinkyOpenAppActionHandler(),
    ]

    static func execute(_ action: PinkyAppAction) async -> String {
        for handler in handlers {
            if let result = await handler.execute(action) {
                return result
            }
        }
        return "i couldn't do that."
    }

    static func executeLegacy(_ action: PinkyAppAction) async -> String {
        await execute(action)
    }
}
