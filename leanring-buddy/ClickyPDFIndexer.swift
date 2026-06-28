//
//  ClickyPDFIndexer.swift
//  leanring-buddy
//
//  Extracts text from PDFs and builds searchable chunks.
//

import Foundation
import PDFKit

enum ClickyPDFIndexer {

    static func indexDocument(
        sourceURL: URL,
        preferredTitle: String? = nil
    ) throws -> (ClickyKnowledgeDocument, [ClickyKnowledgeChunk]) {
        guard let pdfDocument = PDFDocument(url: sourceURL) else {
            throw indexerError("Could not read PDF.")
        }

        let originalFilename = sourceURL.deletingPathExtension().lastPathComponent
        let title = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? preferredTitle!.trimmingCharacters(in: .whitespacesAndNewlines)
            : originalFilename.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")

        let documentID = slugify(title)
        let destinationFilename = "\(documentID).pdf"
        let destinationURL = ClickyKnowledgePaths.documentsDirectory.appendingPathComponent(destinationFilename)

        try FileManager.default.createDirectory(
            at: ClickyKnowledgePaths.documentsDirectory,
            withIntermediateDirectories: true
        )

        if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        let aliases = defaultAliases(for: title, documentID: documentID)
        let knowledgeDocument = ClickyKnowledgeDocument(
            id: documentID,
            title: title,
            filename: destinationFilename,
            aliases: aliases,
            importedAt: Date(),
            kind: .reference
        )

        var chunks: [ClickyKnowledgeChunk] = []
        let pageCount = pdfDocument.pageCount

        for pageIndex in 0..<pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pageText.isEmpty else { continue }

            let splitChunks = chunkText(pageText)
            for (chunkIndex, chunkText) in splitChunks.enumerated() {
                chunks.append(
                    ClickyKnowledgeChunk(
                        id: "\(documentID)-p\(pageIndex)-c\(chunkIndex)",
                        documentID: documentID,
                        documentTitle: title,
                        pageIndex: pageIndex,
                        chunkIndex: chunkIndex,
                        text: chunkText,
                        relevanceScore: 0
                    )
                )
            }
        }

        guard !chunks.isEmpty else {
            throw indexerError("This PDF has no extractable text. Scanned documents are not supported yet.")
        }

        return (knowledgeDocument, chunks)
    }

    private static func chunkText(_ text: String) -> [String] {
        let normalizedText = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let maxChunkLength = 900
        guard normalizedText.count > maxChunkLength else {
            return [normalizedText]
        }

        var chunks: [String] = []
        var startIndex = normalizedText.startIndex

        while startIndex < normalizedText.endIndex {
            let endIndex = normalizedText.index(
                startIndex,
                offsetBy: maxChunkLength,
                limitedBy: normalizedText.endIndex
            ) ?? normalizedText.endIndex

            let chunk = String(normalizedText[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }

            if endIndex == normalizedText.endIndex {
                break
            }
            startIndex = endIndex
        }

        return chunks.isEmpty ? [normalizedText] : chunks
    }

    private static func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        let slug = lowered.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if slug.isEmpty {
            return "document-\(UUID().uuidString.prefix(8))"
        }
        return slug
    }

    private static func defaultAliases(for title: String, documentID: String) -> [String] {
        var aliases = Set<String>()
        aliases.insert(title.lowercased())
        aliases.insert(documentID.lowercased())

        if title.lowercased().contains("sop") == false {
            aliases.insert("\(title.lowercased()) sop")
        }

        return Array(aliases).sorted()
    }

    private static func indexerError(_ message: String) -> NSError {
        NSError(domain: "ClickyPDFIndexer", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
