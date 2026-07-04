//
//  CompanionScreenContextDelta.swift
//  leanring-buddy
//
//  Detects meaningful screen context changes between walkthrough snapshots.
//

import Foundation

enum CompanionScreenContextDelta {

    /// Returns true when the user likely navigated away from the step's starting screen.
    static func hasMeaningfulChange(
        from before: ScreenContext?,
        to after: ScreenContext
    ) -> Bool {
        guard let before else { return false }

        if !before.app.isEmpty, !after.app.isEmpty, !appsMatch(before.app, after.app) {
            return true
        }

        if normalized(before.url) != normalized(after.url) {
            return true
        }

        if normalized(before.windowTitle) != normalized(after.windowTitle) {
            return true
        }

        return false
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func appsMatch(_ a: String, _ b: String) -> Bool {
        let left = a.lowercased()
        let right = b.lowercased()
        return left == right || left.contains(right) || right.contains(left)
    }
}
