//
//  ClickyNotchFallbackPillView.swift
//  leanring-buddy
//
//  Top-center hover target for Macs without a physical notch — shaped like
//  the MacBook menu-bar cutout (flat top, rounded bottom).
//

import Combine
import SwiftUI

@MainActor
final class ClickyNotchFallbackPillModel: ObservableObject {
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var audioPowerLevel: CGFloat = 0
}

private enum NotchTabShape {
    static let outline = UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 14,
        bottomTrailingRadius: 14,
        topTrailingRadius: 0,
        style: .continuous
    )
}

/// Flat top, generous bottom corners — reads like a small notch tab at the screen edge.
private struct NotchTabBackground: View {
    var body: some View {
        NotchTabShape.outline
            .fill(Color.black)
            .overlay {
                NotchTabShape.outline
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            }
    }
}

struct ClickyNotchFallbackPillView: View {
    @ObservedObject var model: ClickyNotchFallbackPillModel

    static let contentWidth: CGFloat = 156
    static let contentHeight: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            leadingFlank
            Spacer(minLength: 0)
            trailingFlank
        }
        .padding(.horizontal, 10)
        .frame(width: Self.contentWidth, height: Self.contentHeight)
        .background(notchBackground)
        .clipShape(NotchTabShape.outline)
        .fixedSize()
    }

    private var leadingFlank: some View {
        ClickyNotchIdleHandView(size: 16, isIdle: model.voiceState == .idle)
            .frame(width: 32, height: 24, alignment: .leading)
    }

    private var trailingFlank: some View {
        Group {
            switch model.voiceState {
            case .listening:
                notchMiniMeter
            case .checking, .processing:
                notchSpinner
            case .responding:
                notchPulseDot(color: DS.Colors.accentText)
            case .idle:
                notchPulseDot(color: DS.Colors.success)
            }
        }
        .frame(width: 32, height: 24, alignment: .trailing)
    }

    private var notchBackground: some View {
        NotchTabBackground()
    }

    private var notchMiniMeter: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(DS.Colors.accentText.opacity(0.55 + Double(index) * 0.12))
                    .frame(width: 3, height: max(4, min(14, 4 + model.audioPowerLevel * CGFloat(index + 1) * 10)))
            }
        }
    }

    private var notchSpinner: some View {
        NotchSpinnerIcon()
    }

    private func notchPulseDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.65), radius: 4)
    }
}

private struct NotchSpinnerIcon: View {
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
