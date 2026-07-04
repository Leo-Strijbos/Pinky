//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case checking
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// True when the system default input is a Bluetooth headset (e.g. AirPods).
    /// Push-to-talk is disabled in this state because macOS Bluetooth mic
    /// capture is unreliable through AVAudioEngine.
    @Published private(set) var isBluetoothInputDeviceSelected = false
    @Published private(set) var selectedInputDeviceName = ""

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// BlueCursorView observes this to replay pointing when the overlay remounts.
    @Published private(set) var pointingRequestEpoch = 0

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the welcome animation.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Response Panel (notch dropdown)

    @Published private(set) var streamingResponseText: String = ""
    @Published private(set) var isResponsePanelStreaming: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let globalTypedCommandShortcutMonitor = GlobalTypedCommandShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    private lazy var commandPaletteWindowManager = PinkyCommandPaletteWindowManager(companionManager: self)
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://clicky-proxy.leoclicks.workers.dev"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    let skillManager = SkillManager()

    private lazy var turnService: CompanionTurnService = {
        CompanionTurnService(
            claudeAPI: claudeAPI,
            skillManager: skillManager
        )
    }()

    private let sessionManager = CompanionSessionManager()

    private lazy var sessionPlanningService: CompanionSessionPlanningService = {
        CompanionSessionPlanningService(
            claudeAPI: claudeAPI,
            skillManager: skillManager
        )
    }()

    private lazy var sessionCompletionMonitor: CompanionSessionCompletionMonitor = {
        CompanionSessionCompletionMonitor(claudeAPI: claudeAPI)
    }()

    private lazy var sessionPollingController: CompanionSessionPollingController = {
        CompanionSessionPollingController(completionMonitor: sessionCompletionMonitor)
    }()

    @Published private(set) var isWalkthroughActive = false
    @Published private(set) var walkthroughStatusText: String?

    /// Mirrored from SkillManager so overlay SwiftUI views update reliably.
    @Published private(set) var isTeaching = false
    @Published private(set) var teachingStepCount = 0
    @Published private(set) var isTeachingProcessing = false
    @Published var isTeachingBriefPresented = false

    /// Opens embedded WebView panels for stock charts and places lookups.
    var resultWindowManager: PinkyResultWindowManager?

    /// Opens PDF panels for knowledge-base source documents.
    var documentWindowManager: PinkyDocumentWindowManager?

    /// Opens floating panels for generated copyable content.
    var copyableContentWindowManager: PinkyCopyableContentWindowManager?

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// Tracks when copyable code/command was last delivered for walkthrough routing.
    private var lastCopyableDeliveryHistoryIndex: Int?
    private var lastCopyableKind: PinkyCopyableContentPayload.Kind?

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    /// Bumped whenever the user interrupts or replaces an in-flight response.
    /// Stale tasks compare their snapshot against this to avoid false error fallbacks.
    private var responseEpoch = 0

    private var shortcutTransitionCancellable: AnyCancellable?
    private var typedCommandShortcutCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var skillManagerCancellable: AnyCancellable?
    private var teachingStateCancellables = Set<AnyCancellable>()
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    func endWalkthrough() {
        sessionPollingController.stopPolling()
        _ = sessionManager.endWalkthrough(reason: .userDone)
        invalidateCurrentResponse()
        syncWalkthroughState()
    }

    private func syncWalkthroughState() {
        if let session = sessionManager.activeSession {
            isWalkthroughActive = true
            walkthroughStatusText = {
                var text = "\(session.plan.title) · step \(session.currentIndex + 1)/\(session.plan.steps.count)"
                if session.coachingMode == .shadowing {
                    text += " · watching"
                }
                return text
            }()
            sessionPollingController.startPolling(
                sessionManager: sessionManager,
                workflowManager: skillManager,
                shouldSkipAdvance: { [weak self] in
                    self?.shouldDeferWalkthroughAutomation ?? false
                },
                onOutcome: { [weak self] outcome in
                    self?.deliverWalkthroughOutcome(outcome)
                }
            )
            ensurePointingOverlayVisible()
        } else {
            isWalkthroughActive = false
            walkthroughStatusText = nil
            sessionPollingController.stopPolling()
        }
    }

    private var shouldDeferWalkthroughAutomation: Bool {
        isTeaching
            || skillManager.isTeaching
            || buddyDictationManager.isDictationInProgress
            || buddyDictationManager.isFinalizingTranscript
            || buddyDictationManager.isPreparingToRecord
            || voiceState == .listening
            || currentResponseTask != nil
    }

    private func deliverWalkthroughOutcome(_ outcome: CompanionSessionOutcome) {
        sessionPollingController.stopPolling()
        invalidateCurrentResponse()
        let responseEpochAtStart = responseEpoch

        currentResponseTask = Task {
            defer {
                if responseEpochAtStart == responseEpoch {
                    currentResponseTask = nil
                    if voiceState != .listening,
                       !buddyDictationManager.isDictationInProgress,
                       !elevenLabsTTSClient.isPlaying {
                        voiceState = .idle
                    }
                    syncWalkthroughState()
                }
            }

            guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

            voiceState = .processing
            do {
                try await deliverSessionOutcome(
                    transcript: "",
                    outcome: outcome,
                    responseEpochAtStart: responseEpochAtStart
                )
            } catch {
                if !Self.shouldSuppressResponseError(
                    error,
                    responseEpochAtStart: responseEpochAtStart,
                    currentEpoch: responseEpoch
                ) {
                    print("⚠️ Walkthrough auto-advance error: \(error)")
                }
            }
        }
    }

    /// When enabled, the pointer overlay stays visible at all times.
    /// When disabled (default), the overlay appears only while Ctrl+Option is held
    /// or through an active voice/pointing interaction, then fades out shortly after.
    @Published var isPinkyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isPinkyCursorEnabled") == nil
        ? false
        : UserDefaults.standard.bool(forKey: "isPinkyCursorEnabled")

    func setPinkyCursorEnabled(_ enabled: Bool) {
        isPinkyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isPinkyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Pinky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindTypedCommandShortcut()
        bindSkillManagerObservation()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // before the user's first push-to-talk interaction.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isPinkyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation plays.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .pinkyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        PinkyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation.
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Pinky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Pinky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        scheduleTransientHideIfNeeded()
    }

    /// Keeps the transparent overlay windows mounted so pointing animations can run.
    func ensurePointingOverlayVisible() {
        transientHideTask?.cancel()
        transientHideTask = nil

        guard !isOverlayVisible else { return }

        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func publishElementPoint(_ renderedPoint: CompanionPointRenderer.RenderedPoint) {
        ensurePointingOverlayVisible()
        detectedElementDisplayFrame = renderedPoint.displayFrame
        detectedElementScreenLocation = renderedPoint.globalLocation
        pointingRequestEpoch += 1
    }

    func publishElementPoint(
        _ renderedPoint: CompanionPointRenderer.RenderedPoint,
        bubbleText: String?
    ) {
        detectedElementBubbleText = bubbleText
        publishElementPoint(renderedPoint)
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        globalTypedCommandShortcutMonitor.stop()
        commandPaletteWindowManager.hide()
        buddyDictationManager.cancelCurrentDictation()
        buddyDictationManager.shutdown()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        invalidateCurrentResponse()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        typedCommandShortcutCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
            globalTypedCommandShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
            globalTypedCommandShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            PinkyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            PinkyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            PinkyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            PinkyAnalytics.trackAllPermissionsGranted()
        }

        refreshSelectedInputDevice()
    }

    func refreshSelectedInputDevice() {
        let inputDeviceDescription = BuddyMicrophoneCaptureUtilities.defaultInputDeviceDescription()
        let isBluetoothInput = BuddyMicrophoneCaptureUtilities.isDefaultInputDeviceBluetooth()

        if selectedInputDeviceName != inputDeviceDescription {
            selectedInputDeviceName = inputDeviceDescription
        }

        if isBluetoothInputDeviceSelected != isBluetoothInput {
            isBluetoothInputDeviceSelected = isBluetoothInput
            if isBluetoothInput {
                print("🎙️ Bluetooth input detected (\(inputDeviceDescription)) — push-to-talk disabled")
            }
        }
    }

    var bluetoothInputWarningMessage: String {
        let loweredName = selectedInputDeviceName.lowercased()
        if loweredName.contains("airpod") {
            return "AirPods can't be used as Pinky's microphone. Open Sound Settings and switch to your Mac's built-in mic instead."
        }
        return "Bluetooth microphones can't be used for voice input. Open Sound Settings and switch to your Mac's built-in mic instead."
    }

    func presentBluetoothInputWarning() {
        streamingResponseText = bluetoothInputWarningMessage
        isResponsePanelStreaming = false
        NotificationCenter.default.post(name: .pinkyShowPanel, object: nil)
    }

    func openSoundInputSettings() {
        if let soundSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(soundSettingsURL)
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    PinkyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isPinkyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindSkillManagerObservation() {
        skillManagerCancellable = skillManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        skillManager.$isTeaching
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isTeaching in
                self?.isTeaching = isTeaching
            }
            .store(in: &teachingStateCancellables)

        skillManager.$teachingStepCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.teachingStepCount = count
            }
            .store(in: &teachingStateCancellables)

        skillManager.$isProcessing
            .combineLatest(skillManager.$isTeaching)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isProcessing, isTeaching in
                self?.isTeachingProcessing = isProcessing && !isTeaching
            }
            .store(in: &teachingStateCancellables)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        triggerOnboarding()
    }

    func requestMicrophonePermission() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    func openAccessibilitySettings() {
        WindowPositionManager.openAccessibilitySettings()
    }

    func openScreenRecordingSettings() {
        WindowPositionManager.openScreenRecordingSettings()
    }

    func resetPlaybookRecordingFromHere() {
        skillManager.resetTeachingFromHere()
    }

    func toggleTeaching() {
        if skillManager.isTeaching {
            Task {
                await finishTeachingSession()
            }
        } else {
            requestTeachingStart()
        }
    }

    func requestTeachingStart() {
        guard !skillManager.isTeaching, !isTeachingBriefPresented else { return }
        isTeachingBriefPresented = true
    }

    func cancelTeachingBrief() {
        isTeachingBriefPresented = false
    }

    func completeTeachingBrief() {
        isTeachingBriefPresented = false
        startTeachingSession()
    }

    func togglePlaybookRecording() {
        toggleTeaching()
    }

    func startTeachingSession() {
        transientHideTask?.cancel()
        transientHideTask = nil
        // Teaching needs the cursor overlay, but must not replay the first-run
        // welcome animation (that only belongs in triggerOnboarding).
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
        skillManager.startTeaching()
        print("📗 Teaching UI active — look for ● Teaching… beside the cursor")
    }

    func finishTeachingSession() async {
        voiceState = .processing
        guard let draft = await skillManager.stopTeaching(claudeAPI: claudeAPI) else {
            if voiceState == .processing { voiceState = .idle }
            return
        }

        let epoch = responseEpoch
        voiceState = .responding
        let spokenText = "Got it. I can teach that now. Can I save this as \(draft.suggestedTitle)?"
        do {
            try await speakResponseText(spokenText, responseEpochAtStart: epoch)
        } catch {
            print("⚠️ Teaching confirmation TTS failed: \(error.localizedDescription)")
        }
        if responseEpoch == epoch, voiceState == .responding {
            voiceState = .idle
        }
    }

    func handleTeachingSaveConfirmation(_ transcript: String) async {
        guard skillManager.pendingDraft != nil else { return }

        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let epoch = responseEpoch
        voiceState = .responding

        if TeachingSaveConfirmation.isAffirmative(normalized) {
            let title = skillManager.pendingDraftTitle
            await skillManager.confirmTeachingSave()
            let spoken = title.isEmpty ? "Saved." : "Saved as \(title)."
            try? await speakResponseText(spoken, responseEpochAtStart: epoch)
        } else if TeachingSaveConfirmation.isNegative(normalized) {
            skillManager.cancelPendingDraft()
            try? await speakResponseText("No problem, I won't save it.", responseEpochAtStart: epoch)
        } else {
            await skillManager.confirmTeachingSave(title: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            try? await speakResponseText("Saved as \(transcript.trimmingCharacters(in: .whitespacesAndNewlines)).", responseEpochAtStart: epoch)
        }

        if responseEpoch == epoch, voiceState == .responding {
            voiceState = .idle
        }
    }

    func presentSkillImport(kind: SkillKind) {
        skillManager.presentImportPanel(kind: kind, claudeAPI: claudeAPI)
    }

    func startSkillWalkthrough(skillName: String) {
        guard let plan = CompanionSessionPlanBuilder.plan(
            forSkillName: skillName,
            skillManager: skillManager
        ) else { return }

        _ = sessionManager.activatePlan(plan)
        syncWalkthroughState()
    }

    func openSkillPDF(skill: AgentSkill, fileURL: URL) {
        documentWindowManager?.show(sources: [
            SkillSourceDocument(
                skillName: skill.name,
                title: skill.title,
                fileURL: fileURL,
                pageIndex: 0
            ),
        ])
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }

                // User speech always wins — even if Pinky is still in .responding
                // from TTS or a prior response that didn't reset yet.
                if isRecording {
                    self.voiceState = .listening
                    return
                }

                if isFinalizing || isPreparing {
                    self.voiceState = .processing
                    return
                }

                // While checking, responding, processing, or an active response task owns state.
                if self.voiceState == .checking {
                    return
                }

                // While a response task is running, the pipeline owns non-idle states.
                if self.currentResponseTask != nil {
                    return
                }

                // Don't snap to idle over an in-flight TTS playback window.
                guard self.voiceState != .responding else { return }

                self.voiceState = .idle
                self.scheduleTransientHideIfNeeded()
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func bindTypedCommandShortcut() {
        typedCommandShortcutCancellable = globalTypedCommandShortcutMonitor
            .togglePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.toggleCommandPalette()
            }
    }

    func toggleCommandPalette() {
        commandPaletteWindowManager.toggle()
    }

    func submitTypedRequest(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastTranscript = trimmed
        print("⌨️ Companion received typed request: \(trimmed)")

        transientHideTask?.cancel()
        transientHideTask = nil

        ensurePointingOverlayVisible()

        sendTranscriptToClaude(transcript: trimmed)
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            if isBluetoothInputDeviceSelected {
                print("🎙️ Push-to-talk blocked — Bluetooth input not supported (\(selectedInputDeviceName))")
                presentBluetoothInputWarning()
                return
            }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // Show the overlay for any voice interaction, including transient mode.
            ensurePointingOverlayVisible()

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .pinkyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            invalidateCurrentResponse()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            PinkyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        PinkyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        if self?.skillManager.isTeaching == true {
                            self?.skillManager.attachNarration(finalTranscript)
                            return
                        }
                        if self?.skillManager.pendingDraft != nil {
                            Task {
                                await self?.handleTeachingSaveConfirmation(finalTranscript)
                            }
                            return
                        }
                        self?.sendTranscriptToClaude(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            PinkyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            scheduleTransientHideIfNeeded()
        case .none:
            break
        }
    }

    // MARK: - AI Response Pipeline

    /// Resolves route then runs the matching voice pipeline. Default is the unified agent turn.
    private func sendTranscriptToClaude(transcript: String) {
        invalidateCurrentResponse()
        sessionPollingController.stopPolling()
        let responseEpochAtStart = responseEpoch

        currentResponseTask = Task {
            defer {
                if responseEpochAtStart == responseEpoch {
                    currentResponseTask = nil
                    if voiceState != .listening,
                       !buddyDictationManager.isDictationInProgress {
                        voiceState = .idle
                        scheduleTransientHideIfNeeded()
                    }
                }
            }

            voiceState = .processing
            prepareResponsePanel()

            do {
                if sessionPlanningService.pendingClarification != nil {
                    try await deliverPendingPlanningResponse(
                        transcript: transcript,
                        responseEpochAtStart: responseEpochAtStart
                    )
                    return
                }

                if let retryTranscript = sessionPlanningService.pendingRetryTranscript,
                   CompanionSessionPlanningBriefFormatter.shouldRetryFailedPlanning(transcript) {
                    sessionPlanningService.clearPendingRetry()
                    try await deliverPlannedSessionStart(
                        transcript: retryTranscript,
                        responseEpochAtStart: responseEpochAtStart
                    )
                    return
                }

                if let sessionOutcome = await sessionManager.process(
                    transcript: transcript,
                    workflowManager: skillManager,
                    completionMonitor: sessionCompletionMonitor,
                    routingContext: walkthroughRoutingContext()
                ) {
                    switch sessionOutcome {
                    case .needsPlan(let planningTranscript):
                        try await deliverPlannedSessionStart(
                            transcript: planningTranscript,
                            responseEpochAtStart: responseEpochAtStart
                        )

                    case .exitAndContinue(let remainingTranscript):
                        syncWalkthroughState()
                        let command = PinkyVoiceSessionPhrases.commandAfterWalkthroughExit(
                            in: remainingTranscript
                        )
                        try await deliverVoiceRoute(
                            transcript: command,
                            responseEpochAtStart: responseEpochAtStart
                        )

                    default:
                        try await deliverSessionOutcome(
                            transcript: transcript,
                            outcome: sessionOutcome,
                            responseEpochAtStart: responseEpochAtStart
                        )
                        syncWalkthroughState()
                    }
                    return
                }

                try await deliverVoiceRoute(
                    transcript: transcript,
                    responseEpochAtStart: responseEpochAtStart
                )
            } catch {
                if Self.shouldSuppressResponseError(
                    error,
                    responseEpochAtStart: responseEpochAtStart,
                    currentEpoch: responseEpoch
                ) {
                    print("🎙️ Voice response interrupted")
                    finishResponsePanelStream()
                    return
                }
                PinkyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                finishResponsePanelStream()
                speakCreditsErrorFallback()
            }
        }
    }

    /// Cancels in-flight voice response work and marks any pending task as stale.
    private func invalidateCurrentResponse() {
        responseEpoch += 1
        currentResponseTask?.cancel()
        currentResponseTask = nil
        elevenLabsTTSClient.stopPlayback()
        isResponsePanelStreaming = false
    }

    // MARK: - Response Panel Streaming

    func prepareResponsePanel() {
        streamingResponseText = ""
        isResponsePanelStreaming = true
        NotificationCenter.default.post(name: .pinkyShowPanel, object: nil)
    }

    func finishResponsePanelStream() {
        isResponsePanelStreaming = false
    }

    private func streamSpokenTextToPanel(
        _ text: String,
        responseEpochAtStart: Int,
        speechDuration: TimeInterval
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let words = trimmed
            .split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
        guard !words.isEmpty else { return }

        let streamDuration = max(speechDuration * 0.95, Double(words.count) * 0.05)
        let delayPerWord = streamDuration / Double(words.count)

        for (index, word) in words.enumerated() {
            guard responseEpochAtStart == responseEpoch else { return }
            if index > 0 {
                streamingResponseText += " "
            }
            streamingResponseText += word
            if index < words.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(delayPerWord * 1_000_000_000))
            }
        }
    }

    private func waitForPlaybackToFinish(responseEpochAtStart: Int) async throws {
        while elevenLabsTTSClient.isPlaying {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
            guard responseEpochAtStart == responseEpoch else { return }
        }
    }

    private func speakAndStreamToPanel(
        _ spokenText: String,
        responseEpochAtStart: Int,
        keepProcessingIndicatorDuringPlayback: Bool = false
    ) async throws {
        let trimmed = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        streamingResponseText = ""
        isResponsePanelStreaming = true

        do {
            voiceState = .processing
            let speechDuration = try await elevenLabsTTSClient.speakText(trimmed)
            guard responseEpochAtStart == responseEpoch else { return }

            if !keepProcessingIndicatorDuringPlayback {
                voiceState = .responding
            }

            async let panelStream: Void = streamSpokenTextToPanel(
                trimmed,
                responseEpochAtStart: responseEpochAtStart,
                speechDuration: max(speechDuration, 0.25)
            )
            async let playbackWait: Void = waitForPlaybackToFinish(responseEpochAtStart: responseEpochAtStart)
            try await (panelStream, playbackWait)
        } catch {
            if Self.shouldSuppressResponseError(
                error,
                responseEpochAtStart: responseEpochAtStart,
                currentEpoch: responseEpoch
            ) {
                print("🔊 TTS interrupted")
                return
            }
            PinkyAnalytics.trackTTSError(error: error.localizedDescription)
            print("⚠️ ElevenLabs TTS error: \(error)")
            speakCreditsErrorFallback()
        }
    }

    private func deliverVoiceRoute(
        transcript: String,
        responseEpochAtStart: Int
    ) async throws {
        if let compoundSteps = CompanionSessionPlanBuilder.compoundSteps(from: transcript) {
            let spokenText = await CompanionSessionRunner.executeCompoundSteps(compoundSteps)
            guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

            appendExchangeToConversationHistory(
                userTranscript: transcript,
                assistantResponse: spokenText
            )
            PinkyAnalytics.trackAIResponseReceived(response: spokenText)
            try await speakAndStreamToPanel(spokenText, responseEpochAtStart: responseEpochAtStart)
            finishResponsePanelStream()
            return
        }

        let routeContext = CompanionVoiceRouteContext(
            uploadedDocumentCount: skillManager.skillCount,
            workflowScreenCount: skillManager.skills.reduce(0) { $0 + $1.playbackSteps.count }
        )

        let decision = CompanionVoiceRouter.resolve(
            transcript: transcript,
            context: routeContext
        )

        print("🎙️ Voice route: \(decision.route.rawValue) (\(decision.reason))")

        switch decision.route {
        case .quickLocal:
            let spokenText = decision.cannedResponse ?? "okay."
            try await deliverTextOnlyResponse(
                transcript: transcript,
                spokenText: spokenText,
                responseEpochAtStart: responseEpochAtStart
            )

        case .intro:
            let spokenText = try await fetchTextOnlyResponse(
                transcript: transcript,
                systemPrompt: CompanionAgentPrompt.introOnly,
                model: CompanionAgentPrompt.introModel
            )
            try await deliverTextOnlyResponse(
                transcript: transcript,
                spokenText: spokenText,
                responseEpochAtStart: responseEpochAtStart
            )

        case .appAction:
            guard let appAction = decision.appAction else {
                try await deliverAgentResponse(
                    transcript: transcript,
                    responseEpochAtStart: responseEpochAtStart
                )
                return
            }
            try await deliverAppActionResponse(
                transcript: transcript,
                action: appAction,
                responseEpochAtStart: responseEpochAtStart
            )

        case .agent:
            try await deliverAgentResponse(
                transcript: transcript,
                responseEpochAtStart: responseEpochAtStart
            )
        }
    }

    private func deliverPendingPlanningResponse(
        transcript: String,
        responseEpochAtStart: Int
    ) async throws {
        guard let pending = sessionPlanningService.pendingClarification else { return }

        if PinkyVoiceSessionPhrases.isCancel(transcript) {
            sessionPlanningService.clearPendingClarification()
            try await deliverTextOnlyResponse(
                transcript: transcript,
                spokenText: "no problem, we can pick this up later.",
                responseEpochAtStart: responseEpochAtStart
            )
            return
        }

        if CompanionSessionPlanningBriefFormatter.shouldAbandonPendingClarification(
            transcript,
            pending: pending
        ) {
            sessionPlanningService.clearPendingClarification()
            try await deliverVoiceRoute(
                transcript: transcript,
                responseEpochAtStart: responseEpochAtStart
            )
            return
        }

        voiceState = .processing

        do {
            let result = try await sessionPlanningService.resumePendingPlan(with: transcript)
            guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

            switch result {
            case .needsClarification(let clarification):
                try await deliverTextOnlyResponse(
                    transcript: transcript,
                    spokenText: clarification.spokenPrompt,
                    responseEpochAtStart: responseEpochAtStart
                )

            case .plan(let plan):
                let activatedOutcome = sessionManager.activatePlan(plan)
                try await deliverSessionOutcome(
                    transcript: transcript,
                    outcome: activatedOutcome,
                    responseEpochAtStart: responseEpochAtStart
                )
                syncWalkthroughState()
            }
        } catch {
            if Self.shouldSuppressResponseError(
                error,
                responseEpochAtStart: responseEpochAtStart,
                currentEpoch: responseEpoch
            ) {
                return
            }
            print("⚠️ Session planning resume failed: \(error.localizedDescription) — falling back to agent")
            sessionPlanningService.clearPendingClarification()
            try await deliverAgentResponse(
                transcript: transcript,
                responseEpochAtStart: responseEpochAtStart
            )
        }
    }

    private func deliverPlannedSessionStart(
        transcript: String,
        responseEpochAtStart: Int
    ) async throws {
        voiceState = .processing
        try await speakResponseText(
            "let me break this down.",
            responseEpochAtStart: responseEpochAtStart,
            keepProcessingIndicatorDuringPlayback: true
        )
        guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

        appendExchangeToConversationHistory(
            userTranscript: transcript,
            assistantResponse: "let me break this down."
        )
        PinkyAnalytics.trackAIResponseReceived(response: "let me break this down.")

        voiceState = .processing

        do {
            let result = try await sessionPlanningService.buildPlan(transcript: transcript)
            guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

            switch result {
            case .needsClarification(let clarification):
                try await deliverTextOnlyResponse(
                    transcript: transcript,
                    spokenText: clarification.spokenPrompt,
                    responseEpochAtStart: responseEpochAtStart
                )

            case .plan(let plan):
                let activatedOutcome = sessionManager.activatePlan(plan)
                try await deliverSessionOutcome(
                    transcript: transcript,
                    outcome: activatedOutcome,
                    responseEpochAtStart: responseEpochAtStart
                )
                syncWalkthroughState()
            }
        } catch {
            if Self.shouldSuppressResponseError(
                error,
                responseEpochAtStart: responseEpochAtStart,
                currentEpoch: responseEpoch
            ) {
                return
            }
            print("⚠️ Session planning failed: \(error.localizedDescription) — falling back to agent")
            sessionPlanningService.markPendingRetry(transcript: transcript)
            try await deliverAgentResponse(
                transcript: transcript,
                responseEpochAtStart: responseEpochAtStart
            )
        }
    }

    private func deliverSessionOutcome(
        transcript: String,
        outcome: CompanionSessionOutcome,
        responseEpochAtStart: Int
    ) async throws {
        switch outcome {
        case .speak(let spokenText, _):
            try await deliverTextOnlyResponse(
                transcript: transcript,
                spokenText: spokenText,
                responseEpochAtStart: responseEpochAtStart
            )

        case .runCompoundSteps(let steps):
            let spokenText = await CompanionSessionRunner.executeCompoundSteps(steps)
            guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

            appendExchangeToConversationHistory(userTranscript: transcript, assistantResponse: spokenText)
            PinkyAnalytics.trackAIResponseReceived(response: spokenText)
            try await speakAndStreamToPanel(spokenText, responseEpochAtStart: responseEpochAtStart)
            finishResponsePanelStream()

        case .agentTurn(let question, let session):
            try await deliverAgentResponse(
                transcript: question,
                responseEpochAtStart: responseEpochAtStart,
                pinnedProcedureSession: session
            )

        case .ended(let spokenText):
            try await deliverTextOnlyResponse(
                transcript: transcript,
                spokenText: spokenText,
                responseEpochAtStart: responseEpochAtStart
            )

        case .needsPlan(let planningTranscript):
            try await deliverPlannedSessionStart(
                transcript: planningTranscript,
                responseEpochAtStart: responseEpochAtStart
            )

        case .executeGuideStep(let session):
            try await deliverGuideStepResponse(
                transcript: transcript,
                session: session,
                responseEpochAtStart: responseEpochAtStart
            )

        case .autoAdvanced(let transition, let session):
            if session.coachingMode == .shadowing {
                syncWalkthroughState()
                return
            }
            if let transition, !transition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await speakResponseText(transition, responseEpochAtStart: responseEpochAtStart)
            }
            guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }
            let nextOutcome = sessionManager.presentCurrentStep()
            try await deliverSessionOutcome(
                transcript: transcript,
                outcome: nextOutcome,
                responseEpochAtStart: responseEpochAtStart
            )

        case .exitAndContinue(let remainingTranscript):
            syncWalkthroughState()
            try await deliverVoiceRoute(
                transcript: remainingTranscript,
                responseEpochAtStart: responseEpochAtStart
            )
        }
    }

    private func deliverGuideStepResponse(
        transcript: String,
        session: CompanionActiveSession,
        responseEpochAtStart: Int
    ) async throws {
        voiceState = .processing

        let delivery = try await turnService.runGuideStepTurn(
            session: session,
            model: selectedModel,
            capabilityContext: makeCapabilityContext()
        )

        guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

        sessionManager.markGuideStepPresented()
        syncWalkthroughState()

        let guideTranscript = transcript.isEmpty
            ? "walkthrough step \(session.currentIndex + 1)"
            : transcript

        try await applyAgentTurnResult(
            transcript: guideTranscript,
            delivery: delivery,
            responseEpochAtStart: responseEpochAtStart
        )
    }

    private func deliverAppActionResponse(
        transcript: String,
        action: PinkyAppAction,
        responseEpochAtStart: Int
    ) async throws {
        guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

        let spokenText = await PinkyAppActionExecutor.execute(
            action,
            context: makeCapabilityContext()
        )
        guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

        appendExchangeToConversationHistory(userTranscript: transcript, assistantResponse: spokenText)
        PinkyAnalytics.trackAIResponseReceived(response: spokenText)

        try await speakAndStreamToPanel(spokenText, responseEpochAtStart: responseEpochAtStart)
        finishResponsePanelStream()
    }

    private func deliverAgentResponse(
        transcript: String,
        responseEpochAtStart: Int,
        pinnedProcedureSession: CompanionActiveSession? = nil
    ) async throws {
        let delivery = try await turnService.runAgentTurn(
            transcript: transcript,
            conversationHistory: conversationHistoryForAPI(),
            model: selectedModel,
            capabilityContext: makeCapabilityContext(),
            pinnedProcedureSession: pinnedProcedureSession
        )

        guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

        try await applyAgentTurnResult(
            transcript: transcript,
            delivery: delivery,
            responseEpochAtStart: responseEpochAtStart
        )
    }

    private func applyAgentTurnResult(
        transcript: String,
        delivery: CompanionTurnService.AgentTurnDelivery,
        responseEpochAtStart: Int
    ) async throws {
        let result = delivery.result
        let cursorScreenCapture = delivery.cursorScreenCapture
        let spokenText = CompanionAgentActionSpeech.resolveSpokenText(
            modelText: result.spokenText,
            executedActions: [],
            effects: CompanionTurnEffects(
                pointTarget: result.pointTarget,
                panelPayload: result.panelPayload
            )
        )

        if result.pointTarget != nil, spokenText.isEmpty {
            voiceState = .idle
        }

        if let pointTarget = result.pointTarget {
            let renderedPoint = CompanionPointRenderer.render(
                pointTarget: pointTarget,
                on: cursorScreenCapture
            )
            publishElementPoint(renderedPoint)
            PinkyAnalytics.trackElementPointed(elementLabel: renderedPoint.label)
            print("🎯 Element pointing: (\(pointTarget.x), \(pointTarget.y)) → \"\(renderedPoint.label)\"")
        } else {
            print("🎯 Element pointing: none")
        }

        appendExchangeToConversationHistory(userTranscript: transcript, assistantResponse: spokenText)
        PinkyAnalytics.trackAIResponseReceived(response: spokenText)

        if let panelPayload = result.panelPayload {
            resultWindowManager?.show(panelPayload)
        }

        // Knowledge-base PDF panels disabled — responses stream in the notch panel instead.
        // let sourceDocuments = turnService.sourceDocumentsToPresent(for: transcript)
        // if !sourceDocuments.isEmpty {
        //     documentWindowManager?.show(sources: sourceDocuments)
        // }

        guard !spokenText.isEmpty else {
            finishResponsePanelStream()
            return
        }

        try await speakAndStreamToPanel(spokenText, responseEpochAtStart: responseEpochAtStart)
        finishResponsePanelStream()
    }

    private func makeCapabilityContext(
        screenCapture: CompanionScreenCapture? = nil
    ) -> CompanionCapabilityContext {
        var context = CompanionCapabilityContext(
            screenCapture: screenCapture,
            documentWindowManager: documentWindowManager,
            resultWindowManager: resultWindowManager,
            copyableContentWindowManager: copyableContentWindowManager
        )
        context.onCopyableContentDelivered = { [weak self] payload in
            self?.noteCopyableContentDelivered(payload)
        }
        return context
    }

    private func noteCopyableContentDelivered(_ payload: PinkyCopyableContentPayload) {
        lastCopyableDeliveryHistoryIndex = conversationHistory.count
        lastCopyableKind = payload.kind
    }

    private func walkthroughRoutingContext() -> CompanionWalkthroughRoutingContext {
        let recentCopyableKind: PinkyCopyableContentPayload.Kind?
        if let deliveryIndex = lastCopyableDeliveryHistoryIndex,
           conversationHistory.count - deliveryIndex <= 2 {
            recentCopyableKind = lastCopyableKind
        } else {
            recentCopyableKind = nil
        }

        let recentExchanges = conversationHistory.suffix(3).map {
            (user: $0.userTranscript, assistant: $0.assistantResponse)
        }

        return CompanionWalkthroughRoutingContext(
            recentExchanges: recentExchanges,
            recentCopyableKind: recentCopyableKind
        )
    }

    private func conversationHistoryForAPI() -> [(userPlaceholder: String, assistantResponse: String)] {
        conversationHistory.compactMap { entry in
            let user = entry.userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistant = entry.assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !assistant.isEmpty else { return nil }
            return (userPlaceholder: user, assistantResponse: assistant)
        }
    }

    private func appendExchangeToConversationHistory(userTranscript: String, assistantResponse: String) {
        let user = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !assistant.isEmpty else {
            print("🧠 Conversation history: skipped empty exchange (user=\(user.isEmpty), assistant=\(assistant.isEmpty))")
            return
        }

        conversationHistory.append((
            userTranscript: user,
            assistantResponse: assistant
        ))

        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }

        print("🧠 Conversation history: \(conversationHistory.count) exchanges")
    }

    private func fetchTextOnlyResponse(
        transcript: String,
        systemPrompt: String,
        model: String
    ) async throws -> String {
        let (fullResponseText, _) = try await claudeAPI.sendTextStreaming(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistoryForAPI(),
            userPrompt: transcript,
            model: model,
            onTextChunk: { _ in }
        )
        return fullResponseText
    }

    private func deliverTextOnlyResponse(
        transcript: String,
        spokenText: String,
        responseEpochAtStart: Int
    ) async throws {
        guard !Task.isCancelled, responseEpochAtStart == responseEpoch else { return }

        let trimmedSpokenText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        appendExchangeToConversationHistory(userTranscript: transcript, assistantResponse: trimmedSpokenText)
        PinkyAnalytics.trackAIResponseReceived(response: trimmedSpokenText)

        guard !trimmedSpokenText.isEmpty else {
            finishResponsePanelStream()
            return
        }

        try await speakAndStreamToPanel(trimmedSpokenText, responseEpochAtStart: responseEpochAtStart)
        finishResponsePanelStream()
    }

    private func speakResponseText(
        _ spokenText: String,
        responseEpochAtStart: Int,
        keepProcessingIndicatorDuringPlayback: Bool = false
    ) async throws {
        guard !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        do {
            voiceState = .processing
            try await elevenLabsTTSClient.speakText(spokenText)
            guard responseEpochAtStart == responseEpoch else { return }

            if !keepProcessingIndicatorDuringPlayback {
                voiceState = .responding
            }
            while elevenLabsTTSClient.isPlaying {
                try await Task.sleep(nanoseconds: 100_000_000)
                try Task.checkCancellation()
                guard responseEpochAtStart == responseEpoch else { return }
            }
        } catch {
            if Self.shouldSuppressResponseError(
                error,
                responseEpochAtStart: responseEpochAtStart,
                currentEpoch: responseEpoch
            ) {
                print("🔊 TTS interrupted")
                return
            }
            PinkyAnalytics.trackTTSError(error: error.localizedDescription)
            print("⚠️ ElevenLabs TTS error: \(error)")
            speakCreditsErrorFallback()
        }
    }

    /// True when an error should not trigger the credits fallback — user interrupted
    /// or replaced the in-flight response, or the error is a cooperative cancellation.
    private static func shouldSuppressResponseError(
        _ error: Error?,
        responseEpochAtStart: Int,
        currentEpoch: Int
    ) -> Bool {
        if responseEpochAtStart != currentEpoch {
            return true
        }
        if Task.isCancelled {
            return true
        }
        if let error, isBenignCancellation(error) {
            return true
        }
        return false
    }

    /// True when an error is expected from the user interrupting push-to-talk mid-response.
    private static func isBenignCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        var nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isBenignCancellation(underlyingError)
        }

        return false
    }

    /// In transient mode (default), waits for TTS and pointing to finish, then
    /// fades out the overlay half a second after the buddy is done.
    private func scheduleTransientHideIfNeeded() {
        guard !isPinkyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            while self.isOverlayInteractionActive {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Brief pause after the interaction ends, then fade out
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// True while the overlay should stay up for an in-flight voice or pointing interaction.
    private var isOverlayInteractionActive: Bool {
        showOnboardingPrompt
            || isWalkthroughActive
            || isTeaching
            || isTeachingProcessing
            || skillManager.pendingDraft != nil
            || globalPushToTalkShortcutMonitor.isShortcutCurrentlyPressed
            || voiceState != .idle
            || currentResponseTask != nil
            || elevenLabsTTSClient.isPlaying
            || detectedElementScreenLocation != nil
            || buddyDictationManager.isDictationInProgress
            || buddyDictationManager.isFinalizingTranscript
            || buddyDictationManager.isPreparingToRecord
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of API credits. Please check your Cloudflare Worker and API keys."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Onboarding Prompt

    /// Called by the overlay when the welcome animation finishes.
    func finishWelcomeAnimation() {
        startOnboardingPromptStream()
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                        self.scheduleTransientHideIfNeeded()
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

}
