//
//  CompanionCapabilityModels.swift
//  leanring-buddy
//
//  Shared types for the unified client-side capability registry.
//

import Foundation

enum CompanionCapabilityKind {
    /// Side effect with a short confirmation returned to the model.
    case act
    /// Reads local state and returns content to the model.
    case observe
}

enum CompanionCapabilityScope {
    /// Full agent turn — navigation, presentation, and reading.
    case agent
    /// Walkthrough guide step — pointing only.
    case guideStep
    /// Onboarding demo — pointing only.
    case onboarding
}

@MainActor
struct CompanionCapabilityContext {
    var screenCapture: CompanionScreenCapture?
    var documentWindowManager: ClickyDocumentWindowManager?
    var resultWindowManager: ClickyResultWindowManager?
    var copyableContentWindowManager: ClickyCopyableContentWindowManager?
    var onCopyableContentDelivered: ((ClickyCopyableContentPayload) -> Void)?

    static let empty = CompanionCapabilityContext()
}

struct CompanionTurnEffects: Equatable {
    var pointTarget: CompanionPointTarget?
    var panelPayload: ClickyWebResultPayload?
    var copyableContent: ClickyCopyableContentPayload?

    mutating func merge(_ other: CompanionTurnEffects) {
        if let pointTarget = other.pointTarget {
            self.pointTarget = pointTarget
        }
        if let panelPayload = other.panelPayload {
            self.panelPayload = panelPayload
        }
        if let copyableContent = other.copyableContent {
            self.copyableContent = copyableContent
        }
    }
}

struct CompanionCapabilityResult: Equatable {
    let toolResultContent: String
    let effects: CompanionTurnEffects
    let success: Bool

    static func success(_ message: String, effects: CompanionTurnEffects = CompanionTurnEffects()) -> CompanionCapabilityResult {
        CompanionCapabilityResult(toolResultContent: message, effects: effects, success: true)
    }

    static func failure(_ message: String) -> CompanionCapabilityResult {
        CompanionCapabilityResult(toolResultContent: message, effects: CompanionTurnEffects(), success: false)
    }
}

enum CompanionCapabilityInput {
    static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        return nil
    }

    static func boolValue(_ value: Any?, default defaultValue: Bool) -> Bool {
        if let boolValue = value as? Bool { return boolValue }
        return defaultValue
    }

    static func trimmedString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
