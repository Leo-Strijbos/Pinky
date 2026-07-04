//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let pinkyDismissPanel = Notification.Name("pinkyDismissPanel")
    static let pinkyShowPanel = Notification.Name("pinkyShowPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var fallbackPillPanel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?
    private var notchHoverProbeTimer: Timer?
    private var voiceStateCancellables = Set<AnyCancellable>()

    private let companionManager: CompanionManager
    private let dynamicNotchBridge = PinkyDynamicNotchBridge()
    private let fallbackPillModel = PinkyNotchFallbackPillModel()
    private let panelWidth: CGFloat = PinkyResponsePanelLayout.width
    private let panelHeight: CGFloat = PinkyResponsePanelLayout.height
    private static var fallbackPillContentSize: NSSize {
        NSSize(
            width: PinkyNotchFallbackPillView.contentWidth,
            height: PinkyNotchFallbackPillView.contentHeight
        )
    }
    private var usesNotchDropdownPosition = false
    private var isUsingDynamicNotchSurface = false
    private var notchSurfaceDisplayID: CGDirectDisplayID?
    private var panelOpenedFromNotchHover = false
    private var anchorScreen: NSScreen?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()
        observeVoiceStateForNotch()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .pinkyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .pinkyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let screen = PinkyNotchScreenSupport.preferredNotchScreen() {
                self.showPanelFromNotchInteraction(on: screen)
            } else {
                self.showPanel()
            }
        }
    }

    deinit {
        notchHoverProbeTimer?.invalidate()
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Starts the top-of-screen notch surface and hover probe that reveals the
    /// settings panel when the pointer enters the notch region.
    func startNotchSurface() {
        guard let screen = PinkyNotchScreenSupport.preferredNotchScreen() else { return }

        anchorScreen = screen
        updateStatusItemVisibility()

        if PinkyNotchScreenSupport.hasPhysicalNotch(on: screen) {
            isUsingDynamicNotchSurface = true
            notchSurfaceDisplayID = screen.displayID
            dynamicNotchBridge.showCompact(on: screen) { [weak self] in
                self?.showPanelFromNotchInteraction(on: screen)
            }
        } else if PinkyNotchScreenSupport.hasBuiltInNotchDisplay() {
            isUsingDynamicNotchSurface = false
            notchSurfaceDisplayID = screen.displayID
        } else {
            isUsingDynamicNotchSurface = false
            notchSurfaceDisplayID = screen.displayID
            ensureFallbackPill(on: screen)
        }

        startNotchHoverProbe()
        syncNotchVoiceState()
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makePinkyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItemVisibility()
    }

    private func updateStatusItemVisibility() {
        if #available(macOS 13.0, *) {
            statusItem?.isVisible = !PinkyNotchScreenSupport.hasBuiltInNotchDisplay()
        }
    }

    /// Draws the pinky triangle as a menu bar icon. Uses the same shape
    /// and rotation as the in-app cursor so the menu bar icon matches.
    private func makePinkyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if PinkyNotchScreenSupport.hasBuiltInNotchDisplay(),
               let screen = PinkyNotchScreenSupport.preferredNotchScreen() {
                self.showPanelFromNotchInteraction(on: screen)
            } else {
                self.usesNotchDropdownPosition = false
                self.panelOpenedFromNotchHover = false
                self.showPanel()
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemContextMenu(from: sender)
            return
        }

        usesNotchDropdownPosition = false
        panelOpenedFromNotchHover = false
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showStatusItemContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open Pinky",
            action: #selector(openPanelFromStatusMenu),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Pinky",
            action: #selector(quitFromStatusMenu),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: quitItem, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func openPanelFromStatusMenu() {
        usesNotchDropdownPosition = false
        panelOpenedFromNotchHover = false
        showPanel()
    }

    @objc private func quitFromStatusMenu() {
        NSApp.terminate(nil)
    }

    // MARK: - Notch Surface

    private func observeVoiceStateForNotch() {
        companionManager.$voiceState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] voiceState in
                guard let self else { return }
                self.dynamicNotchBridge.updateVoiceState(
                    voiceState,
                    audioPowerLevel: self.companionManager.currentAudioPowerLevel
                )
                self.fallbackPillModel.voiceState = voiceState
            }
            .store(in: &voiceStateCancellables)

        companionManager.$currentAudioPowerLevel
            .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] audioPowerLevel in
                guard let self else { return }
                self.dynamicNotchBridge.updateVoiceState(
                    self.companionManager.voiceState,
                    audioPowerLevel: audioPowerLevel
                )
                self.fallbackPillModel.audioPowerLevel = audioPowerLevel
            }
            .store(in: &voiceStateCancellables)
    }

    private func syncNotchVoiceState() {
        dynamicNotchBridge.updateVoiceState(
            companionManager.voiceState,
            audioPowerLevel: companionManager.currentAudioPowerLevel
        )
        fallbackPillModel.voiceState = companionManager.voiceState
        fallbackPillModel.audioPowerLevel = companionManager.currentAudioPowerLevel
    }

    private func startNotchHoverProbe() {
        notchHoverProbeTimer?.invalidate()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.probeNotchHover()
        }
        notchHoverProbeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func probeNotchHover() {
        let mouseLocation = NSEvent.mouseLocation

        if let hoveredScreen = NSScreen.screens.first(where: {
            PinkyNotchScreenSupport.notchHoverRegion(on: $0).contains(mouseLocation)
        }) {
            anchorScreen = hoveredScreen
            ensureNotchSurface(on: hoveredScreen)

            if let panel, panel.isVisible {
                return
            }

            showPanelFromNotchInteraction(on: hoveredScreen)
            return
        }

        guard panelOpenedFromNotchHover, let panel, panel.isVisible else { return }
        if panel.frame.contains(mouseLocation) {
            return
        }

        hidePanel()
    }

    private func ensureNotchSurface(on screen: NSScreen) {
        guard notchSurfaceDisplayID != screen.displayID else { return }
        notchSurfaceDisplayID = screen.displayID

        if PinkyNotchScreenSupport.hasPhysicalNotch(on: screen) {
            isUsingDynamicNotchSurface = true
            fallbackPillPanel?.orderOut(nil)
            dynamicNotchBridge.showCompact(on: screen) { [weak self] in
                self?.showPanelFromNotchInteraction(on: screen)
            }
        } else if PinkyNotchScreenSupport.hasBuiltInNotchDisplay() {
            // MacBook with a built-in notch: keep DynamicNotchKit on the laptop
            // display and use an invisible hover target on external monitors.
            isUsingDynamicNotchSurface = false
            fallbackPillPanel?.orderOut(nil)
        } else {
            isUsingDynamicNotchSurface = false
            dynamicNotchBridge.hide()
            ensureFallbackPill(on: screen)
        }

        updateStatusItemVisibility()
    }

    private func showPanelFromNotchInteraction(on screen: NSScreen) {
        usesNotchDropdownPosition = true
        panelOpenedFromNotchHover = true
        anchorScreen = screen
        showPanel(on: screen)
    }

    private func ensureFallbackPill(on screen: NSScreen) {
        if fallbackPillPanel == nil {
            createFallbackPillPanel(on: screen)
        } else {
            positionFallbackPill(on: screen)
            fallbackPillPanel?.orderFrontRegardless()
        }
    }

    private func createFallbackPillPanel(on screen: NSScreen) {
        let pillView = PinkyNotchFallbackPillView(model: fallbackPillModel)

        let hostingView = NSHostingView(rootView: pillView)
        hostingView.frame = NSRect(origin: .zero, size: Self.fallbackPillContentSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let pillPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.fallbackPillContentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        pillPanel.isFloatingPanel = true
        pillPanel.level = .statusBar
        pillPanel.isOpaque = false
        pillPanel.backgroundColor = .clear
        pillPanel.hasShadow = false
        pillPanel.hidesOnDeactivate = false
        pillPanel.isExcludedFromWindowsMenu = true
        pillPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pillPanel.contentView = hostingView
        fallbackPillPanel = pillPanel
        positionFallbackPill(on: screen)
        pillPanel.orderFrontRegardless()
    }

    private func positionFallbackPill(on screen: NSScreen) {
        guard let fallbackPillPanel else { return }

        let pillSize = Self.fallbackPillContentSize
        let originX = screen.frame.midX - pillSize.width / 2
        let originY = PinkyNotchScreenSupport.statusSurfaceY(for: pillSize, on: screen)
        fallbackPillPanel.setFrame(
            NSRect(x: originX, y: originY, width: pillSize.width, height: pillSize.height),
            display: true
        )
    }

    // MARK: - Panel Lifecycle

    private func showPanel(on screen: NSScreen? = nil) {
        if panel == nil {
            createPanel()
        }

        positionPanel(on: screen)

        if usesNotchDropdownPosition {
            panel?.level = .popUpMenu
            panel?.orderFrontRegardless()
        } else {
            panel?.level = .floating
            panel?.makeKeyAndOrderFront(nil)
            panel?.orderFrontRegardless()
        }

        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
        panelOpenedFromNotchHover = false
        usesNotchDropdownPosition = false
    }

    private func createPanel() {
        let companionPanelView = PinkyResponsePanelView(companionManager: companionManager)
            .frame(width: panelWidth, height: panelHeight)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanel(on screen: NSScreen? = nil) {
        guard let panel else { return }

        let actualPanelHeight = panelHeight

        if usesNotchDropdownPosition, let notchScreen = screen ?? anchorScreen ?? PinkyNotchScreenSupport.preferredNotchScreen() {
            let panelSize = NSSize(width: panelWidth, height: actualPanelHeight)
            let origin = PinkyNotchScreenSupport.dropdownPanelOrigin(for: panelSize, on: notchScreen)
            panel.setFrame(
                NSRect(x: origin.x, y: origin.y, width: panelWidth, height: actualPanelHeight),
                display: true
            )
            return
        }

        positionPanelBelowStatusItem(actualPanelHeight: actualPanelHeight)
    }

    private func positionPanelBelowStatusItem(actualPanelHeight: CGFloat? = nil) {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4
        let resolvedPanelHeight = actualPanelHeight
            ?? panel.contentView?.fittingSize.height
            ?? panelHeight

        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - resolvedPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: resolvedPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
