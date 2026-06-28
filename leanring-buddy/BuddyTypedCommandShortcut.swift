//
//  BuddyTypedCommandShortcut.swift
//  leanring-buddy
//
//  Global shortcut for opening the typed command palette (ctrl + globe).
//

import AppKit
import CoreGraphics
import Foundation

enum BuddyTypedCommandShortcut {
    enum ToggleTransition {
        case none
        case triggered
    }

    static let modifierFlags: NSEvent.ModifierFlags = [.control, .function]
    static let displayText = "ctrl + globe"

    static func toggleTransition(
        for eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ToggleTransition {
        guard eventType == .flagsChanged else { return .none }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        let isShortcutCurrentlyPressed = modifierFlags.isSuperset(of: Self.modifierFlags)

        if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
            return .triggered
        }

        return .none
    }
}
