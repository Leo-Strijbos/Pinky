//
//  BuddyAudioConversionSupport.swift
//  leanring-buddy
//
//  Shared audio conversion helpers for voice transcription providers.
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum BuddyMicrophoneCaptureUtilities {
    static func defaultInputDeviceDescription() -> String {
        guard let deviceID = defaultInputDeviceID() else { return "unknown input" }
        return inputDeviceName(for: deviceID)
    }

    static func isDefaultInputDeviceBluetooth() -> Bool {
        guard let deviceID = defaultInputDeviceID() else { return false }
        return isBluetoothInputDevice(deviceID)
    }

    /// Attempts to bind the system default input device on the AudioUnit.
    /// Returns false instead of throwing — assignment often fails on Bluetooth
    /// after the graph is connected (-10851), and a fresh engine already
    /// follows the system default input.
    @discardableResult
    static func tryAssignDefaultInputDevice(to inputNode: AVAudioInputNode) -> Bool {
        guard let deviceID = defaultInputDeviceID() else {
            print("🎙️ Could not assign input device — no default input device")
            return false
        }

        guard let audioUnit = inputNode.audioUnit else {
            print("🎙️ Could not assign input device — AudioUnit not ready yet")
            return false
        }

        var resolvedDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &resolvedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            print(
                "🎙️ Could not assign input device \(inputDeviceName(for: deviceID)) "
                    + "(Core Audio status \(status)) — using system default routing"
            )
            return false
        }

        print("🎙️ Assigned input device: \(inputDeviceName(for: deviceID))")
        return true
    }

    /// Opens a brief throwaway engine to force macOS into the Bluetooth HFP mic
    /// profile before the real capture engine starts.
    static func activateBluetoothHFPCaptureProfile() async {
        print("🎙️ Probing Bluetooth mic to activate HFP profile")

        let probeEngine = AVAudioEngine()
        let probeInputNode = probeEngine.inputNode
        let probeMixerNode = probeEngine.mainMixerNode
        let probeOutputNode = probeEngine.outputNode

        probeEngine.connect(probeInputNode, to: probeMixerNode, format: nil)
        probeEngine.connect(probeMixerNode, to: probeOutputNode, format: nil)
        probeMixerNode.outputVolume = 0

        do {
            probeEngine.prepare()
            try probeEngine.start()
            await waitForBluetoothHFPActivation()
            try await Task.sleep(nanoseconds: 150_000_000)
        } catch {
            print("🎙️ Bluetooth HFP probe engine failed to start: \(error)")
        }

        probeEngine.stop()
        probeEngine.reset()
    }

    /// Reads the actual hardware stream format for the default input device.
    static func defaultInputHardwareAVAudioFormat() -> AVAudioFormat? {
        guard let deviceID = defaultInputDeviceID(),
              var streamFormat = inputStreamFormat(for: deviceID) else {
            return nil
        }

        return AVAudioFormat(streamDescription: &streamFormat)
    }

    /// After the engine starts, Bluetooth headsets switch from A2DP playback
    /// (48 kHz) to HFP capture (typically 16 kHz). Poll the device stream
    /// format until the mic profile is active.
    static func waitForBluetoothHFPActivation() async {
        guard let deviceID = defaultInputDeviceID(),
              isBluetoothInputDevice(deviceID) else {
            return
        }

        let maxWaitSeconds: TimeInterval = 3.0
        let pollIntervalNanoseconds: UInt64 = 100_000_000
        let waitDeadline = Date().addingTimeInterval(maxWaitSeconds)

        while Date() < waitDeadline {
            if let streamFormat = inputStreamFormat(for: deviceID),
               streamFormat.mSampleRate > 0,
               streamFormat.mSampleRate <= 24_000 {
                print(
                    "🎙️ Bluetooth HFP active — hardware input "
                        + "\(streamFormat.mSampleRate)Hz, \(streamFormat.mChannelsPerFrame) channel(s)"
                )
                try? await Task.sleep(nanoseconds: 200_000_000)
                return
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        if let streamFormat = inputStreamFormat(for: deviceID) {
            print(
                "🎙️ Bluetooth HFP settle timed out — hardware still reports "
                    + "\(streamFormat.mSampleRate)Hz; proceeding anyway"
            )
        } else {
            print("🎙️ Bluetooth HFP settle timed out — could not read hardware format")
        }
    }

    /// AirPods and other Bluetooth headsets switch from A2DP playback to HFP
    /// capture when the mic opens. The sample rate can jump (e.g. 48 kHz → 16 kHz)
    /// over a few hundred milliseconds — poll until it stabilizes.
    static func waitForInputFormatToSettle(on inputNode: AVAudioInputNode) async {
        let isBluetoothInputDevice = isDefaultInputDeviceBluetooth()
        let requiredStableDurationSeconds: TimeInterval = isBluetoothInputDevice ? 0.25 : 0.1
        let maxWaitSeconds: TimeInterval = isBluetoothInputDevice ? 2.5 : 0.5
        let pollIntervalNanoseconds: UInt64 = 50_000_000

        var lastObservedSampleRate: Double = 0
        var sampleRateStableSince: Date?
        let waitDeadline = Date().addingTimeInterval(maxWaitSeconds)

        while Date() < waitDeadline {
            let currentFormat = inputNode.outputFormat(forBus: 0)
            let currentSampleRate = currentFormat.sampleRate

            guard currentSampleRate > 0 else {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                continue
            }

            if currentSampleRate == lastObservedSampleRate {
                if sampleRateStableSince == nil {
                    sampleRateStableSince = Date()
                } else if Date().timeIntervalSince(sampleRateStableSince!) >= requiredStableDurationSeconds {
                    return
                }
            } else {
                lastObservedSampleRate = currentSampleRate
                sampleRateStableSince = nil
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    static func copyPCMBuffer(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceBuffer.format,
            frameCapacity: sourceBuffer.frameLength
        ) else {
            return nil
        }

        copiedBuffer.frameLength = sourceBuffer.frameLength

        let sourceBufferList = UnsafeMutableAudioBufferListPointer(sourceBuffer.mutableAudioBufferList)
        let copiedBufferList = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)

        guard sourceBufferList.count == copiedBufferList.count else { return nil }

        for bufferIndex in 0..<sourceBufferList.count {
            guard let sourceData = sourceBufferList[bufferIndex].mData,
                  let copiedData = copiedBufferList[bufferIndex].mData else {
                return nil
            }

            memcpy(
                copiedData,
                sourceData,
                Int(sourceBufferList[bufferIndex].mDataByteSize)
            )
        }

        return copiedBuffer
    }

    static func rootMeanSquareLevel(from audioBuffer: AVAudioPCMBuffer) -> Float? {
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return nil }

        if let floatChannelData = audioBuffer.floatChannelData {
            let channelCount = Int(audioBuffer.format.channelCount)
            var summedSquares: Float = 0

            for channelIndex in 0..<channelCount {
                let channelSamples = floatChannelData[channelIndex]
                for sampleIndex in 0..<frameCount {
                    let sample = channelSamples[sampleIndex]
                    summedSquares += sample * sample
                }
            }

            let sampleCount = Float(frameCount * max(channelCount, 1))
            return sqrt(summedSquares / sampleCount)
        }

        if let int16ChannelData = audioBuffer.int16ChannelData {
            let channelCount = Int(audioBuffer.format.channelCount)
            var summedSquares: Float = 0
            let int16NormalizationFactor: Float = 1.0 / Float(Int16.max)

            for channelIndex in 0..<channelCount {
                let channelSamples = int16ChannelData[channelIndex]
                for sampleIndex in 0..<frameCount {
                    let normalizedSample = Float(channelSamples[sampleIndex]) * int16NormalizationFactor
                    summedSquares += normalizedSample * normalizedSample
                }
            }

            let sampleCount = Float(frameCount * max(channelCount, 1))
            return sqrt(summedSquares / sampleCount)
        }

        return nil
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        ) == noErr else {
            return nil
        }

        return deviceID
    }

    private static func isBluetoothInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var transportType = UInt32(0)
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &transportType) == noErr else {
            return false
        }

        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func inputDeviceName(for deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr else {
            return "unknown input"
        }

        var deviceNameUnmanaged: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &deviceNameUnmanaged) { propertyPointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, propertyPointer)
        }

        guard status == noErr, let deviceNameUnmanaged else {
            return "unknown input"
        }

        return deviceNameUnmanaged.takeRetainedValue() as String
    }

    private static func inputStreamFormat(for deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
        var streamFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &streamFormat) == noErr else {
            return nil
        }

        return streamFormat
    }
}

