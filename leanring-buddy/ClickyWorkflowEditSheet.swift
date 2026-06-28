//
//  ClickyWorkflowEditSheet.swift
//  leanring-buddy
//
//  Edit sheet for workflow metadata and steps.
//

import SwiftUI

struct WorkflowEditorPresentation: Identifiable {
    let id: String
}

struct ClickyWorkflowEditSheet: View {
    @ObservedObject var workflowManager: ClickyWorkflowManager
    let workflowID: String
    let onDismiss: () -> Void

    @State private var name = ""
    @State private var goal = ""
    @State private var summary = ""
    @State private var triggerPhrasesText = ""
    @State private var steps: [EditableWorkflowStep] = []
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fieldSection(title: "Name") {
                        editField(text: $name, placeholder: "Workflow name")
                    }

                    fieldSection(title: "Goal") {
                        editField(text: $goal, placeholder: "What this workflow accomplishes")
                    }

                    fieldSection(title: "Summary") {
                        editField(text: $summary, placeholder: "One-line summary")
                    }

                    fieldSection(title: "Trigger phrases") {
                        Text("One phrase per line — voice commands that start this workflow.")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)

                        TextEditor(text: $triggerPhrasesText)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 72)
                            .padding(8)
                            .background(fieldBackground)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Steps")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)

                        if steps.isEmpty {
                            Text("No steps left — add steps by re-recording or cancel delete.")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.textTertiary)
                        }

                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, _ in
                            stepEditor(stepIndex: index)
                        }
                    }
                }
                .padding(16)
            }

            footer
        }
        .frame(width: 420, height: 520)
        .background(DS.Colors.background)
        .onAppear {
            guard !didLoad else { return }
            loadDraft()
            didLoad = true
        }
    }

    private var header: some View {
        HStack {
            Text("Edit workflow")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel", action: onDismiss)
                .buttonStyle(DSSecondaryButtonStyle())

            Spacer()

            Button("Save") {
                saveChanges()
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || steps.isEmpty)
        }
        .padding(16)
        .overlay(alignment: .top) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    @ViewBuilder
    private func fieldSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            content()
        }
    }

    private func editField(text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(fieldBackground)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }

    private func stepEditor(stepIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Step \(stepIndex + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Button(action: {
                    steps.remove(at: stepIndex)
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.destructiveText)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(steps.count <= 1)
            }

            editField(
                text: $steps[stepIndex].name,
                placeholder: "Step name"
            )

            editField(
                text: $steps[stepIndex].meaning,
                placeholder: "What happens on this screen"
            )

            editField(
                text: $steps[stepIndex].spokenDescription,
                placeholder: "Narration (optional)"
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func loadDraft() {
        guard let workflow = workflowManager.workflows.first(where: { $0.id == workflowID }) else { return }

        name = workflow.name
        goal = workflow.goal
        summary = workflow.summary
        triggerPhrasesText = workflow.triggerPhrases.joined(separator: "\n")

        steps = workflowManager.screenStates(forWorkflowID: workflowID).map { state in
            EditableWorkflowStep(
                id: state.id,
                name: state.name,
                meaning: state.meaning,
                spokenDescription: state.spokenDescription,
                sourceState: state
            )
        }
    }

    private func saveChanges() {
        let triggerPhrases = triggerPhrasesText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let updatedSteps = steps.map { draft in
            var state = draft.sourceState
            state.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            state.meaning = draft.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            state.spokenDescription = draft.spokenDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return state
        }

        workflowManager.saveWorkflowEdits(
            workflowID: workflowID,
            name: name,
            goal: goal,
            summary: summary,
            triggerPhrases: triggerPhrases,
            steps: updatedSteps
        )
        onDismiss()
    }
}

private struct EditableWorkflowStep: Identifiable {
    let id: String
    var name: String
    var meaning: String
    var spokenDescription: String
    let sourceState: ClickyWorkflowScreenState
}
