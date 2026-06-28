//
//  PlaybookDocView.swift
//  leanring-buddy
//
//  Beautiful rendered documentation from playbook doc blocks.
//

import SwiftUI

struct PlaybookDocView: View {
    let playbook: Playbook
    let steps: [PlaybookStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if playbook.docBlocks.isEmpty {
                fallbackContent
            } else {
                ForEach(playbook.docBlocks) { block in
                    blockView(block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: PlaybookDocBlock) -> some View {
        switch block.kind {
        case .hero:
            VStack(alignment: .leading, spacing: 8) {
                Text(block.title ?? playbook.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Glass.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let body = block.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(DS.Glass.textSecondary)
                        .lineSpacing(4)
                }

                tagRow
            }
            .padding(.bottom, 4)

        case .heading:
            Text(block.title ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Glass.accentText)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.top, 4)

        case .paragraph:
            Text(block.body ?? "")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(DS.Glass.textSecondary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

        case .steps:
            VStack(alignment: .leading, spacing: 10) {
                if let title = block.title {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Glass.textPrimary)
                }

                if let items = block.items {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        stepRow(number: index + 1, text: item)
                    }
                } else if !steps.isEmpty {
                    ForEach(steps.sorted { $0.index < $1.index }) { step in
                        stepRow(number: step.index + 1, text: "\(step.title): \(step.instruction)")
                    }
                }
            }

        case .callout:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Glass.accentText)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    if let title = block.title {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Glass.textPrimary)
                    }
                    if let body = block.body {
                        Text(body)
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Glass.textSecondary)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(14)
            .glassHubCard()
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Glass.accentSubtle, lineWidth: 1)
            )

        case .divider:
            Rectangle()
                .fill(DS.Glass.borderSubtle)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textOnAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DS.Glass.accent))

            Text(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(DS.Glass.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tagRow: some View {
        HStack(spacing: 6) {
            kindBadge

            ForEach(playbook.tags.prefix(4), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Glass.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(DS.Glass.surfaceMuted)
                    )
            }
        }
    }

    private var kindBadge: some View {
        Text(playbook.kind == .procedure ? "Procedure" : "Reference")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(playbook.kind == .procedure ? DS.Glass.accentText : DS.Glass.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(playbook.kind == .procedure ? DS.Glass.accentSubtle : DS.Glass.surfaceMuted)
            )
    }

    private var fallbackContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(playbook.title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Glass.textPrimary)

            Text(playbook.summary)
                .font(.system(size: 14))
                .foregroundStyle(DS.Glass.textSecondary)

            if !steps.isEmpty {
                ForEach(steps.sorted { $0.index < $1.index }) { step in
                    stepRow(number: step.index + 1, text: "\(step.title): \(step.instruction)")
                }
            }
        }
    }
}

struct PlaybookListCard: View {
    let playbook: Playbook
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: playbook.kind == .procedure
                                ? [DS.Colors.accentText, DS.Glass.accent]
                                : [DS.Glass.textTertiary.opacity(0.35), DS.Glass.textTertiary.opacity(0.2)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(playbook.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Glass.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(playbook.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Glass.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        Label(
                            playbook.kind == .procedure ? "\(playbook.stepCount) steps" : "Reference",
                            systemImage: playbook.kind == .procedure ? "list.number" : "doc.text"
                        )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Glass.textTertiary)

                        if let firstTag = playbook.tags.first {
                            Text(firstTag)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(DS.Glass.accentText.opacity(0.85))
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Glass.textTertiary.opacity(isHovered ? 0.9 : 0.45))
            }
            .padding(14)
            .glassHubCard(isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
    }
}
