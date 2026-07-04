//
//  PinkyTeachingBriefSheet.swift
//  leanring-buddy
//
//  Short onboarding shown before teaching starts — explains push-to-talk
//  narration and how to finish the session.
//

import SwiftUI

struct PinkyTeachingBriefSheet: View {
    let narrateShortcut: String
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var countdown: Int? = 3
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Show Pinky a workflow")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(DS.Glass.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                briefRow(
                    number: "1",
                    title: "Do the task normally",
                    detail: "Click through it like you usually would. Pinky captures each step from your screen."
                )
                briefRow(
                    number: "2",
                    title: "Narrate with \(narrateShortcut)",
                    detail: "Hold \(narrateShortcut) whenever you want to explain a step. Release when you're done speaking — Pinky ties that narration to the current screen."
                )
                briefRow(
                    number: "3",
                    title: "Tap Stop to finish",
                    detail: "When the workflow is complete, tap Stop in the panel. Pinky will turn it into a saved workflow."
                )
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DS.Glass.surfaceMuted.opacity(0.85))

                if let countdown {
                    Text("\(countdown)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Glass.accent)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: countdown)
                } else {
                    Text("Go!")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Glass.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)

            Text("Starting in a moment…")
                .font(.system(size: 11))
                .foregroundStyle(DS.Glass.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)

            Button("Cancel") {
                countdownTask?.cancel()
                onCancel()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DS.Glass.textSecondary)
            .buttonStyle(.plain)
            .pointerCursor()
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(24)
        .frame(width: 360)
        .glassHubPanel()
        .onAppear {
            startCountdown()
        }
        .onDisappear {
            countdownTask?.cancel()
        }
    }

    private func briefRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DS.Colors.textOnAccent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(DS.Glass.accent))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Glass.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Glass.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 3

        countdownTask = Task {
            for value in stride(from: 3, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    countdown = value
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                countdown = nil
            }
            try? await Task.sleep(nanoseconds: 450_000_000)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                onComplete()
            }
        }
    }
}
