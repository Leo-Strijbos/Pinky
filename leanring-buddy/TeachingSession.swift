//
//  TeachingSession.swift
//  leanring-buddy
//
//  Collects timestamped workflow signals and promotes durable keyframes.
//

import Foundation

actor TeachingSession {
    private(set) var isActive = false
    private var startedAt: Date?
    private var signals: [TimestampedSignal] = []
    private var keyframes: [TeachingKeyframe] = []
    private var nextKeyframeIndex = 0

    var keyframeCount: Int { keyframes.count }
    var signalCount: Int { signals.count }

    func start() {
        guard !isActive else { return }
        isActive = true
        startedAt = Date()
        signals = []
        keyframes = []
        nextKeyframeIndex = 0
        print("📗 Teaching session started")
    }

    func ingest(_ signal: WorkflowSignal, at timestamp: Date = Date()) {
        guard isActive else { return }

        signals.append(TimestampedSignal(timestamp: timestamp, signal: signal))

        if case .frame(let frame) = signal, frame.isKeyframe {
            promoteKeyframe(from: frame, at: timestamp)
        }
    }

    func recordSpeech(_ text: String, at timestamp: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !trimmed.isEmpty else { return }

        ingest(
            .speech(TranscriptSegment(text: trimmed, source: .pushToTalk)),
            at: timestamp
        )
    }

    func resetFromHere() {
        guard isActive else { return }
        signals.removeAll()
        keyframes.removeAll()
        nextKeyframeIndex = 0
        startedAt = Date()
        print("📗 Teaching session reset from current screen")
    }

    func finish() -> TeachingArtifact? {
        guard isActive, let startedAt else { return nil }

        isActive = false
        let artifact = TeachingArtifact(
            startedAt: startedAt,
            finishedAt: Date(),
            signals: signals,
            keyframes: keyframes
        )

        signals = []
        keyframes = []
        self.startedAt = nil
        nextKeyframeIndex = 0

        print("📗 Teaching session finished (\(artifact.keyframes.count) keyframes, \(artifact.signals.count) signals)")
        return artifact
    }

    func cancel() {
        isActive = false
        signals = []
        keyframes = []
        startedAt = nil
        nextKeyframeIndex = 0
    }

    private func promoteKeyframe(from frame: ScreenFrame, at timestamp: Date) {
        let context = signals.last(where: {
            if case .context = $0.signal { return true }
            return false
        }).flatMap { entry -> ContextSnapshot? in
            if case .context(let snapshot) = entry.signal { return snapshot }
            return nil
        }

        let id = "kf-\(nextKeyframeIndex)"
        nextKeyframeIndex += 1

        keyframes.append(
            TeachingKeyframe(
                id: id,
                timestamp: timestamp,
                jpegData: frame.jpegData,
                visualFingerprint: frame.visualFingerprint,
                cursorLocation: frame.cursorLocation,
                context: context
            )
        )
    }
}
