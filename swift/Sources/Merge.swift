import AVFAudio
import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

// MARK: - Merge audio files with timestamp alignment

/// Frame count of an audio file, or 0 when it is missing or unreadable.
func audioFrameCount(atPath path: String) -> AVAudioFramePosition {
    guard FileManager.default.fileExists(atPath: path),
          let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return 0 }
    return file.length
}

func mergeAudioFiles(systemPath: String, micPath: String,
                     systemStartHostTime: UInt64, micStartHostTime: UInt64,
                     sessionStartHostTime: UInt64, outputPath: String) throws {
    let fm = FileManager.default
    // Judge "empty" by frame count, not file size. AVAudioFile pads the WAV header to
    // 4096 bytes, so the old "<= 44 bytes" check never saw an empty track, and an empty
    // track also has no start time, which wrecked the offset below.
    let systemFrames = audioFrameCount(atPath: systemPath)
    let micFrames = audioFrameCount(atPath: micPath)

    // Both empty — clean up temp files and let the caller handle it
    if systemFrames == 0 && micFrames == 0 {
        try? fm.removeItem(atPath: systemPath)
        try? fm.removeItem(atPath: micPath)
        fputs("No audio was captured (system and mic tracks are both empty).\n", stderr)
        return
    }

    // Mic empty but system has data — just rename system file
    if micFrames == 0 {
        try? fm.removeItem(atPath: micPath)
        try fm.moveItem(atPath: systemPath, toPath: outputPath)
        fputs("Merged audio saved to \(outputPath) (system only, no mic audio)\n", stderr)
        return
    }

    // Open files — system is optional (may be empty when only mic captured audio)
    let systemFile: AVAudioFile? = systemFrames > 0
        ? try AVAudioFile(forReading: URL(fileURLWithPath: systemPath)) : nil
    let micFile = try AVAudioFile(forReading: URL(fileURLWithPath: micPath))

    let outputSampleRate: Double = kSystemAudioSampleRate
    let outputChannels: AVAudioChannelCount = 1

    // Align the tracks by when each delivered its first buffer. A start time of 0 means
    // the track never delivered one, and a time before this session began is bogus.
    // Either used to make the offset the Mac's whole awake time: tens of GB of leading
    // silence that took longer to write than the wrapper waits, so the merge was killed
    // half-way. With both start times inside the session, the offset can't exceed it.
    func plausible(_ hostTime: UInt64) -> Bool { hostTime != 0 && hostTime >= sessionStartHostTime }
    var offsetFrames: Int64 = 0
    if systemFile != nil {
        if plausible(systemStartHostTime) && plausible(micStartHostTime) {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let ticksToNanos = Double(timebase.numer) / Double(timebase.denom)
            let offsetTicks = Double(micStartHostTime) - Double(systemStartHostTime)
            let offsetSeconds = offsetTicks * ticksToNanos / 1_000_000_000.0
            offsetFrames = Int64(offsetSeconds * outputSampleRate)
        } else {
            fputs("Warning: a track has no start time; aligning system and mic audio at the start.\n", stderr)
        }
    }
    let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: outputSampleRate,
                                      channels: outputChannels,
                                      interleaved: true)!
    let outputFile = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath),
                                      settings: outputFormat.settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: true)

    // Mic converter using callback API (handles sample rate + channel conversion)
    let micFormat = micFile.processingFormat
    let micConverter = AVAudioConverter(from: micFormat, to: outputFormat)!
    let micRate = micFormat.sampleRate

    let chunkSize: AVAudioFrameCount = 8192
    let systemLength = systemFile.map { Int64($0.length) } ?? 0
    // Mic file length converted to output-rate frames
    let micLengthOutput = Int64(Double(micFile.length) * outputSampleRate / micRate)

    // Calculate total output length accounting for offset
    let systemEndFrame = (offsetFrames >= 0) ? systemLength : systemLength + (-offsetFrames)
    let micEndFrame = (offsetFrames >= 0) ? micLengthOutput + offsetFrames : micLengthOutput
    let totalOutputFrames = max(systemEndFrame, micEndFrame)

    // Mic region in output timeline
    let micOutputStart: Int64 = (offsetFrames >= 0) ? offsetFrames : 0
    let micOutputEnd: Int64 = micOutputStart + micLengthOutput
    var micDone = false

    var outputFrame: Int64 = 0

    while outputFrame < totalOutputFrames {
        let framesToProcess = AVAudioFrameCount(min(Int64(chunkSize), totalOutputFrames - outputFrame))
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: framesToProcess) else { break }
        outBuffer.frameLength = framesToProcess

        // Zero the output buffer
        let outPtr = outBuffer.floatChannelData![0]
        for i in 0..<Int(framesToProcess * outputChannels) {
            outPtr[i] = 0
        }

        // Read and mix system audio (manual interleave from non-interleaved processingFormat)
        if let systemFile = systemFile {
            let sysFrameInFile = (offsetFrames >= 0) ? outputFrame : outputFrame + offsetFrames
            let writeOffset = max(0, -sysFrameInFile)
            let readStart = max(0, sysFrameInFile)
            if readStart < systemLength && writeOffset < Int64(framesToProcess) {
                let maxRead = Int64(framesToProcess) - writeOffset
                let sysReadCount = AVAudioFrameCount(min(maxRead, systemLength - readStart))
                if sysReadCount > 0 {
                    systemFile.framePosition = AVAudioFramePosition(readStart)
                    if let sysBuf = AVAudioPCMBuffer(pcmFormat: systemFile.processingFormat, frameCapacity: sysReadCount) {
                        try systemFile.read(into: sysBuf, frameCount: sysReadCount)
                        let sysData = sysBuf.floatChannelData!
                        let sysCh = Int(sysBuf.format.channelCount)
                        let wo = Int(writeOffset)
                        for i in 0..<Int(sysBuf.frameLength) {
                            var mix: Float = 0
                            for ch in 0..<sysCh { mix += sysData[ch][i] }
                            outPtr[wo + i] += mix / Float(sysCh)
                        }
                    }
                }
            }
        }

        // Read and mix mic audio using callback-based converter
        let chunkEnd = outputFrame + Int64(framesToProcess)
        if !micDone && chunkEnd > micOutputStart && outputFrame < micOutputEnd {
            let overlapStart = max(outputFrame, micOutputStart)
            let overlapEnd = min(chunkEnd, micOutputEnd)
            let micFramesNeeded = AVAudioFrameCount(overlapEnd - overlapStart)

            if micFramesNeeded > 0 {
                guard let micOutBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: micFramesNeeded) else { break }

                var convError: NSError?
                let status = micConverter.convert(to: micOutBuf, error: &convError) { inNumberOfPackets, outStatus in
                    let remaining = AVAudioFrameCount(micFile.length - micFile.framePosition)
                    if remaining == 0 {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    let toRead = min(inNumberOfPackets, remaining)
                    guard let buf = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: toRead) else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try micFile.read(into: buf, frameCount: toRead)
                        outStatus.pointee = .haveData
                        return buf
                    } catch {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                }

                if status == .endOfStream {
                    micDone = true
                }

                // Mix converted mic audio into output at correct position
                if micOutBuf.frameLength > 0 {
                    let offsetInChunk = Int(overlapStart - outputFrame)
                    let srcPtr = micOutBuf.floatChannelData![0]
                    let count = Int(micOutBuf.frameLength * outputChannels)
                    for i in 0..<count {
                        outPtr[offsetInChunk * Int(outputChannels) + i] += srcPtr[i]
                    }
                }
            }
        }

        // Clamp to [-1, 1]
        let totalSamples = Int(framesToProcess * outputChannels)
        for i in 0..<totalSamples {
            outPtr[i] = max(-1.0, min(1.0, outPtr[i]))
        }

        try outputFile.write(from: outBuffer)
        outputFrame += Int64(framesToProcess)
    }

    // Delete temp files
    try? FileManager.default.removeItem(atPath: systemPath)
    try? FileManager.default.removeItem(atPath: micPath)

    let detail = systemFile == nil ? " (mic only, no system audio)" : ""
    fputs("Merged audio saved to \(outputPath)\(detail)\n", stderr)
}
