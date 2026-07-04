//
//  PinkyWorkflowOCR.swift
//  leanring-buddy
//
//  Extracts on-screen text terms for workflow screen matching.
//

import AppKit
import Foundation
import Vision

enum PinkyWorkflowOCR {

    static func recognizeTerms(from jpegData: Data, limit: Int = 32) -> [String] {
        guard let image = NSImage(data: jpegData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("⚠️ Workflow OCR failed: \(error.localizedDescription)")
            return []
        }

        guard let observations = request.results else { return [] }

        var terms: [String] = []
        var seen: Set<String> = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let tokens = tokenize(candidate.string)
            for token in tokens where !seen.contains(token) {
                seen.insert(token)
                terms.append(token)
                if terms.count >= limit {
                    return terms
                }
            }
        }

        return terms
    }

    private static func tokenize(_ raw: String) -> [String] {
        raw
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && $0.count <= 32 }
    }
}
