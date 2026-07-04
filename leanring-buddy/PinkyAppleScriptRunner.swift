//
//  PinkyAppleScriptRunner.swift
//  leanring-buddy
//
//  Runs local AppleScript for app automation (Spotify playback, etc.).
//

import Foundation

enum PinkyAppleScriptRunner {
    struct Result {
        let terminationStatus: Int32
        let output: String
        let errorOutput: String

        var succeeded: Bool {
            terminationStatus == 0
        }
    }

    static func run(_ script: String) -> Result {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return Result(
                terminationStatus: -1,
                output: "",
                errorOutput: error.localizedDescription
            )
        }

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return Result(
            terminationStatus: process.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? "",
            errorOutput: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}
