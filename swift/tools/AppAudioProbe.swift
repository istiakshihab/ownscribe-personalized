// Spike: which API attributes per-app audio correctly — ScreenCaptureKit app filters or Core Audio
// process taps? See docs/per-app-audio.md. Not part of the shipped helper.
//
// Build:  swiftc -O -o bin/app-audio-probe swift/tools/AppAudioProbe.swift
// Run:    bin/app-audio-probe list
//         bin/app-audio-probe tap  <bundle-prefix | pid:N> [seconds]   (Core Audio process taps)
//         bin/app-audio-probe sck  <bundle-id> [seconds]               (ScreenCaptureKit app filter)
// Both capture modes run two meters at once: the app alone, and everything except the app.

import AVFAudio
import AppKit
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

struct ProbeError: Error, CustomStringConvertible { let description: String }

/// Peak/RMS accumulator shared between an audio callback thread and the reporting loop.
final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var count = 0
    private(set) var buffers = 0

    func add(_ samples: UnsafeBufferPointer<Float>) {
        var p: Float = 0
        var s: Double = 0
        for v in samples {
            p = max(p, abs(v))
            s += Double(v) * Double(v)
        }
        lock.lock()
        peak = max(peak, p)
        sumSquares += s
        count += samples.count
        buffers += 1
        lock.unlock()
    }

    /// Returns (peak dBFS, rms dBFS, buffers) since the last call and resets.
    func take() -> (Double?, Double?, Int) {
        lock.lock()
        defer { peak = 0; sumSquares = 0; count = 0; buffers = 0; lock.unlock() }
        let db = { (x: Double) -> Double? in x > 0 ? 20 * log10(x) : nil }
        return (db(Double(peak)), count > 0 ? db((sumSquares / Double(count)).squareRoot()) : nil, buffers)
    }
}

// MARK: - Core Audio helpers

func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
    return ref.takeRetainedValue() as String
}

struct AudioProcess { let object: AudioObjectID; let pid: pid_t; let bundleID: String; let playing: Bool }

func audioProcesses() -> [AudioProcess] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map { id in
        AudioProcess(object: id,
                     pid: getProperty(id, kAudioProcessPropertyPID, pid_t(0)) ?? 0,
                     bundleID: getString(id, kAudioProcessPropertyBundleID) ?? "",
                     playing: (getProperty(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0)
    }
}

func defaultOutputUID() throws -> String {
    guard let device = getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                                   AudioDeviceID(0)),
          let uid = getString(device, kAudioDevicePropertyDeviceUID) else {
        throw ProbeError(description: "no default output device")
    }
    return uid
}

/// A process tap (include or exclude) wrapped in a private aggregate device, metering its audio.
final class TapMeter {
    let meter = Meter()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(_ description: CATapDescription) throws {
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr else {
            throw ProbeError(description: "AudioHardwareCreateProcessTap failed (\(err)); is System Audio Recording allowed?")
        }
        let outputUID = try defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ownscribe-probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr else { throw ProbeError(description: "AudioHardwareCreateAggregateDevice failed (\(err))") }
        let meter = self.meter
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                meter.add(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: n))
            }
        }
        guard err == noErr else { throw ProbeError(description: "AudioDeviceCreateIOProcIDWithBlock failed (\(err))") }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { throw ProbeError(description: "AudioDeviceStart failed (\(err))") }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

// MARK: - ScreenCaptureKit

final class SCKMeter: NSObject, SCStreamOutput {
    let meter = Meter()
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "probe.sck")

    func start(_ filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 24000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let block = sampleBuffer.dataBuffer else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return }
        pointer.withMemoryRebound(to: Float.self, capacity: length / 4) {
            meter.add(UnsafeBufferPointer(start: $0, count: length / 4))
        }
    }

    func stop() async { try? await stream?.stopCapture() }
}

// MARK: - Reporting

func fmt(_ db: Double?) -> String { db.map { String(format: "%6.1f", $0) } ?? "  −∞  " }

