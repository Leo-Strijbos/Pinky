//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures only the display where the cursor currently is.
    static func captureCursorScreenAsJPEG() async throws -> CompanionScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No display available for capture"]
            )
        }

        let mouseLocation = NSEvent.mouseLocation
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        let cursorDisplay = content.displays.first { display in
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(
                    x: display.frame.origin.x,
                    y: display.frame.origin.y,
                    width: CGFloat(display.width),
                    height: CGFloat(display.height)
                )
            return displayFrame.contains(mouseLocation)
        } ?? content.displays[0]

        let displayFrame = nsScreenByDisplayID[cursorDisplay.displayID]?.frame
            ?? CGRect(
                x: cursorDisplay.frame.origin.x,
                y: cursorDisplay.frame.origin.y,
                width: CGFloat(cursorDisplay.width),
                height: CGFloat(cursorDisplay.height)
            )

        return try await captureDisplay(
            cursorDisplay,
            displayFrame: displayFrame,
            label: "user's screen (cursor is here)",
            isCursorScreen: true,
            excludingWindows: ownAppWindows
        )
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No display available for capture"]
            )
        }

        let mouseLocation = NSEvent.mouseLocation
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(
                    x: display.frame.origin.x,
                    y: display.frame.origin.y,
                    width: CGFloat(display.width),
                    height: CGFloat(display.height)
                )
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            let capture = try await captureDisplay(
                display,
                displayFrame: displayFrame,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                excludingWindows: ownAppWindows
            )
            capturedScreens.append(capture)
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"]
            )
        }

        return capturedScreens
    }

    private static func captureDisplay(
        _ display: SCDisplay,
        displayFrame: CGRect,
        label: String,
        isCursorScreen: Bool,
        excludingWindows: [SCWindow]
    ) async throws -> CompanionScreenCapture {
        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)

        let configuration = SCStreamConfiguration()
        let maxDimension = 1280
        let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
        if display.width >= display.height {
            configuration.width = maxDimension
            configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
        }

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode screenshot"]
            )
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: label,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )
    }
}
