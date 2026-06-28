//
//  ClickyResultPanelView.swift
//  leanring-buddy
//
//  White panel that embeds a web result (stock chart, maps search, etc.).
//

import SwiftUI

struct ClickyResultPanelView: View {
    let payload: ClickyWebResultPayload
    let onClose: () -> Void
    let onOpenInBrowser: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.black.opacity(0.08))

            ClickyWebView(url: payload.url)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: payload.kind == .stockChart ? "chart.line.uptrend.xyaxis" : "map")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.accentText)
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.05), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(payload.kind == .stockChart ? "Stock chart" : "Places")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.88))
                Text(payload.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onOpenInBrowser) {
                Image(systemName: "safari")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .background(Color.black.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Open in browser")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .background(Color.black.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white)
    }
}
