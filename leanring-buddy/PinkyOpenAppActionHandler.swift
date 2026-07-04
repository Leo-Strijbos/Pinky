//
//  PinkyOpenAppActionHandler.swift
//  leanring-buddy
//
//  Opens macOS applications by bundle ID or `open -a`.
//

import AppKit
import Foundation

struct PinkyOpenAppActionHandler: PinkyAppActionHandling {
    func execute(_ action: PinkyAppAction) async -> String? {
        guard case .openApp(let appName) = action else { return nil }
        return Self.openApplication(named: appName)
    }

    static func openApplication(named normalizedName: String) -> String {
        let displayName = PinkyKnownApplication.displayName(for: normalizedName)

        if let bundleIdentifier = PinkyKnownApplication.bundleIdentifiers[normalizedName],
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    print("⚠️ App open failed for \(displayName): \(error.localizedDescription)")
                }
            }
            print("📱 Opened app: \(displayName)")
            return "opening \(displayName)."
        }

        if runOpenCommand(arguments: ["-a", displayName]) {
            print("📱 Opened app via open -a: \(displayName)")
            return "opening \(displayName)."
        }

        print("⚠️ Could not open app: \(displayName)")
        return "i couldn't open \(displayName)."
    }

    @discardableResult
    static func runOpenCommand(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            print("⚠️ open command failed: \(error.localizedDescription)")
            return false
        }
    }
}