func report(_ meters: [(String, Meter)], seconds: Int) {
    print("time  " + meters.map { "\($0.0.padding(toLength: 22, withPad: " ", startingAt: 0))" }.joined())
    print("      " + meters.map { _ in "peak    rms  bufs      " }.joined())
    for second in 1...seconds {
        Thread.sleep(forTimeInterval: 1)
        let cols = meters.map { _, meter -> String in
            let (peak, rms, buffers) = meter.take()
            return "\(fmt(peak)) \(fmt(rms)) \(String(format: "%4d", buffers))     "
        }
        print(String(format: "%3ds  ", second) + cols.joined())
    }
}

// MARK: - Commands

func listCommand() async {
    print("Core Audio process objects (what taps see):")
    for p in audioProcesses().sorted(by: { $0.bundleID < $1.bundleID }) {
        print("  pid \(String(p.pid).padding(toLength: 7, withPad: " ", startingAt: 0)) \(p.playing ? "▶ playing" : "         ") \(p.bundleID.isEmpty ? "(no bundle id)" : p.bundleID)")
    }
    print("\nScreenCaptureKit applications (what app filters see):")
    if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) {
        for app in content.applications.sorted(by: { $0.bundleIdentifier < $1.bundleIdentifier }) where !app.bundleIdentifier.isEmpty {
            print("  pid \(String(app.processID).padding(toLength: 7, withPad: " ", startingAt: 0)) \(app.bundleIdentifier)  \(app.applicationName)")
        }
    } else {
        print("  (unavailable: Screen Recording permission missing?)")
    }
}

func tapCommand(_ target: String, seconds: Int) throws {
    let processes = audioProcesses()
    let matched: [AudioProcess]
    if target.hasPrefix("pid:"), let pid = pid_t(target.dropFirst(4)) {
        matched = processes.filter { $0.pid == pid }
    } else {
        matched = processes.filter { $0.bundleID.hasPrefix(target) }
    }
    guard !matched.isEmpty else { throw ProbeError(description: "no Core Audio process matches \(target); run `list`") }
    print("Tapping \(matched.count) process object(s): " + matched.map { "\($0.bundleID.isEmpty ? "pid \($0.pid)" : $0.bundleID)" }.joined(separator: ", "))
    let objects = matched.map(\.object)
    let app = try TapMeter(CATapDescription(monoMixdownOfProcesses: objects))
    let others = try TapMeter(CATapDescription(monoGlobalTapButExcludeProcesses: objects))
    report([("app (include tap)", app.meter), ("everything else", others.meter)], seconds: seconds)
    app.stop()
    others.stop()
}

func sckCommand(_ bundleID: String, seconds: Int) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    guard let display = content.displays.first else { throw ProbeError(description: "no display") }
    guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
        throw ProbeError(description: "\(bundleID) is not in SCShareableContent.applications; run `list`")
    }
    let appMeter = SCKMeter()
    let othersMeter = SCKMeter()
    try await appMeter.start(SCContentFilter(display: display, including: [app], exceptingWindows: []))
    try await othersMeter.start(SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: []))
    print("ScreenCaptureKit: \(app.applicationName) (\(bundleID)), pid \(app.processID)")
    report([("app (include filter)", appMeter.meter), ("everything else", othersMeter.meter)], seconds: seconds)
    await appMeter.stop()
    await othersMeter.stop()
}

let args = CommandLine.arguments
let seconds = args.count > 3 ? Int(args[3]) ?? 8 : 8
let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task.detached {
    do {
        switch args.count > 1 ? args[1] : "" {
        case "list": await listCommand()
        case "tap" where args.count > 2: try tapCommand(args[2], seconds: seconds)
        case "sck" where args.count > 2: try await sckCommand(args[2], seconds: seconds)
        default:
            print("usage: app-audio-probe list | tap <bundle-prefix|pid:N> [seconds] | sck <bundle-id> [seconds]")
            exitCode = 2
        }
    } catch {
        print("error: \(error)")
        exitCode = 1
    }
    semaphore.signal()
}
_ = NSApplication.shared  // ScreenCaptureKit needs a connection to the window server
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
exit(exitCode)
