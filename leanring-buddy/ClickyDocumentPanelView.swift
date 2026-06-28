//
//  ClickyDocumentPanelView.swift
//  leanring-buddy
//
//  White panel for viewing SOP PDFs returned by knowledge retrieval.
//

import SwiftUI

struct ClickyDocumentPanelView: View {
    let sources: [ClickyKnowledgeSourceDocument]
    let onClose: () -> Void
    let onOpenInPreview: (ClickyKnowledgeSourceDocument) -> Void

    @State private var selectedSourceID: String?

    private var selectedSource: ClickyKnowledgeSourceDocument? {
        if let selectedSourceID,
           let matchedSource = sources.first(where: { $0.documentID == selectedSourceID }) {
            return matchedSource
        }
        return sources.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.black.opacity(0.08))

            if sources.count > 1 {
                sourcePicker
                Divider().background(Color.black.opacity(0.08))
            }

            if let selectedSource {
                ClickyPDFView(fileURL: selectedSource.fileURL, pageIndex: selectedSource.pageIndex)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            } else {
                Text("No document selected")
                    .foregroundStyle(Color.black.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 640)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            selectedSourceID = sources.first?.documentID
        }
        .onChange(of: sources.map(\.documentID)) { _, newIDs in
            if let selectedSourceID, newIDs.contains(selectedSourceID) {
                return
            }
            self.selectedSourceID = sources.first?.documentID
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.accentText)
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.05), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("SOP")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.88))
                Text(selectedSource?.title ?? "Document")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer()

            if let selectedSource {
                Button(action: { onOpenInPreview(selectedSource) }) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.55))
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Open in Preview")
            }

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

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources, id: \.documentID) { source in
                    Button(action: { selectedSourceID = source.documentID }) {
                        Text(source.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(
                                selectedSourceID == source.documentID
                                    ? Color.white
                                    : Color.black.opacity(0.65)
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(
                                        selectedSourceID == source.documentID
                                            ? DS.Colors.accentText
                                            : Color.black.opacity(0.06)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}
