//
//  ClickyWorkflowRecorder.swift
//  leanring-buddy
//
//  Event-driven workflow recording — snapshots on app, URL, window, or visual changes.
//

import Foundation

@MainActor
final class ClickyWorkflowRecorder {
    private var pollTask: Task<Void, Never>?
    private var snapshots: [ClickyWorkflowRawSnapshot] = []
    private var lastSignature: String?
    private var lastCaptureAt: Date?
    private var nextSnapshotIsEntry = false
    private let pollIntervalNanoseconds: UInt64 = 1_500_000_000
    private let minimumCaptureGapNanoseconds: UInt64 = 2_000_000_000

    var snapshotCount: Int {
        snapshots.count
    }

    func start() {
        guard pollTask == nil else { return }
        snapshots = []
        lastSignature = nil
        lastCaptureAt = nil
        nextSnapshotIsEntry = false

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await captureIfNeeded()
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }

        print("🎬 Workflow recording started")
    }

    func stop() -> [ClickyWorkflowRawSnapshot] {
        pollTask?.cancel()
        pollTask = nil
        let captured = snapshots
        snapshots = []
        lastSignature = nil
        lastCaptureAt = nil
        nextSnapshotIsEntry = false
        print("🎬 Workflow recording stopped (\(captured.count) snapshots)")
        return captured
    }

    func attachNarration(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !snapshots.isEmpty else {
            print("🎬 Workflow narration ignored — no snapshot to attach to yet")
            return
        }

        let index = snapshots.count - 1
        if snapshots[index].spokenDescription.isEmpty {
            snapshots[index].spokenDescription = trimmed
        } else {
            snapshots[index].spokenDescription += " \(trimmed)"
        }
        print("🎬 Workflow narration attached to snapshot #\(index + 1): \(trimmed)")
    }

    /// Discards preamble snapshots and restarts from the current screen as step 1.
    func resetFromHere() async {
        snapshots.removeAll()
        lastSignature = nil
        lastCaptureAt = nil
        nextSnapshotIsEntry = true
        await captureIfNeeded(force: true)
        print("🎬 Workflow reset — recording starts from current screen")
    }

    private func captureIfNeeded(force: Bool = false) async {
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let cursorScreen = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first else {
                return
            }

            let context = ClickyWorkflowContextCapture.captureCurrentContext()
            let fingerprint = visualFingerprint(for: cursorScreen.imageData)
            let signature = ClickyWorkflowContextCapture.signature(
                for: context,
                visualFingerprint: fingerprint
            )

            let now = Date()

            if !force {
                if let lastCaptureAt,
                   now.timeIntervalSince(lastCaptureAt) < Double(minimumCaptureGapNanoseconds) / 1_000_000_000,
                   signature == lastSignature {
                    return
                }

                guard signature != lastSignature || snapshots.isEmpty else { return }
            }

            let isEntry = nextSnapshotIsEntry
            nextSnapshotIsEntry = false

            snapshots.append(
                ClickyWorkflowRawSnapshot(
                    imageData: cursorScreen.imageData,
                    app: context.app,
                    url: context.url,
                    windowTitle: context.windowTitle,
                    capturedAt: now,
                    visualFingerprint: fingerprint,
                    spokenDescription: "",
                    isEntryState: isEntry
                )
            )
            lastSignature = signature
            lastCaptureAt = now
            let entryLabel = isEntry ? " [entry]" : ""
            print("🎬 Workflow snapshot #\(snapshots.count)\(entryLabel): \(context.app)\(context.url.map { " — \($0)" } ?? "")")
        } catch {
            print("⚠️ Workflow snapshot failed: \(error.localizedDescription)")
        }
    }

    private func visualFingerprint(for jpegData: Data) -> String {
        ClickyWorkflowVisualFingerprint.fingerprint(for: jpegData)
    }
}
