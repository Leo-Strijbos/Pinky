//
//  PinkyCommandPaletteWindowManager.swift
//  leanring-buddy
//
//  Floating Spotlight-style command palette for typed requests.
//

import AppKit
import Combine
import SwiftUI

private final class PinkyCommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PinkyCommandPaletteWindowManager: ObservableObject {
    static let barWidth: CGFloat = 620
    static let barHeight: CGFloat = 56

    private weak var companionManager: CompanionManager?
    private var panel: PinkyCommandPalettePanel?
    @Published var queryText = ""
    @Published private(set) var isVisible = false
    private var escapeMonitor: Any?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            createPanel()
        }

        queryText = ""
        refreshContent()
        positionPanel()
        panel?.alphaValue = 0
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        isVisible = true
        installEscapeMonitor()

        NotificationCenter.default.post(name: .pinkyDismissPanel, object: nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel?.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }

        removeEscapeMonitor()
        isVisible = false

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    func submitCurrentQuery() {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        hide()
        companionManager?.submitTypedRequest(trimmed)
    }

    private func createPanel() {
        guard let companionManager else { return }

        let hostingView = makeHostingView(companionManager: companionManager)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.barWidth, height: Self.barHeight)

        let commandPanel = PinkyCommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.barWidth, height: Self.barHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        commandPanel.isFloatingPanel = true
        commandPanel.level = .modalPanel
        commandPanel.isOpaque = false
        commandPanel.backgroundColor = .clear
        commandPanel.hasShadow = true
        commandPanel.hidesOnDeactivate = false
        commandPanel.isExcludedFromWindowsMenu = true
        commandPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        commandPanel.contentView = hostingView
        panel = commandPanel
    }

    private func refreshContent() {
        guard let companionManager, let panel else { return }
        let hostingView = makeHostingView(companionManager: companionManager)
        hostingView.frame = panel.contentView?.bounds ?? NSRect(
            x: 0,
            y: 0,
            width: Self.barWidth,
            height: Self.barHeight
        )
        panel.contentView = hostingView
    }

    private func makeHostingView(companionManager: CompanionManager) -> NSHostingView<PinkyCommandPaletteView> {
        NSHostingView(
            rootView: PinkyCommandPaletteView(windowManager: self)
        )
    }

    private func positionPanel() {
        guard let panel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = targetScreen else { return }

        let originX = screen.frame.midX - Self.barWidth / 2
        let originY = screen.frame.midY + Self.barHeight * 0.35

        panel.setFrame(
            NSRect(x: originX, y: originY, width: Self.barWidth, height: Self.barHeight),
            display: true
        )
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.isVisible == true else { return event }
            if event.keyCode == 53 {
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}
