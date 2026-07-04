//
//  CompanionSessionPlanningContext.swift
//  leanring-buddy
//
//  Shared screen capture and local context for session planning phases.
//

import Foundation

struct CompanionSessionPlanningCapture {
    let screenCapture: CompanionScreenCapture
    let screenContext: ScreenContext

    var labeledImage: (data: Data, label: String) {
        let dimensionInfo =
            " (image dimensions: \(screenCapture.screenshotWidthInPixels)x\(screenCapture.screenshotHeightInPixels) pixels)"
        return (
            data: screenCapture.imageData,
            label: screenCapture.label + dimensionInfo
        )
    }
}

enum CompanionSessionPlanningContext {

    static func capture() async throws -> CompanionSessionPlanningCapture {
        CompanionSessionPlanningCapture(
            screenCapture: try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG(),
            screenContext: ScreenContextCapture.captureCurrentContext()
        )
    }

    static func screenContextAppendix(for context: ScreenContext) -> String {
        var lines = [
            "local screen context (metadata only — may or may not relate to the user's request):",
            "platform: macOS",
            "frontmost app: \(context.app)",
        ]

        if let windowTitle = context.windowTitle, !windowTitle.isEmpty {
            lines.append("front window title: \(windowTitle)")
        }
        if let url = context.url, !url.isEmpty {
            lines.append("browser url: \(url)")
        }

        lines.append(
            "use this only when it clearly helps answer the user's request. ignore it when unrelated."
        )
        return lines.joined(separator: "\n")
    }
}