final class BuddyPCM16AudioConverter {
    private let targetAudioFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?
    private var currentInputFormatDescription: String?
    private var failedConversionCount = 0
    private var hasLoggedConversionFailure = false

    init(targetSampleRate: Double) {
        self.targetAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    func convertToPCM16Data(from audioBuffer: AVAudioPCMBuffer) -> Data? {
        let inputFormatDescription = audioBuffer.format.settings.description

        if currentInputFormatDescription != inputFormatDescription {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: targetAudioFormat)
            currentInputFormatDescription = inputFormatDescription
            failedConversionCount = 0
            hasLoggedConversionFailure = false
        }

        guard let audioConverter else {
            logConversionFailureIfNeeded(
                reason: "no converter for \(audioBuffer.format.sampleRate)Hz \(audioBuffer.format.channelCount)ch"
            )
            return nil
        }

        let sampleRateRatio = targetAudioFormat.sampleRate / audioBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(audioBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            logConversionFailureIfNeeded(reason: "could not allocate output buffer")
            return nil
        }

        var hasProvidedSourceBuffer = false
        var conversionError: NSError?

        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedSourceBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedSourceBuffer = true
            outStatus.pointee = .haveData
            return audioBuffer
        }

        if conversionStatus == .error {
            logConversionFailureIfNeeded(
                reason: conversionError?.localizedDescription ?? "conversion error"
            )
            return nil
        }

