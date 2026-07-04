//
//  PinkyResponsePanelView.swift
//  leanring-buddy
//
//  Notch dropdown — streams Pinky's spoken response text.
//

import AppKit
import SwiftUI

private enum PinkyPanelTypography {
    static let response = Font.system(size: 15, weight: .regular, design: .default)
    static let caption = Font.system(size: 13, weight: .regular, design: .default)
    static let status = Font.system(size: 12, weight: .medium, design: .default)
}

struct PinkyResponsePanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var showPermissions = false

    private let horizontalPadding: CGFloat = 22
    private let verticalPadding: CGFloat = 12

    private var skillManager: SkillManager { companionManager.skillManager }

    private var visibleResponseText: String {
        PinkyPanelDisplayText.visibleWindow(from: companionManager.streamingResponseText)
    }

    private var isTeachingUIActive: Bool {
        companionManager.isTeaching || companionManager.isTeachingProcessing
    }

    var body: some View {
        VStack(spacing: 0) {
            if !companionManager.allPermissionsGranted {
                permissionsBanner
            }

            if companionManager.isBluetoothInputDeviceSelected {
                bluetoothInputBanner
            }

            if isTeachingUIActive {
                teachingStrip
            }

            responseContent

            Spacer(minLength: 0)

            voiceFooter
        }
        .frame(
            width: PinkyResponsePanelLayout.width,
            height: PinkyResponsePanelLayout.height
        )
        .glassResponsePanel()
        .sheet(isPresented: $showPermissions) {
            PinkyPermissionsSheet(companionManager: companionManager)
        }
        .sheet(isPresented: $companionManager.isTeachingBriefPresented) {
            PinkyTeachingBriefSheet(
                narrateShortcut: BuddyPushToTalkShortcut.pushToTalkDisplayText,
                onComplete: {
                    companionManager.completeTeachingBrief()
                },
                onCancel: {
                    companionManager.cancelTeachingBrief()
                }
            )
        }
        .sheet(isPresented: teachingSaveSheetBinding) {
            PinkyTeachingSaveSheet(companionManager: companionManager)
        }
    }

    private var teachingSaveSheetBinding: Binding<Bool> {
        Binding(
            get: { skillManager.pendingDraft != nil },
            set: { _ in }
        )
    }

    // MARK: - Content

    private var responseContent: some View {
        Group {
            if !companionManager.streamingResponseText.isEmpty {
                Text(visibleResponseText)
                    .font(PinkyPanelTypography.response)
                    .foregroundStyle(DS.Glass.textPrimary.opacity(0.92))
                    .lineSpacing(4)
                    .tracking(-0.1)
                    .lineLimit(PinkyPanelDisplayText.maxVisibleLines)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .animation(.easeOut(duration: 0.18), value: visibleResponseText)
            } else {
                emptyStateContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, verticalPadding)
    }

    private var emptyStateContent: some View {
        Group {
            if isTeachingUIActive {
                Text(companionManager.isTeachingProcessing
                    ? "Turning what you did into steps…"
                    : "Do the task. Hold \(BuddyPushToTalkShortcut.pushToTalkDisplayText) to narrate a step, then tap Stop when you're done.")
                    .font(PinkyPanelTypography.caption)
                    .foregroundStyle(DS.Glass.textSecondary)
                    .lineSpacing(3)
            } else if companionManager.voiceState == .processing
                || companionManager.voiceState == .checking
                || companionManager.isResponsePanelStreaming {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DS.Colors.overlayCursorBrand)
                    Text("Thinking…")
                        .font(PinkyPanelTypography.caption)
                        .foregroundStyle(DS.Glass.textSecondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hold Ctrl + Option to ask")
                        .font(PinkyPanelTypography.caption)
                        .foregroundStyle(DS.Glass.textTertiary)

                    if companionManager.allPermissionsGranted && companionManager.hasCompletedOnboarding {
                        Text("Or tap Teach me to show Pinky a workflow.")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Glass.textTertiary.opacity(0.85))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var teachingStrip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red.opacity(0.9))
                .frame(width: 6, height: 6)

            Text(companionManager.isTeachingProcessing
                ? "Processing workflow…"
                : "Teaching · \(companionManager.teachingStepCount) steps")
                .font(PinkyPanelTypography.status)
                .foregroundStyle(DS.Glass.textPrimary)

            Spacer(minLength: 0)

            if companionManager.isTeachingProcessing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("From here") {
                    companionManager.resetPlaybookRecordingFromHere()
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DS.Glass.accentText)
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private var permissionsBanner: some View {
        Button(action: { showPermissions = true }) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.warning)
                Text("Grant permissions to use voice")
                    .font(PinkyPanelTypography.status)
                    .foregroundStyle(DS.Glass.textSecondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Glass.textTertiary)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 8)
            .background(DS.Colors.warning.opacity(0.1))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var bluetoothInputBanner: some View {
        Button(action: { companionManager.openSoundInputSettings() }) {
            HStack(spacing: 8) {
                Image(systemName: "airpods")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.warning)
                Text(bluetoothBannerTitle)
                    .font(PinkyPanelTypography.status)
                    .foregroundStyle(DS.Glass.textSecondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Glass.textTertiary)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 8)
            .background(DS.Colors.warning.opacity(0.1))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var bluetoothBannerTitle: String {
        let name = companionManager.selectedInputDeviceName.lowercased()
        if name.contains("airpod") {
            return "AirPods can't be used for voice — switch to your Mac's mic"
        }
        return "Bluetooth mic can't be used for voice — switch input in Sound Settings"
    }

    // MARK: - Footer

    private var voiceFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(voiceDotColor)
                .frame(width: 6, height: 6)

            Text(voiceStatusTitle)
                .font(PinkyPanelTypography.status)
                .foregroundStyle(DS.Glass.textSecondary)

            Spacer(minLength: 0)

            if companionManager.allPermissionsGranted && companionManager.hasCompletedOnboarding {
                teachingFooterButton
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Button("Start") {
                    companionManager.completeOnboarding()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Colors.textOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(DS.Glass.accent))
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Glass.textTertiary.opacity(0.85))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Quit Pinky")
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Divider().background(DS.Glass.borderSubtle.opacity(0.6))
        }
    }

    @ViewBuilder
    private var teachingFooterButton: some View {
        if companionManager.isTeaching {
            Button("Stop") {
                companionManager.toggleTeaching()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.Glass.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(DS.Glass.surfaceMuted))
            .buttonStyle(.plain)
            .pointerCursor()
        } else if skillManager.pendingDraft == nil {
            Button("Teach me") {
                companionManager.toggleTeaching()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.Colors.textOnAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(DS.Glass.accent))
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(skillManager.isProcessing)
        }
    }

    private var voiceDotColor: Color {
        if companionManager.isTeaching {
            return Color.red.opacity(0.9)
        }

        switch companionManager.voiceState {
        case .idle: return DS.Colors.success
        case .listening: return DS.Colors.overlayCursorBrand
        case .checking: return DS.Colors.warning
        case .processing: return DS.Colors.warning
        case .responding: return DS.Colors.overlayCursorBrand
        }
    }

    private var voiceStatusTitle: String {
        if companionManager.isBluetoothInputDeviceSelected {
            return "Bluetooth mic unavailable"
        }

        if companionManager.isTeaching {
            return "Teaching · \(companionManager.teachingStepCount) steps"
        }

        if companionManager.isTeachingProcessing {
            return "Processing workflow…"
        }

        if skillManager.pendingDraft != nil {
            return "Ready to save workflow"
        }

        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .checking: return "Watching…"
        case .processing: return "Thinking…"
        case .responding: return "Speaking…"
        }
    }
}

