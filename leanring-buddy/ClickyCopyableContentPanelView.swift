//
//  ClickyCopyableContentPanelView.swift
//  leanring-buddy
//
//  Floating panel for copyable generated content (code, commands, JSON, etc.).
//

import AppKit
import SwiftUI

struct ClickyCopyableContentPanelView: View {
    let payload: ClickyCopyableContentPayload
    let onClose: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.black.opacity(0.08))
            content
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: payload.kind.systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.accentText)
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.05), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(payload.kind.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.88))
                HStack(spacing: 6) {
                    Text(payload.title)
                        .lineLimit(1)
                    if let language = payload.language {
                        Text(language)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.06), in: Capsule())
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.45))
            }

            Spacer()

            Button(action: copyToPasteboard) {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(didCopy ? DS.Colors.success : Color.black.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Copy to clipboard")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .background(Color.black.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white)
    }

    private var content: some View {
        ScrollView {
            Text(payload.body)
                .font(contentFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var contentFont: Font {
        switch payload.kind {
        case .code, .command, .json:
            return .system(.body, design: .monospaced)
        case .text:
            return .system(.body, design: .default)
        }
    }

    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload.body, forType: .string)
        didCopy = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }
}
