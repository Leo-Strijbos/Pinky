//
//  PlaybookHubView.swift
//  leanring-buddy
//
//  DEPRECATED — replaced by ClickyResponsePanelView. Unused; safe to delete later.
//

import SwiftUI

private enum HubFilter: String, CaseIterable, Identifiable {
    case all
    case procedures
    case reference

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .procedures: return "Procedures"
        case .reference: return "Reference"
        }
    }

    var kind: PlaybookKind? {
        switch self {
        case .all: return nil
        case .procedures: return .procedure
        case .reference: return .reference
        }
    }
}

struct PlaybookHubView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var searchText = ""
    @State private var selectedFilter: HubFilter = .all
    @State private var selectedPlaybook: Playbook?
    @State private var playbookPendingDelete: Playbook?
    @State private var showPermissions = false

    private var playbookManager: PlaybookManager { companionManager.playbookManager }

    var body: some View {
        VStack(spacing: 0) {
            hubHeader

            if !companionManager.allPermissionsGranted {
                permissionsBanner
            }

            if companionManager.isWalkthroughActive {
                walkthroughBanner
            }

            if let selectedPlaybook {
                PlaybookDetailView(
                    playbook: selectedPlaybook,
                    steps: playbookManager.steps(forPlaybookID: selectedPlaybook.id),
                    companionManager: companionManager,
                    onBack: { self.selectedPlaybook = nil },
                    onDelete: { playbookPendingDelete = selectedPlaybook }
                )
            } else {
                libraryContent
            }

            voiceFooter
        }
        .frame(width: 440, height: 580)
        .glassHubPanel()
        .confirmationDialog(
            "Remove playbook?",
            isPresented: Binding(
                get: { playbookPendingDelete != nil },
                set: { if !$0 { playbookPendingDelete = nil } }
            ),
            presenting: playbookPendingDelete
        ) { playbook in
            Button("Remove", role: .destructive) {
                playbookManager.deletePlaybook(id: playbook.id)
                if selectedPlaybook?.id == playbook.id {
                    selectedPlaybook = nil
                }
                playbookPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                playbookPendingDelete = nil
            }
        } message: { playbook in
            Text("Remove \"\(playbook.title)\" from your knowledge hub?")
        }
        .sheet(isPresented: $showPermissions) {
            PermissionsSheet(companionManager: companionManager)
        }
    }

    // MARK: - Header

    private var hubHeader: some View {
        HStack(spacing: 12) {
            if selectedPlaybook != nil {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Knowledge")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Glass.textPrimary)

                    Text("\(playbookManager.playbookCount) playbook\(playbookManager.playbookCount == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Glass.textTertiary)
                }
            }

            Spacer()

            if selectedPlaybook == nil {
                addMenu
            }

            if !companionManager.allPermissionsGranted {
                Button(action: { showPermissions = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Glass.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(DS.Glass.surfaceMuted))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Glass.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(DS.Glass.surfaceMuted))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var addMenu: some View {
        Menu {
            Button("Import procedure (PDF)") {
                companionManager.presentPlaybookImport(kind: .procedure)
            }
            Button("Import reference (PDF)") {
                companionManager.presentPlaybookImport(kind: .reference)
            }
            Divider()
            Button(playbookManager.isRecording ? "Stop recording" : "Record procedure") {
                companionManager.togglePlaybookRecording()
            }
            .disabled(playbookManager.isProcessing)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DS.Colors.textOnAccent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(DS.Glass.accent))
        }
        .menuStyle(.borderlessButton)
        .pointerCursor()
    }

    // MARK: - Library

    private var libraryContent: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            filterChips
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            if playbookManager.isRecording {
                recordingBanner
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            if let message = playbookManager.lastMessage {
                statusLine(message, isError: false)
            }
            if let error = playbookManager.lastError {
                statusLine(error, isError: true)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    let items = playbookManager.filteredPlaybooks(
                        searchText: searchText,
                        kind: selectedFilter.kind
                    )

                    if items.isEmpty {
                        emptyState
                    } else {
                        ForEach(items) { playbook in
                            PlaybookListCard(playbook: playbook) {
                                selectedPlaybook = playbook
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Glass.textTertiary)

            TextField("Search playbooks…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DS.Glass.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Glass.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DS.Glass.borderSubtle, lineWidth: 0.5)
        )
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(HubFilter.allCases) { filter in
                Button(action: { selectedFilter = filter }) {
                    Text(filter.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selectedFilter == filter ? DS.Glass.textPrimary : DS.Glass.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                selectedFilter == filter
                                    ? DS.Glass.accentSubtle
                                    : DS.Glass.surfaceMuted
                            )
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DS.Glass.textTertiary.opacity(0.6))
                .padding(.top, 40)

            Text("No playbooks yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Glass.textSecondary)

            Text("Import a PDF or record a procedure.\nClicky turns it into docs you can browse or ask about.")
                .font(.system(size: 12))
                .foregroundStyle(DS.Glass.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var recordingBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red.opacity(0.9))
                    .frame(width: 8, height: 8)
                Text("Recording · \(playbookManager.recordingStepCount) steps")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Glass.textPrimary)
                Spacer()
                if playbookManager.isProcessing {
                    ProgressView().controlSize(.small)
                }
            }

            Text("Hold Ctrl+Option on each screen to narrate the step.")
                .font(.system(size: 10))
                .foregroundStyle(DS.Glass.textTertiary)

            Button("Start from here") {
                companionManager.resetPlaybookRecordingFromHere()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DS.Glass.accentText)
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.red.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Banners

    private var permissionsBanner: some View {
        Button(action: { showPermissions = true }) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Colors.warning)
                Text("Grant permissions to use voice")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Glass.textSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Glass.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(DS.Colors.warning.opacity(0.12))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var walkthroughBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(DS.Glass.accentText)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Walkthrough active")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Glass.textPrimary)
                if let status = companionManager.walkthroughStatusText {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Glass.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("End") {
                companionManager.endWalkthrough()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.Glass.accentText)
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(DS.Glass.accentSubtle)
    }

    // MARK: - Footer

    private var voiceFooter: some View {
        VStack(spacing: 0) {
            Divider().background(DS.Glass.borderSubtle)

            HStack(spacing: 10) {
                Circle()
                    .fill(voiceDotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: voiceDotColor.opacity(0.5), radius: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(voiceStatusTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Glass.textPrimary)
                    Text("Hold Ctrl + Option anywhere to ask")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Glass.textTertiary)
                }

                Spacer()

                if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                    Button("Start") {
                        companionManager.completeOnboarding()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Colors.textOnAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(DS.Glass.accent))
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var voiceDotColor: Color {
        switch companionManager.voiceState {
        case .idle: return DS.Colors.success
        case .listening: return DS.Glass.accentText
        case .checking: return DS.Colors.warning
        case .processing: return DS.Colors.warning
        case .responding: return DS.Glass.accentText
        }
    }

    private var voiceStatusTitle: String {
        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .checking: return "Watching…"
        case .processing: return "Thinking…"
        case .responding: return "Speaking…"
        }
    }

    private func statusLine(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isError ? Color.red.opacity(0.85) : DS.Glass.textTertiary)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Detail

struct PlaybookDetailView: View {
    let playbook: Playbook
    let steps: [PlaybookStep]
    @ObservedObject var companionManager: CompanionManager
    let onBack: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Glass.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(DS.Glass.surfaceMuted))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Spacer()

                if playbook.kind == .procedure {
                    Button(action: startWalkthrough) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                            Text("Start")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(DS.Colors.textOnAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(DS.Glass.accent))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else {
                    Button(action: askAboutThis) {
                        Text("Ask about this")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Glass.accentText)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                Menu {
                    if playbook.sourceFileURL != nil {
                        Button("Open original PDF") {
                            openPDF()
                        }
                    }
                    Button("Remove", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Glass.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(DS.Glass.surfaceMuted))
                }
                .menuStyle(.borderlessButton)
                .pointerCursor()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            ScrollView {
                PlaybookDocView(playbook: playbook, steps: steps)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
    }

    private func startWalkthrough() {
        companionManager.startPlaybookWalkthrough(playbookID: playbook.id)
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
    }

    private func askAboutThis() {
        companionManager.playbookManager.pinReferencePlaybook(id: playbook.id)
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
    }

    private func openPDF() {
        guard let fileURL = playbook.sourceFileURL else { return }
        companionManager.openPlaybookPDF(playbook: playbook, fileURL: fileURL)
    }
}

// MARK: - Permissions

private struct PermissionsSheet: View {
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
