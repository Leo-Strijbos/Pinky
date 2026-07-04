//
//  PinkyNotchScreenSupport.swift
//  leanring-buddy
//
//  Helpers for detecting MacBook notch displays and positioning UI beneath
//  the physical notch cutout.
//

import AppKit

enum PinkyNotchScreenSupport {
    /// Returns the built-in display that hosts the physical notch, if any.
    static func preferredNotchScreen() -> NSScreen? {
        if let builtIn = NSScreen.screens.first(where: { hasPhysicalNotch(on: $0) }) {
            return builtIn
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func hasBuiltInNotchDisplay() -> Bool {
        NSScreen.screens.contains(where: { hasPhysicalNotch(on: $0) })
    }

    static func hasPhysicalNotch(on screen: NSScreen) -> Bool {
        guard #available(macOS 12.0, *) else { return false }

        if screenLooksBuiltIn(screen),
           let notchWidth = physicalNotchWidth(on: screen),
           notchWidth > 0 {
            return true
        }

        return isLikelyBuiltInNotchScreen(screen)
    }

    static func physicalNotchWidth(on screen: NSScreen) -> CGFloat? {
        guard #available(macOS 12.0, *),
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              !leftArea.isEmpty,
              !rightArea.isEmpty else {
            return nil
        }

        let gap = rightArea.minX - leftArea.maxX
        return gap > 0 ? gap : nil
    }

    static func notchReservedTopInset(on screen: NSScreen) -> CGFloat? {
        if #available(macOS 12.0, *) {
            let safeTop = screen.safeAreaInsets.top
            if safeTop >= 32 {
                return safeTop
            }
        }

        if hasPhysicalNotch(on: screen) {
            return 32
        }

        return nil
    }

    /// Screen-space rect covering the notch tab and compact Dynamic Island flanks.
    /// Keep this aligned to the visible notch surface only — extending it downward
    /// makes the dropdown open when the cursor is in the gap below the tab.
    static func notchHoverRegion(on screen: NSScreen) -> NSRect {
        let surfaceWidth: CGFloat
        let surfaceHeight: CGFloat

        if hasPhysicalNotch(on: screen) {
            let physicalNotchWidth = physicalNotchWidth(on: screen) ?? 0
            surfaceWidth = max(physicalNotchWidth + 96, 196)
            surfaceHeight = notchReservedTopInset(on: screen) ?? 38
        } else {
            surfaceWidth = PinkyNotchFallbackPillView.contentWidth
            surfaceHeight = PinkyNotchFallbackPillView.contentHeight
        }

        let size = NSSize(width: surfaceWidth, height: surfaceHeight)
        let y = statusSurfaceY(for: size, on: screen)

        return NSRect(
            x: screen.frame.midX - surfaceWidth / 2,
            y: y,
            width: surfaceWidth,
            height: surfaceHeight
        )
    }

    static func statusSurfaceY(for size: NSSize, on screen: NSScreen) -> CGFloat {
        screen.frame.maxY - size.height + 2
    }

    /// Screen-space center of the buddy hand icon in the notch or fallback pill.
    static func buddyHandScreenPoint(on screen: NSScreen) -> CGPoint {
        let handHeight: CGFloat = 34
        let surfaceY = statusSurfaceY(for: NSSize(width: 1, height: handHeight), on: screen)
        let handY = surfaceY + handHeight / 2

        let handX: CGFloat
        if hasPhysicalNotch(on: screen) {
            // DynamicNotch leading flank — left side of the compact island.
            let region = notchHoverRegion(on: screen)
            handX = region.minX + 16
        } else {
            // Fallback pill — hand sits in the leading flank.
            let pillWidth: CGFloat = 156
            handX = screen.frame.midX - pillWidth / 2 + 10 + 16
        }

        return CGPoint(x: handX, y: handY)
    }

    /// Whether this screen hosts the notch / fallback-pill buddy surface.
    static func isNotchHostScreen(_ screen: NSScreen) -> Bool {
        guard let notchScreen = preferredNotchScreen() else { return false }
        return screen.frame == notchScreen.frame
    }

    static func dropdownPanelOrigin(
        for panelSize: NSSize,
        on screen: NSScreen,
        gapBelowNotch: CGFloat = 8
    ) -> NSPoint {
        let originX = screen.frame.midX - panelSize.width / 2
        let notchInset = notchReservedTopInset(on: screen) ?? 28
        let notchBottomY = screen.frame.maxY - notchInset
        let originY = notchBottomY - gapBelowNotch - panelSize.height
        return NSPoint(x: originX, y: originY)
    }

    private static func screenLooksBuiltIn(_ screen: NSScreen) -> Bool {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber.uint32Value) != 0
    }

    private static func isLikelyBuiltInNotchScreen(_ screen: NSScreen) -> Bool {
        guard screenLooksBuiltIn(screen) else { return false }

        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top >= 32
        }

        return false
    }
}
