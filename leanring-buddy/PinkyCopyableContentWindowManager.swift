//
//  PinkyCopyableContentWindowManager.swift
//  leanring-buddy
//
//  Owns floating panels for generated copyable content.
//

import AppKit
import SwiftUI

private final class PinkyCopyableContentWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PinkyCopyableContentWindowManager {
    private var panel: PinkyCopyableContentWindowPanel?
    private var currentPayload: PinkyCopyableContentPayload?

    func show(_ payload: PinkyCopyableContentPayload) {
        if panel == nil {
            createPanel()
        }

        currentPayload = payload
        refreshPanelContent()
        positionPanel()
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()

        print("📋 Copyable content panel: \(payload.kind.rawValue) → \(payload.title)")
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func refreshPanelContent() {
        guard let panel, let payload = currentPayload else { return }

        let contentView = PinkyCopyableContentPanelView(
            payload: payload,
            onClose: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = panel.contentView?.bounds ?? .zero
        panel.contentView = hostingView
    }

    private func createPanel() {
        let placeholderPayload = PinkyCopyableContentPayload(
            title: "Loading…",
            body: "",
            kind: .text
        )

        let contentView = PinkyCopyableContentPanelView(
            payload: placeholderPayload,
            onClose: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 520)

        let contentPanel = PinkyCopyableContentWindowPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        contentPanel.titleVisibility = .hidden
        contentPanel.titlebarAppearsTransparent = true
        contentPanel.isFloatingPanel = true
        contentPanel.level = .floating
        contentPanel.isOpaque = true
        contentPanel.backgroundColor = .white
        contentPanel.hasShadow = true
        contentPanel.hidesOnDeactivate = false
        contentPanel.isExcludedFromWindowsMenu = true
        contentPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentPanel.contentView = hostingView
        contentPanel.isMovableByWindowBackground = true
        contentPanel.minSize = NSSize(width: 480, height: 320)

        panel = contentPanel
    }

    private func positionPanel() {
        guard let panel else { return }

        let defaultSize = NSSize(width: 640, height: 520)
        panel.setContentSize(defaultSize)

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let originX = screen.visibleFrame.midX - defaultSize.width / 2 + 120
            let originY = screen.visibleFrame.midY - defaultSize.height / 2
            panel.setFrame(
                NSRect(x: originX, y: originY, width: defaultSize.width, height: defaultSize.height),
                display: true
            )
        }
    }
}
