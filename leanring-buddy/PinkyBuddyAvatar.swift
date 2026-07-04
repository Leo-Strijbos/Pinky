//
//  PinkyBuddyAvatar.swift
//  leanring-buddy
//
//  On-screen buddy hand assets — pointer (idle/navigation) and wave (welcome).
//

import SwiftUI

enum PinkyBuddyAvatar {
    /// Pointer finger asset is rotated 45° clockwise from its natural orientation.
    static let pointerClockwiseOffset: Double = 45

    /// Default rotation while following the cursor or pointing at a target.
    static let pointerIdleRotation: Double = pointerClockwiseOffset

    static let iconSize: CGFloat = 28

    /// Smaller wave hand for notch / menu-bar compact surfaces.
    static let notchIconSize: CGFloat = 18

    /// Pivot for the waving-hand rotation — lower-left of the wrist (normalized 0…1).
    static let waveRotationAnchor = UnitPoint(x: 0.4, y: 0.8)
}

// MARK: - Brand Glow

private struct PinkyBrandGlowModifier: ViewModifier {
    var intensity: CGFloat

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: 7 * intensity)
                .opacity(0.45 * intensity)

            content
                .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.85 * intensity), radius: 2)
                .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.6 * intensity), radius: 8)
                .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.35 * intensity), radius: 16 + (intensity - 1) * 18)
        }
    }
}

private struct PinkyBrandGlowSubtleModifier: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: 3)
                .opacity(0.18)

            content
                .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.35), radius: 2)
                .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.18), radius: 6)
        }
    }
}

extension View {
    func pinkyBrandGlow(intensity: CGFloat = 1.0) -> some View {
        modifier(PinkyBrandGlowModifier(intensity: intensity))
    }

    func pinkyBrandGlowSubtle() -> some View {
        modifier(PinkyBrandGlowSubtleModifier())
    }
}

// MARK: - Pointer Hand

struct PinkyHandPointerView: View {
    var rotationDegrees: Double
    var scale: CGFloat
    var glowIntensity: CGFloat

    var body: some View {
        Image("PinkyHandPointer")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: PinkyBuddyAvatar.iconSize, height: PinkyBuddyAvatar.iconSize)
            .rotationEffect(.degrees(rotationDegrees))
            .scaleEffect(scale)
            .pinkyBrandGlow(intensity: glowIntensity)
    }
}

// MARK: - Waving Hand

struct PinkyHandWaveView: View {
    var swingDegrees: Double
    var scale: CGFloat
    var glowIntensity: CGFloat

    var body: some View {
        Image("PinkyHandWave")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: PinkyBuddyAvatar.iconSize, height: PinkyBuddyAvatar.iconSize)
            .rotationEffect(.degrees(swingDegrees), anchor: PinkyBuddyAvatar.waveRotationAnchor)
            .scaleEffect(scale)
            .pinkyBrandGlow(intensity: glowIntensity)
    }
}

// MARK: - Notch Wave Icon

/// Compact waving hand for the MacBook notch and fallback menu-bar tab.
/// Plays a subtle wave every few seconds while idle.
struct PinkyNotchIdleHandView: View {
    var size: CGFloat = PinkyBuddyAvatar.notchIconSize
    var isIdle: Bool = true

    @State private var waveSwingDegrees: Double = 0
    @State private var idleWaveTimer: Timer?

    var body: some View {
        Image("PinkyHandWave")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .rotationEffect(.degrees(waveSwingDegrees), anchor: PinkyBuddyAvatar.waveRotationAnchor)
            .pinkyBrandGlowSubtle()
            .onAppear {
                startIdleWaveTimer()
                if isIdle {
                    playSubtleWave()
                }
            }
            .onDisappear {
                idleWaveTimer?.invalidate()
                idleWaveTimer = nil
            }
            .onChange(of: isIdle) { _, idle in
                if idle {
                    playSubtleWave()
                } else {
                    waveSwingDegrees = 0
                }
            }
    }

    private func startIdleWaveTimer() {
        idleWaveTimer?.invalidate()
        idleWaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            guard isIdle else { return }
            playSubtleWave()
        }
    }

    private func playSubtleWave() {
        waveSwingDegrees = 0
        withAnimation(.easeInOut(duration: 0.2).repeatCount(4, autoreverses: true)) {
            waveSwingDegrees = 12
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            withAnimation(.easeOut(duration: 0.2)) {
                waveSwingDegrees = 0
            }
        }
    }
}

/// Static notch wave icon — use `PinkyNotchIdleHandView` for the live notch surface.
struct PinkyNotchWaveIcon: View {
    var size: CGFloat = PinkyBuddyAvatar.notchIconSize

    var body: some View {
        Image("PinkyHandWave")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .pinkyBrandGlowSubtle()
    }
}
