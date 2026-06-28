//
//  CompanionCapability.swift
//  leanring-buddy
//
//  Protocol for client-side agent capabilities (act + observe).
//

import Foundation

@MainActor
protocol CompanionCapability {
    var name: String { get }
    var kind: CompanionCapabilityKind { get }
    var scopes: Set<CompanionCapabilityScope> { get }
    var toolDefinition: [String: Any] { get }

    func execute(input: [String: Any], context: CompanionCapabilityContext) async -> CompanionCapabilityResult
}
