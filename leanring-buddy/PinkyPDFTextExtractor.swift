//
//  PinkyPDFTextExtractor.swift
//  leanring-buddy
//
//  Extracts text from local PDF files for observe capabilities.
//

import Foundation
import PDFKit

enum PinkyPDFTextExtractor {

    static func extractText(from url: URL, maxPages: Int, maxChars: Int) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }

        let pageLimit = min(max(maxPages, 1), document.pageCount)
        var collected = ""
        collected.reserveCapacity(min(maxChars, 4096))

        for pageIndex in 0..<pageLimit {
            guard let page = document.page(at: pageIndex),
                  let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pageText.isEmpty else {
                continue
            }

            if !collected.isEmpty {
                collected += "\n\n"
            }

            collected += "[page \(pageIndex + 1)]\n\(pageText)"

            if collected.count >= maxChars {
                collected = String(collected.prefix(maxChars))
                collected += "\n\n[truncated]"
                break
            }
        }

        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
