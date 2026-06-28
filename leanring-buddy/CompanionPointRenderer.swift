//
//  CompanionPointRenderer.swift
//  leanring-buddy
//
//  Maps screenshot pixel coordinates to global AppKit screen locations.
//

import CoreGraphics
import Foundation

enum CompanionPointRenderer {

    struct RenderedPoint: Equatable {
        let globalLocation: CGPoint
        let displayFrame: CGRect
        let label: String
    }

    static func render(
        pointTarget: CompanionPointTarget,
        on capture: CompanionScreenCapture
    ) -> RenderedPoint {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        let clampedX = max(0, min(CGFloat(pointTarget.x), screenshotWidth))
        let clampedY = max(0, min(CGFloat(pointTarget.y), screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        let globalLocation = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )

        return RenderedPoint(
            globalLocation: globalLocation,
            displayFrame: displayFrame,
            label: pointTarget.label
        )
    }
}
