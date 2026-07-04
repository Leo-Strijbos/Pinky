//
//  TeachingModels.swift
//  leanring-buddy
//
//  Core types for workflow teaching: signals, artifacts, and drafts.
//

import CoreGraphics
import Foundation

// MARK: - Signals

struct ScreenFrame: Sendable, Equatable {
    let jpegData: Data
    let visualFingerprint: String
    let cursorLocation: CGPoint
    /// When true, the frame is promoted to a durable keyframe for step synthesis.
    let isKeyframe: Bool
}

struct PointerEvent: Sendable, Equatable {
    enum Kind: String, Sendable {
        case click
        case scroll
    }

    let kind: Kind
    let location: CGPoint
    let button: Int?
}

struct ContextSnapshot: Sendable, Equatable {
    let app: String
    let url: String?
    let windowTitle: String?

    var signature: String {
        [
            app.lowercased(),
            url?.lowercased() ?? "",
            windowTitle?.lowercased() ?? "",
        ].joined(separator: "|")
    }

    var screenContext: ScreenContext {
        ScreenContext(app: app, url: url, windowTitle: windowTitle)
    }

    init(app: String, url: String?, windowTitle: String?) {
        self.app = app
        self.url = url
        self.windowTitle = windowTitle
    }

    init(screenContext: ScreenContext) {
        self.app = screenContext.app
        self.url = screenContext.url
        self.windowTitle = screenContext.windowTitle
    }
}

struct TranscriptSegment: Sendable, Equatable {
    let text: String
    let source: Source

    enum Source: String, Sendable {
        case pushToTalk
    }
}

enum WorkflowSignal: Sendable, Equatable {
    case frame(ScreenFrame)
    case pointer(PointerEvent)
    case context(ContextSnapshot)
    case speech(TranscriptSegment)
}

struct TimestampedSignal: Sendable, Equatable {
    let timestamp: Date
    let signal: WorkflowSignal
}

// MARK: - Artifact

struct TeachingKeyframe: Sendable, Equatable {
    let id: String
    let timestamp: Date
    let jpegData: Data
    let visualFingerprint: String
    let cursorLocation: CGPoint
    let context: ContextSnapshot?
}

struct TeachingArtifact: Sendable {
    let startedAt: Date
    let finishedAt: Date
    let signals: [TimestampedSignal]
    let keyframes: [TeachingKeyframe]
}
