//
//  ClickyWorkflowVisualFingerprint.swift
//  leanring-buddy
//
//  Compact visual hash for workflow screen matching.
//

import CryptoKit
import Foundation

enum ClickyWorkflowVisualFingerprint {
    static func fingerprint(for jpegData: Data) -> String {
        let digest = SHA256.hash(data: jpegData)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
