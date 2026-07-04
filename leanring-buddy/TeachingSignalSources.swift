//
//  TeachingSignalSources.swift
//  leanring-buddy
//
//  Producers and monitors that feed WorkflowSignal into a TeachingSession.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Protocol

protocol WorkflowSignalSource: AnyObject {
    func start(session: TeachingSession) async
    func stop()
}

// MARK: - Pointer monitor

final class TeachingPointerMonitor: @unchecked Sendable {
    var onPointerEvent: (@MainActor (PointerEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard eventTap == nil else { return }

        let eventTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .scrollWheel]
        let eventMask = eventTypes.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }

            let monitor = Unmanaged<TeachingPointerMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            monitor.handle(eventType: eventType, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Teaching pointer monitor: couldn't create event tap")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            print("⚠️ Teaching pointer monitor: couldn't create run loop source")
            return
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("📗 Teaching pointer monitor started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(eventType: CGEventType, event: CGEvent) {
        let location = event.location

        let pointerEvent: PointerEvent?
        switch eventType {
        case .leftMouseDown:
            pointerEvent = PointerEvent(kind: .click, location: location, button: 0)
        case .rightMouseDown:
            pointerEvent = PointerEvent(kind: .click, location: location, button: 1)
        case .scrollWheel:
            pointerEvent = PointerEvent(kind: .scroll, location: location, button: nil)
        default:
            pointerEvent = nil
        }

        guard let pointerEvent else { return }

        Task { @MainActor [weak self] in
            self?.onPointerEvent?(pointerEvent)
        }
    }
}

// MARK: - Capture coordinator

@MainActor
final class TeachingCaptureCoordinator {
    private let session = TeachingSession()
    private let pointerMonitor = TeachingPointerMonitor()

    private var captureTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    private var lastContextSignature: String?
    private var lastVisualFingerprint: String?
    private var lastCaptureAt: Date?
    private var pendingClickKeyframe = false

    private(set) var isActive = false
    private(set) var keyframeCount = 0

    private let pollIntervalNanoseconds: UInt64 = 750_000_000
    private let minimumCaptureGapNanoseconds: UInt64 = 500_000_000

    func start() {
        guard !isActive else { return }

        isActive = true
        keyframeCount = 0
        lastContextSignature = nil
        lastVisualFingerprint = nil
        lastCaptureAt = nil
        pendingClickKeyframe = false

        Task { await session.start() }

        pointerMonitor.onPointerEvent = { [weak self] event in
            self?.handlePointerEvent(event)
        }
        pointerMonitor.start()

        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureTick()
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanoseconds ?? 750_000_000)
            }
        }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.isActive else { return }
                let count = await self.session.keyframeCount
                self.keyframeCount = count
            }
        }

        print("📗 Teaching capture started")
    }

    func stop() async -> TeachingArtifact? {
        guard isActive else { return nil }

        captureTask?.cancel()
        captureTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        pointerMonitor.stop()
        pointerMonitor.onPointerEvent = nil
        isActive = false
        keyframeCount = 0

        return await session.finish()
    }

    func cancel() async {
        captureTask?.cancel()
        captureTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        pointerMonitor.stop()
        pointerMonitor.onPointerEvent = nil
        isActive = false
        keyframeCount = 0
        await session.cancel()
    }

    func attachNarration(_ text: String) async {
        await session.recordSpeech(text)
        pendingClickKeyframe = true
        await captureTick(forceKeyframe: true)
    }

    func resetFromHere() async {
        await session.resetFromHere()
        lastContextSignature = nil
        lastVisualFingerprint = nil
        lastCaptureAt = nil
        pendingClickKeyframe = false
        await captureTick(forceKeyframe: true)
        keyframeCount = await session.keyframeCount
    }

    private func handlePointerEvent(_ event: PointerEvent) {
        guard event.kind == .click else { return }

        Task {
            await session.ingest(.pointer(event))
            pendingClickKeyframe = true
            await captureTick(forceKeyframe: true)
        }
    }

    private func captureTick(forceKeyframe: Bool = false) async {
        let context = ContextSnapshot(screenContext: ScreenContextCapture.captureCurrentContext())
        let now = Date()

        await session.ingest(.context(context), at: now)

        let contextChanged = context.signature != lastContextSignature
        let shouldAttemptFrame = forceKeyframe
            || contextChanged
            || pendingClickKeyframe
            || lastCaptureAt == nil
            || now.timeIntervalSince(lastCaptureAt ?? .distantPast) >= Double(minimumCaptureGapNanoseconds) / 1_000_000_000

        guard shouldAttemptFrame else { return }

        do {
            let capture = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
            let fingerprint = PinkyWorkflowVisualFingerprint.fingerprint(for: capture.imageData)
            let visualChanged = fingerprint != lastVisualFingerprint

            let promoteKeyframe = forceKeyframe
                || pendingClickKeyframe
                || contextChanged
                || visualChanged
                || lastVisualFingerprint == nil

            pendingClickKeyframe = false

            if !promoteKeyframe,
               let lastCaptureAt,
               now.timeIntervalSince(lastCaptureAt) < Double(minimumCaptureGapNanoseconds) / 1_000_000_000,
               !contextChanged {
                return
            }

            let cursorLocation = NSEvent.mouseLocation
            let frame = ScreenFrame(
                jpegData: capture.imageData,
                visualFingerprint: fingerprint,
                cursorLocation: cursorLocation,
                isKeyframe: promoteKeyframe
            )

            await session.ingest(.frame(frame), at: now)
            lastContextSignature = context.signature
            lastVisualFingerprint = fingerprint
            lastCaptureAt = now
            keyframeCount = await session.keyframeCount
        } catch {
            print("⚠️ Teaching capture tick failed: \(error.localizedDescription)")
        }
    }
}
