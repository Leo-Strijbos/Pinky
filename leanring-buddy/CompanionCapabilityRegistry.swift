//
//  CompanionCapabilityRegistry.swift
//  leanring-buddy
//
//  Central registry for client-side agent capabilities and fast-path execution.
//

import Foundation

@MainActor
final class CompanionCapabilityRegistry {
    static let standard = CompanionCapabilityRegistry()

    private let capabilities: [String: any CompanionCapability]

    init(capabilities: [any CompanionCapability] = CompanionCapabilityRegistry.defaultCapabilities) {
        var map: [String: any CompanionCapability] = [:]
        for capability in capabilities {
            map[capability.name] = capability
        }
        self.capabilities = map
    }

    private static let defaultCapabilities: [any CompanionCapability] = [
        CompanionPointAtElementCapability(),
        CompanionShowPanelCapability(),
        CompanionPresentDocumentCapability(),
        CompanionPresentCopyableContentCapability(),
        CompanionOpenURLCapability(),
        CompanionOpenAppCapability(),
        CompanionReadPDFCapability(),
        CompanionReadFileCapability(),
    ]

    func toolDefinitions(for scope: CompanionCapabilityScope) -> [[String: Any]] {
        capabilities.values
            .filter { $0.scopes.contains(scope) }
            .sorted { $0.name < $1.name }
            .map(\.toolDefinition)
    }

    func clientToolNames(for scope: CompanionCapabilityScope) -> Set<String> {
        Set(toolDefinitions(for: scope).compactMap { $0["name"] as? String })
    }

    func clientToolUseBlocks(
        from contentBlocks: [[String: Any]],
        scope: CompanionCapabilityScope
    ) -> [[String: Any]] {
        let names = clientToolNames(for: scope)
        return contentBlocks.filter { block in
            guard (block["type"] as? String) == "tool_use",
                  let toolName = block["name"] as? String else {
                return false
            }
            return names.contains(toolName)
        }
    }

    func execute(
        name: String,
        input: [String: Any],
        context: CompanionCapabilityContext
    ) async -> CompanionCapabilityResult {
        guard let capability = capabilities[name] else {
            return .failure("unknown capability: \(name)")
        }

        return await capability.execute(input: input, context: context)
    }

    func executeToolUses(
        _ toolUses: [[String: Any]],
        context: CompanionCapabilityContext
    ) async -> (
        toolResults: [[String: Any]],
        effects: CompanionTurnEffects,
        executedActions: [CompanionExecutedAction]
    ) {
        var toolResults: [[String: Any]] = []
        var effects = CompanionTurnEffects()
        var executedActions: [CompanionExecutedAction] = []

        for toolUse in toolUses {
            guard let toolUseID = toolUse["id"] as? String,
                  let name = toolUse["name"] as? String,
                  let input = toolUse["input"] as? [String: Any] else {
                continue
            }

            let result = await execute(name: name, input: input, context: context)
            effects.merge(result.effects)
            executedActions.append(
                CompanionExecutedAction(
                    capabilityName: name,
                    resultContent: result.toolResultContent,
                    pointLabel: result.effects.pointTarget?.label
                )
            )

            toolResults.append([
                "type": "tool_result",
                "tool_use_id": toolUseID,
                "content": result.toolResultContent,
            ])
        }

        return (toolResults, effects, executedActions)
    }

    func executeAppAction(
        _ action: ClickyAppAction,
        context: CompanionCapabilityContext
    ) async -> String {
        switch action {
        case .openApp(let appName):
            let result = await execute(
                name: "open_app",
                input: ["app_name": appName],
                context: context
            )
            return result.toolResultContent

        case .openURL(let url, let browser, let newTab):
            var input: [String: Any] = [
                "url": url.absoluteString,
                "new_tab": newTab,
            ]
            if let browser {
                input["browser"] = browser
            }
            let result = await execute(name: "open_url", input: input, context: context)
            return result.toolResultContent

        case .spotifySearchAndPlay, .spotifyPlaybackControl:
            return await ClickyAppActionHandlerRegistry.executeLegacy(action)
        }
    }
}