        guard let pcmDataPointer = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            logConversionFailureIfNeeded(reason: "converted buffer had no data")
            return nil
        }

        let bytesPerFrame = Int(targetAudioFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        guard byteCount > 0 else {
            logConversionFailureIfNeeded(reason: "converted buffer was empty")
            return nil
        }

        return Data(bytes: pcmDataPointer, count: byteCount)
    }

    private func logConversionFailureIfNeeded(reason: String) {
        failedConversionCount += 1
        guard !hasLoggedConversionFailure else { return }
        hasLoggedConversionFailure = true
        print("🎙️ BuddyPCM16AudioConverter: conversion failed (\(reason)); further failures suppressed")
    }
}

enum BuddyWAVFileBuilder {
    static func buildWAVData(
        fromPCM16MonoAudio pcm16AudioData: Data,
        sampleRate: Int,
        channelCount: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        let byteRate = sampleRate * channelCount * bitsPerSample / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let dataChunkSize = UInt32(pcm16AudioData.count)
        let fileSize = UInt32(36) + dataChunkSize

        var wavData = Data()

        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(littleEndianData(from: fileSize))
        wavData.append("WAVE".data(using: .ascii)!)
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(littleEndianData(from: UInt32(16)))
        wavData.append(littleEndianData(from: UInt16(1)))
        wavData.append(littleEndianData(from: UInt16(channelCount)))
        wavData.append(littleEndianData(from: UInt32(sampleRate)))
        wavData.append(littleEndianData(from: UInt32(byteRate)))
        wavData.append(littleEndianData(from: UInt16(blockAlign)))
        wavData.append(littleEndianData(from: UInt16(bitsPerSample)))
        wavData.append("data".data(using: .ascii)!)
        wavData.append(littleEndianData(from: dataChunkSize))
        wavData.append(pcm16AudioData)

        return wavData
    }

    private static func littleEndianData<T: FixedWidthInteger>(from value: T) -> Data {
        var littleEndianValue = value.littleEndian
        return Data(bytes: &littleEndianValue, count: MemoryLayout<T>.size)
    }
}
