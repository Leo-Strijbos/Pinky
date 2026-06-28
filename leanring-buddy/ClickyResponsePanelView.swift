//
//  ClickyResponsePanelView.swift
//  leanring-buddy
//
//  Notch dropdown — streams Clicky's spoken response text.
//

import AppKit
import SwiftUI

private enum ClickyPanelTypography {
    static let response = Font.system(size: 15, weight: .regular, design: .default)
    static let caption = Font.system(size: 13, weight: .regular, design: .default)
    static let status = Font.system(size: 12, weight: .medium, design: .default)
}

struct ClickyResponsePanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var showPermissions = false

    private let horizontalPadding: CGFloat = 22
    private let verticalPadding: CGFloat = 12

    private var visibleResponseText: String {
        ClickyPanelDisplayText.visibleWindow(from: companionManager.streamingResponseText)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !companionManager.allPermissionsGranted {
                permissionsBanner
            }

            if companionManager.isBluetoothInputDeviceSelected {
                bluetoothInputBanner
            }

            responseContent

            Spacer(minLength: 0)

            voiceFooter
        }
        .frame(
            width: ClickyResponsePanelLayout.width,
            height: ClickyResponsePanelLayout.height
        )
        .glassResponsePanel()
        .sheet(isPresented: $showPermissions) {
            ClickyPermissionsSheet(companionManager: companionManager)
        }
    }

    // MARK: - Content

    private var responseContent: some View {
        Group {
            if !companionManager.streamingResponseText.isEmpty {
                Text(visibleResponseText)
                    .font(ClickyPanelTypography.response)
                    .foregroundStyle(DS.Glass.textPrimary.opacity(0.92))
                    .lineSpacing(4)
                    .tracking(-0.1)
                    .lineLimit(ClickyPanelDisplayText.maxVisibleLines)
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
            if companionManager.voiceState == .processing
                || companionManager.voiceState == .checking
                || companionManager.isResponsePanelStreaming {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DS.Colors.overlayCursorBrand)
                    Text("Thinking…")
                        .font(ClickyPanelTypography.caption)
                        .foregroundStyle(DS.Glass.textSecondary)
                }
            } else {
                Text("Hold Ctrl + Option to ask")
                    .font(ClickyPanelTypography.caption)
                    .foregroundStyle(DS.Glass.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionsBanner: some View {
        Button(action: { showPermissions = true }) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.warning)
                Text("Grant permissions to use voice")
                    .font(ClickyPanelTypography.status)
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
                    .font(ClickyPanelTypography.status)
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
                .font(ClickyPanelTypography.status)
                .foregroundStyle(DS.Glass.textSecondary)

            Spacer(minLength: 0)

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
            .help("Quit Clicky")
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Divider().background(DS.Glass.borderSubtle.opacity(0.6))
        }
    }

    private var voiceDotColor: Color {
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

        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .checking: return "Watching…"
        case .processing: return "Thinking…"
        case .responding: return "Speaking…"
        }
    }
}

// MARK: - Permissions

private struct ClickyPermissionsSheet: View {
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
