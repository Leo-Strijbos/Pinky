//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private var resultWindowManager: PinkyResultWindowManager?
    private var documentWindowManager: PinkyDocumentWindowManager?
    private var copyableContentWindowManager: PinkyCopyableContentWindowManager?
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Pinky: Starting...")
        print("🎯 Pinky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        PinkyAnalytics.configure()
        PinkyAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        resultWindowManager = PinkyResultWindowManager()
        let documentWindowManager = PinkyDocumentWindowManager()
        let copyableContentWindowManager = PinkyCopyableContentWindowManager()
        companionManager.resultWindowManager = resultWindowManager
        companionManager.documentWindowManager = documentWindowManager
        companionManager.copyableContentWindowManager = copyableContentWindowManager
        self.documentWindowManager = documentWindowManager
        self.copyableContentWindowManager = copyableContentWindowManager
        companionManager.start()
        menuBarPanelManager?.startNotchSurface()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Pinky: Registered as login item")
            } catch {
                print("⚠️ Pinky: Failed to register as login item: \(error)")
            }
        }
    }
}
