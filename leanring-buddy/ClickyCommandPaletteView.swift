//
//  ClickyCommandPaletteView.swift
//  leanring-buddy
//
//  Minimal Spotlight-style typed command bar.
//

import SwiftUI

struct ClickyCommandPaletteView: View {
    @ObservedObject var windowManager: ClickyCommandPaletteWindowManager

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DS.Glass.textSecondary.opacity(0.85))

            TextField("Ask Clicky anything…", text: $windowManager.queryText)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(DS.Glass.textPrimary)
                .focused($isFieldFocused)
                .onSubmit {
                    windowManager.submitCurrentQuery()
                }

            if !windowManager.queryText.isEmpty {
                Button(action: { windowManager.queryText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.Glass.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassSpotlightBar()
        .onAppear {
            isFieldFocused = true
        }
        .background {
            Button("") {
                windowManager.hide()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }
}