// MARK: - Teaching Save

private struct PinkyTeachingSaveSheet: View {
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.dismiss) private var dismiss

    private var skillManager: SkillManager { companionManager.skillManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save this workflow?")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(DS.Glass.textPrimary)

            Text("Pinky learned \(skillManager.pendingDraft?.steps.count ?? 0) steps.")
                .font(.system(size: 12))
                .foregroundStyle(DS.Glass.textTertiary)

            TextField(
                "Workflow name",
                text: Binding(
                    get: { skillManager.pendingDraftTitle },
                    set: { skillManager.pendingDraftTitle = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Glass.surfaceMuted)
            )

            HStack(spacing: 12) {
                Button("Discard") {
                    skillManager.cancelPendingDraft()
                    dismiss()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Glass.textSecondary)
                .buttonStyle(.plain)
                .pointerCursor()

                Spacer(minLength: 0)

                Button("Save") {
                    Task {
                        await skillManager.confirmTeachingSave()
                        dismiss()
                    }
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(skillManager.isProcessing)
            }
        }
        .padding(24)
        .frame(width: 340)
        .glassHubPanel()
    }
}

// MARK: - Permissions

private struct PinkyPermissionsSheet: View {
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(DS.Glass.textPrimary)

            permissionRow(
                title: "Microphone",
                granted: companionManager.hasMicrophonePermission,
                action: { companionManager.requestMicrophonePermission() }
            )
            permissionRow(
                title: "Accessibility",
                granted: companionManager.hasAccessibilityPermission,
                action: { companionManager.openAccessibilitySettings() }
            )
            permissionRow(
                title: "Screen Recording",
                granted: companionManager.hasScreenRecordingPermission,
                action: { companionManager.openScreenRecordingSettings() }
            )

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(DSPrimaryButtonStyle())
        }
        .padding(24)
        .frame(width: 360, height: 320)
        .glassHubPanel()
    }

    private func permissionRow(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Glass.textPrimary)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.Colors.success)
            } else {
                Button("Grant", action: action)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Glass.accentText)
                    .buttonStyle(.plain)
                    .pointerCursor()
            }
        }
        .padding(.vertical, 8)
    }
}
