//
//  CompanionAgentModels.swift
//  leanring-buddy
//
//  Structured results from the single voice agent turn.
//

import CoreGraphics
import Foundation

struct CompanionPointTarget: Equatable {
    let x: Int
    let y: Int
    let label: String
}

struct CompanionAgentTurnResult: Equatable {
    let spokenText: String
    let sources: [ClickyWebSource]
    let usedWebSearch: Bool
    let pointTarget: CompanionPointTarget?
    let panelPayload: ClickyWebResultPayload?
}
