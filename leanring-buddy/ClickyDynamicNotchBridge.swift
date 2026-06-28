//
//  ClickyDynamicNotchBridge.swift
//  leanring-buddy
//
//  Minimal DynamicNotchKit integration: compact Clicky presence in the
//  MacBook notch. Tap or hover label opens the response panel beneath the notch.
//

import AppKit
import Combine
import SwiftUI

#if canImport(DynamicNotchKit)
import DynamicNotchKit

@MainActor
private final class ClickyDynamicNotchModel: ObservableObject {
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var audioPowerLevel: CGFloat = 0
    @Published var isExpanded = false

    var openPanel: () -> Void = {}
}

@MainActor
final class ClickyDynamicNotchBridge {
    private let model = ClickyDynamicNotchModel()
    private var targetScreen: NSScreen?

    private lazy var notch: DynamicNotch<
        ClickyNotchExpandedView,
        ClickyNotchCompactLeadingView,
        ClickyNotchCompactTrailingView
    > = {
        let notch = DynamicNotch(
            hoverBehavior: [.hapticFeedback, .increaseShadow],
            style: .notch(topCornerRadius: 13, bottomCornerRadius: 18)
        ) {
            ClickyNotchExpandedView(model: self.model)
        } compactLeading: {
            ClickyNotchCompactLeadingView(model: self.model)
        } compactTrailing: {
            ClickyNotchCompactTrailingView(model: self.model)
        }

        notch.transitionConfiguration.skipIntermediateHides = true
        return notch
    }()

    func showCompact(on screen: NSScreen, openPanel: @escaping () -> Void) {
        targetScreen = screen
        model.openPanel = openPanel
        model.isExpanded = false
        Task { await notch.compact(on: screen) }
    }

    func updateVoiceState(_ voiceState: CompanionVoiceState, audioPowerLevel: CGFloat) {
        model.voiceState = voiceState
        model.audioPowerLevel = audioPowerLevel
    }

    func hide() {
        Task { await notch.hide() }
    }
}

// MARK: - Compact Views

private struct ClickyNotchCompactLeadingView: View {
    @ObservedObject var model: ClickyDynamicNotchModel

    var body: some View {
        ClickyNotchIdleHandView(isIdle: model.voiceState == .idle)
            .frame(width: 22, height: 22)
            .frame(width: 32, height: 24, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.openPanel() }
            .accessibilityLabel("Clicky")
    }
}

private struct ClickyNotchCompactTrailingView: View {
    @ObservedObject var model: ClickyDynamicNotchModel

    var body: some View {
        Group {
            switch model.voiceState {
            case .listening:
                ClickyNotchMiniMeter(level: model.audioPowerLevel)
            case .checking, .processing:
                ClickyNotchSpinnerIcon()
            case .responding:
                ClickyNotchPulseDot(color: DS.Colors.accentText)
            case .idle:
                ClickyNotchPulseDot(color: DS.Colors.success)
            }
        }
        .frame(width: 32, height: 24, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { model.openPanel() }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch model.voiceState {
        case .idle: return "Clicky ready"
        case .listening: return "Listening"
        case .checking: return "Watching"
        case .processing: return "Processing"
        case .responding: return "Responding"
        }
    }
}

/// Drops down the response panel beneath the notch.
private struct ClickyNotchExpandedView: View {
    @ObservedObject var model: ClickyDynamicNotchModel

    var body: some View {
        HStack(spacing: 8) {
            ClickyNotchIdleHandView(size: 14, isIdle: model.voiceState == .idle)
            Text("Clicky")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Glass.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.85)))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.openPanel() }
        .accessibilityLabel("Open Clicky panel")
    }
}

// MARK: - Shared Notch Visuals

private struct ClickyNotchPulseDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.65), radius: 4)
    }
}

private struct ClickyNotchSpinnerIcon: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                DS.Colors.accentText,
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

private struct ClickyNotchMiniMeter: View {
    let level: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(DS.Colors.accentText.opacity(0.55 + Double(index) * 0.12))
                    .frame(width: 3, height: max(4, min(14, 4 + (level * CGFloat(index + 1) * 10))))
            }
        }
    }
}

#else

@MainActor
final class ClickyDynamicNotchBridge {
    func showCompact(on screen: NSScreen, openPanel: @escaping () -> Void) {}
    func updateVoiceState(_ voiceState: CompanionVoiceState, audioPowerLevel: CGFloat) {}
    func hide() {}
}

#endif
