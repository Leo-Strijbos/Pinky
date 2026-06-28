//
//  ClickyResultWindowManager.swift
//  leanring-buddy
//
//  Owns floating WebView result panels for stock charts and places lookups.
//

import AppKit
import SwiftUI

private final class ClickyResultWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ClickyResultWindowManager {
    private var panel: ClickyResultWindowPanel?
    private var currentPayload: ClickyWebResultPayload?

    func show(_ payload: ClickyWebResultPayload) {
        if panel == nil {
            createPanel()
        }

        currentPayload = payload
        refreshPanelContent()
        positionPanel(for: payload.kind)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()

        print("🪟 Web result panel: \(payload.kind.rawValue) → \(payload.url.absoluteString)")
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func refreshPanelContent() {
        guard let panel, let payload = currentPayload else { return }

        let resultView = ClickyResultPanelView(
            payload: payload,
            onClose: { [weak self] in
                self?.hide()
            },
            onOpenInBrowser: {
                NSWorkspace.shared.open(payload.url)
            }
        )

        let hostingView = NSHostingView(rootView: resultView)
        hostingView.frame = panel.contentView?.bounds ?? .zero
        panel.contentView = hostingView
    }

    private func createPanel() {
        let placeholderPayload = ClickyWebResultPayload(
            kind: .placesMap,
            title: "Loading…",
            url: URL(string: "about:blank")!
        )

        let resultView = ClickyResultPanelView(
            payload: placeholderPayload,
            onClose: { [weak self] in
                self?.hide()
            },
            onOpenInBrowser: {}
        )

        let hostingView = NSHostingView(rootView: resultView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 640)

        let resultPanel = ClickyResultWindowPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        resultPanel.titleVisibility = .hidden
        resultPanel.titlebarAppearsTransparent = true
        resultPanel.isFloatingPanel = true
        resultPanel.level = .floating
        resultPanel.isOpaque = true
        resultPanel.backgroundColor = .white
        resultPanel.hasShadow = true
        resultPanel.hidesOnDeactivate = false
        resultPanel.isExcludedFromWindowsMenu = true
        resultPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        resultPanel.contentView = hostingView
        resultPanel.isMovableByWindowBackground = true
        resultPanel.minSize = NSSize(width: 480, height: 520)

        panel = resultPanel
    }

    private func positionPanel(for kind: ClickyWebResultKind) {
        guard let panel else { return }

        let defaultSize = kind == .stockChart
            ? NSSize(width: 720, height: 640)
            : NSSize(width: 560, height: 680)
        panel.setContentSize(defaultSize)

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let originX = screen.visibleFrame.midX - defaultSize.width / 2
            let originY = screen.visibleFrame.midY - defaultSize.height / 2
            panel.setFrame(
                NSRect(x: originX, y: originY, width: defaultSize.width, height: defaultSize.height),
                display: true
            )
        }
    }
}
