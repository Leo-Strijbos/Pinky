//
//  TeachingPillView.swift
//  leanring-buddy
//
//  Compact cursor-adjacent indicator shown while Pinky is learning a workflow.
//

import SwiftUI

struct TeachingPillView: View {
    let stepCount: Int
    let isProcessing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red.opacity(0.95))
                .frame(width: 6, height: 6)

            Text(isProcessing ? "Processing…" : "Teaching…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.95))

            if stepCount > 0, !isProcessing {
                Text("· \(stepCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 2)
    }
}
