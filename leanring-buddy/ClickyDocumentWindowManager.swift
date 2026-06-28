//
//  ClickyDocumentWindowManager.swift
//  leanring-buddy
//
//  Floating PDF panels for knowledge-base source documents.
//

import AppKit
import SwiftUI

private final class ClickyDocumentWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ClickyDocumentWindowManager {
    private var panel: ClickyDocumentWindowPanel?
    private var currentSources: [ClickyKnowledgeSourceDocument] = []

    func show(sources: [ClickyKnowledgeSourceDocument]) {
        guard !sources.isEmpty else { return }

        if panel == nil {
            createPanel()
        }

        currentSources = sources
        refreshPanelContent()
        positionPanel()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()

        let titles = sources.map(\.title).joined(separator: ", ")
        print("📄 Document panel: \(titles)")
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func refreshPanelContent() {
        guard let panel else { return }

        let documentView = ClickyDocumentPanelView(
            sources: currentSources,
            onClose: { [weak self] in
                self?.hide()
            },
            onOpenInPreview: { source in
                NSWorkspace.shared.open(source.fileURL)
            }
        )

        let hostingView = NSHostingView(rootView: documentView)
        hostingView.frame = panel.contentView?.bounds ?? .zero
        panel.contentView = hostingView
    }

    private func createPanel() {
        let placeholderView = ClickyDocumentPanelView(
            sources: [],
            onClose: { [weak self] in
                self?.hide()
            },
            onOpenInPreview: { _ in }
        )

        let hostingView = NSHostingView(rootView: placeholderView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 760)

        let documentPanel = ClickyDocumentWindowPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        documentPanel.titleVisibility = .hidden
        documentPanel.titlebarAppearsTransparent = true
        documentPanel.isFloatingPanel = true
        documentPanel.level = .floating
        documentPanel.isOpaque = true
        documentPanel.backgroundColor = .white
        documentPanel.hasShadow = true
        documentPanel.hidesOnDeactivate = false
        documentPanel.isExcludedFromWindowsMenu = true
        documentPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        documentPanel.contentView = hostingView
        documentPanel.isMovableByWindowBackground = true
        documentPanel.minSize = NSSize(width: 520, height: 560)

        panel = documentPanel
    }

    private func positionPanel() {
        guard let panel else { return }

        let defaultSize = NSSize(width: 640, height: 760)
        panel.setContentSize(defaultSize)

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let originX = screen.visibleFrame.midX - defaultSize.width / 2 + 180
            let originY = screen.visibleFrame.midY - defaultSize.height / 2
            panel.setFrame(
                NSRect(x: originX, y: originY, width: defaultSize.width, height: defaultSize.height),
                display: true
            )
        }
    }
}
