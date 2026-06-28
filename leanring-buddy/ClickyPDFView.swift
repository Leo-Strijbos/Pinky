//
//  ClickyPDFView.swift
//  leanring-buddy
//
//  PDFKit wrapper for SOP document panels.
//

import PDFKit
import SwiftUI

struct ClickyPDFView: NSViewRepresentable {
    let fileURL: URL
    let pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .white
        loadDocument(into: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        let currentPath = (pdfView.document?.documentURL as URL?)?.path
        if currentPath != fileURL.path {
            loadDocument(into: pdfView)
            return
        }

        goToPage(pageIndex, in: pdfView)
    }

    private func loadDocument(into pdfView: PDFView) {
        pdfView.document = PDFDocument(url: fileURL)
        goToPage(pageIndex, in: pdfView)
    }

    private func goToPage(_ pageIndex: Int, in pdfView: PDFView) {
        guard let document = pdfView.document else { return }
        let safePageIndex = min(max(pageIndex, 0), max(document.pageCount - 1, 0))
        guard let page = document.page(at: safePageIndex) else { return }
        pdfView.go(to: page)
    }
}
