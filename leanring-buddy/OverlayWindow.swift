//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it rests in the notch,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy sits in the notch
    case restingAtNotch
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when idle. During voice interaction, the triangle is
// replaced by a waveform (listening) or spinner (processing).
// The triangle stays visible while idle and while Pinky speaks.
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var buddyPosition: CGPoint
    @State private var cursorIndicatorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        let initialCursorIndicator = CGPoint(x: localX + 35, y: localY + 25)
        _cursorIndicatorPosition = State(initialValue: initialCursorIndicator)
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))

        let hostScreen = NSScreen.screens.first { $0.frame == screenFrame }
        if let hostScreen, PinkyNotchScreenSupport.isNotchHostScreen(hostScreen) {
            let notchPoint = PinkyNotchScreenSupport.buddyHandScreenPoint(on: hostScreen)
            let x = notchPoint.x - screenFrame.origin.x
            let y = screenFrame.height - (notchPoint.y - screenFrame.origin.y)
            _buddyPosition = State(initialValue: CGPoint(x: x, y: y))
        } else {
            _buddyPosition = State(initialValue: .zero)
        }
    }

    @State private var cursorTrackingTimer: Timer?

    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var buddyOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (resting in notch, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .restingAtNotch

    /// The rotation angle of the buddy hand in degrees.
    /// Default is 45° (pointer asset orientation). Changes to face travel direction when navigating.
    @State private var buddyRotationDegrees: Double = PinkyBuddyAvatar.pointerIdleRotation

    /// True during the first-open welcome wave before switching to the pointer hand.
    @State private var isShowingWelcomeWave = false

    /// Side-to-side rotation applied to the waving hand during the welcome animation.
    @State private var waveSwingDegrees: Double = 0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the overlay should render the buddy (pointing flights, welcome).
    /// At rest the live hand lives in the notch UI only.
    private var showsActiveOverlayBuddy: Bool {
        isShowingWelcomeWave || buddyNavigationMode != .restingAtNotch
    }

    private let fullWelcomeMessage = "hey! i'm pinky"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if isNotchHostScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBrand)
                            .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: buddyPosition.x + 10 + (bubbleSize.width / 2), y: buddyPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: buddyPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding prompt — streamed after the welcome animation
            if isNotchHostScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBrand)
                            .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: buddyPosition.x + 10 + (bubbleSize.width / 2), y: buddyPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: buddyPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBrand)
                            .shadow(
                                color: DS.Colors.overlayCursorBrand.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: buddyPosition.x + 10 + (navigationBubbleSize.width / 2), y: buddyPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: buddyPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Waving hand — first launch welcome only.
            PinkyHandWaveView(
                swingDegrees: waveSwingDegrees,
                scale: buddyFlightScale,
                glowIntensity: buddyFlightScale
            )
            .opacity(
                buddyIsVisibleOnThisScreen && isShowingWelcomeWave ? buddyOpacity : 0
            )
            .position(buddyPosition)
            .animation(.easeInOut(duration: 0.18), value: waveSwingDegrees)

            // Pointer hand — pointing flights only (idle hand lives in the notch).
            PinkyHandPointerView(
                rotationDegrees: buddyRotationDegrees,
                scale: buddyFlightScale,
                glowIntensity: buddyFlightScale
            )
            .opacity(
                buddyIsVisibleOnThisScreen
                    && showsActiveOverlayBuddy
                    && !isShowingWelcomeWave
                    ? buddyOpacity : 0
            )
            .position(buddyPosition)
            .animation(
                buddyNavigationMode == .restingAtNotch ? nil : .spring(response: 0.2, dampingFraction: 0.6),
                value: buddyPosition
            )
            .animation(
                buddyNavigationMode == .navigatingToTarget || buddyNavigationMode == .pointingAtTarget
                    ? nil
                    : .easeInOut(duration: 0.3),
                value: buddyRotationDegrees
            )

            // Waveform — next to the cursor while the user is speaking.
            BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                .opacity(isCursorOnThisScreen && companionManager.voiceState == .listening ? 1 : 0)
                .position(cursorIndicatorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorIndicatorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Spinner — next to the cursor while Pinky is checking or processing.
            BlueCursorSpinnerView()
                .opacity(
                    isCursorOnThisScreen
                        && (companionManager.voiceState == .processing
                            || companionManager.voiceState == .checking)
                        ? 1 : 0
                )
                .position(cursorIndicatorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorIndicatorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Teaching pill — beside the cursor while Pinky is learning a workflow.
            TeachingPillView(
                stepCount: companionManager.teachingStepCount,
                isProcessing: companionManager.isTeachingProcessing
            )
            .opacity(
                isCursorOnThisScreen
                    && (companionManager.isTeaching || companionManager.isTeachingProcessing)
                    ? 1 : 0
            )
            .allowsHitTesting(false)
            .position(
                x: cursorIndicatorPosition.x + 56,
                y: cursorIndicatorPosition.y - 4
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorIndicatorPosition)
            .animation(.easeInOut(duration: 0.2), value: companionManager.isTeaching)
            .animation(.easeInOut(duration: 0.2), value: companionManager.teachingStepCount)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            syncBuddyToNotch()
            startCursorIndicatorTracking()
            attemptPointingAnimationIfNeeded()

            if isFirstAppearance && isNotchHostScreen {
                startWelcomeWaveAnimation()
                withAnimation(.easeIn(duration: 2.0)) {
                    self.buddyOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else if isNotchHostScreen {
                self.buddyOpacity = 0.0
            }
        }
        .onDisappear {
            cursorTrackingTimer?.invalidate()
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            guard newLocation != nil else { return }
            attemptPointingAnimationIfNeeded()
        }
        .onChange(of: companionManager.pointingRequestEpoch) { _ in
            attemptPointingAnimationIfNeeded()
        }
    }

    private func overlayOwnsCurrentPoint() -> Bool {
        guard companionManager.detectedElementScreenLocation != nil else { return false }

        if let displayFrame = companionManager.detectedElementDisplayFrame {
            return displayFrame == screenFrame
        }

        return isNotchHostScreen
    }

    private func attemptPointingAnimationIfNeeded() {
        guard let screenLocation = companionManager.detectedElementScreenLocation else { return }
        guard overlayOwnsCurrentPoint() else { return }
        startNavigatingToElement(screenLocation: screenLocation)
    }

    private var hostScreen: NSScreen? {
        NSScreen.screens.first { $0.frame == screenFrame }
    }

    private var isNotchHostScreen: Bool {
        guard let hostScreen else { return false }
        return PinkyNotchScreenSupport.isNotchHostScreen(hostScreen)
    }

    /// Whether the overlay buddy should render on this screen.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .restingAtNotch:
            guard isNotchHostScreen, showsActiveOverlayBuddy else { return false }
            return companionManager.detectedElementScreenLocation == nil
        case .navigatingToTarget, .pointingAtTarget:
            return overlayOwnsCurrentPoint()
        }
    }

    private func notchHandPositionInSwiftUI() -> CGPoint {
        guard let hostScreen else { return buddyPosition }
        let notchPoint = PinkyNotchScreenSupport.buddyHandScreenPoint(on: hostScreen)
        return convertScreenPointToSwiftUICoordinates(notchPoint)
    }

    private func syncBuddyToNotch() {
        guard isNotchHostScreen, buddyNavigationMode == .restingAtNotch else { return }
        buddyPosition = notchHandPositionInSwiftUI()
    }

    private func startCursorIndicatorTracking() {
        let mouseLocation = NSEvent.mouseLocation
        isCursorOnThisScreen = screenFrame.contains(mouseLocation)
        cursorIndicatorPosition = cursorIndicatorPosition(near: mouseLocation)

        cursorTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)
            guard self.isCursorOnThisScreen else { return }
            self.cursorIndicatorPosition = self.cursorIndicatorPosition(near: mouseLocation)
        }
    }

    private func cursorIndicatorPosition(near screenPoint: CGPoint) -> CGPoint {
        let swiftUIPosition = convertScreenPointToSwiftUICoordinates(screenPoint)
        return CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Launch from the notch on the host screen; fade in near the target elsewhere.
        buddyOpacity = 1.0
        if isNotchHostScreen {
            buddyPosition = notchHandPositionInSwiftUI()
        } else {
            buddyPosition = clampedTarget
        }
        buddyRotationDegrees = PinkyBuddyAvatar.pointerIdleRotation

        // Enter navigation mode
        buddyNavigationMode = .navigatingToTarget

        if isNotchHostScreen {
            animateBezierFlightArc(to: clampedTarget, rotateAlongPath: true) {
                guard self.buddyNavigationMode == .navigatingToTarget else { return }
                self.startPointingAtElement()
            }
        } else {
            startPointingAtElement()
        }
    }

    /// Quintic ease-in-out — pronounced slow start, fast middle, slow finish.
    private func easeInOutQuint(_ linearProgress: Double) -> Double {
        let clamped = min(max(linearProgress, 0), 1)
        if clamped < 0.5 {
            return 16 * clamped * clamped * clamped * clamped * clamped
        }
        let t = clamped - 1
        return 1 + 16 * t * t * t * t * t
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. Optional path-aligned rotation on outbound
    /// flights only; return flights keep the idle pointer angle.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        rotateAlongPath: Bool,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = buddyPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.buddyPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Eased progress drives position along the arc (slow → fast → slow).
            let linearProgress = Double(currentFrame) / Double(totalFrames)
            let easedProgress = easeInOutQuint(linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - easedProgress
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * easedProgress * controlPoint.x
                        + easedProgress * easedProgress * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * easedProgress * controlPoint.y
                        + easedProgress * easedProgress * endPosition.y

            self.buddyPosition = CGPoint(x: bezierX, y: bezierY)

            if rotateAlongPath {
                // Rotation: face the direction of travel (tangent to the curve).
                let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                             + 2.0 * easedProgress * (endPosition.x - controlPoint.x)
                let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                             + 2.0 * easedProgress * (endPosition.y - controlPoint.y)
                self.buddyRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0
            }

            // Scale pulse peaks when the flight is moving fastest (middle of eased progress).
            let scalePulse = sin(easedProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Rotate back to default pointer angle now that we've arrived
        buddyRotationDegrees = PinkyBuddyAvatar.pointerIdleRotation

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToNotch()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the notch after pointing is done.
    private func startFlyingBackToNotch() {
        buddyNavigationMode = .navigatingToTarget

        animateBezierFlightArc(to: notchHandPositionInSwiftUI(), rotateAlongPath: false) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Returns the buddy to the notch after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .restingAtNotch
        buddyRotationDegrees = PinkyBuddyAvatar.pointerIdleRotation
        buddyFlightScale = 1.0
        buddyOpacity = 0.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        syncBuddyToNotch()
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    /// Plays a side-to-side wave with the welcome hand, then cross-fades to the pointer.
    private func startWelcomeWaveAnimation() {
        isShowingWelcomeWave = true
        waveSwingDegrees = 0

        withAnimation(.easeInOut(duration: 0.18).repeatCount(6, autoreverses: true)) {
            waveSwingDegrees = 28
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            withAnimation(.easeOut(duration: 0.25)) {
                self.waveSwingDegrees = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.isShowingWelcomeWave = false
            }
        }
    }

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    self.companionManager.finishWelcomeAnimation()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Cursor Voice Indicators

/// Animated bars beside the cursor while the user holds push-to-talk and speaks.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBrand)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Cursor Spinner

/// Spinning indicator beside the cursor while Pinky processes a voice input.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBrand.opacity(0.0),
                        DS.Colors.overlayCursorBrand
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}
