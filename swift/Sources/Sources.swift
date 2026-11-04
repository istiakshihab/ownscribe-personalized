import AVFAudio
import AppKit
import CoreAudio
import Foundation

/// Something that produces audio for one track.
protocol CaptureSource: AnyObject {
    func start() throws
    func stop()
}

// MARK: - Test tone (no permissions needed)

/// A synthetic source: tone bursts at a fixed pitch, timestamped on the host clock exactly like a
/// real device. Used by tests and by `--source test-tone` to exercise the protocol and the merge.
final class TestToneSource: CaptureSource {
    private let writer: TrackWriter
    private let frequency: Double
    private let level: Float
    private let queue = DispatchQueue(label: "com.ownscribe.testtone")
    private var timer: DispatchSourceTimer?
    private var startHostTime: UInt64 = 0
    private var generated: Int64 = 0
    private static let chunkFrames = 480  // 20 ms at 24 kHz

    init(writer: TrackWriter, frequency: Double, level: Float = 0.25) {
        self.writer = writer
        self.frequency = frequency
        self.level = level
    }

    func start() throws {
        startHostTime = mach_absolute_time()
        generated = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        // Generate whatever wall-clock time has passed, so timestamps never drift.
        let elapsed = HostTime.elapsed(from: startHostTime, to: mach_absolute_time())
        let due = Int64(elapsed * kTrackSampleRate)
        while generated + Int64(Self.chunkFrames) <= due {
            let format = AVAudioFormat(standardFormatWithSampleRate: kTrackSampleRate, channels: 1)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunkFrames)) else { return }
            buffer.frameLength = AVAudioFrameCount(Self.chunkFrames)
            let out = buffer.floatChannelData![0]
            for i in 0..<Self.chunkFrames {
                let n = Double(generated + Int64(i))
                let t = n / kTrackSampleRate
                let burstOn = t.truncatingRemainder(dividingBy: 2.0) < 1.4  // 1.4 s on, 0.6 s off
                out[i] = burstOn ? level * Float(sin(2 * .pi * frequency * t)) : 0
            }
            let hostTime = startHostTime + HostTime.ticks(seconds: Double(generated) / kTrackSampleRate)
            writer.append(buffer, hostTime: hostTime)
            generated += Int64(Self.chunkFrames)
        }
    }
}

// MARK: - Core Audio process taps

struct AudioProcessInfo {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isPlaying: Bool
}

func audioProcessObjects() -> [AudioProcessInfo] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map { id in
        AudioProcessInfo(object: id,
                         pid: audioProperty(id, kAudioProcessPropertyPID, pid_t(0)) ?? 0,
                         bundleID: audioStringProperty(id, kAudioProcessPropertyBundleID) ?? "",
                         isPlaying: (audioProperty(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0)
    }
}

func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func audioStringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
    return ref.takeRetainedValue() as String
}

/// Process objects belonging to an app: its bundle ID or any helper whose ID extends it
/// (`com.microsoft.teams2` also matches `com.microsoft.teams2.helper`).
func processObjects(matching prefixes: [String], in processes: [AudioProcessInfo]) -> [AudioObjectID] {
    processes.filter { p in
        !p.bundleID.isEmpty && prefixes.contains { p.bundleID == $0 || p.bundleID.hasPrefix($0 + ".") }
    }.map(\.object)
}

struct TapError: Error, CustomStringConvertible {
    let code: String
    let description: String
}

/// One Core Audio process tap: either the listed apps only (`include`) or everything except them
/// (`exclude`, used for "Other apps"). A tap lives in a private aggregate device whose clock is
/// the default output device; buffers are copied off the real-time thread and handed to the writer.
///
/// Core Audio refuses to change a running tap's process list (kAudioTapPropertyDescription returns
/// '!hog'), so a change builds a replacement tap first. Each tap instance tags its buffers with a
/// generation; the replacement takes over the track on its first buffer and only then are the old
/// tap's buffers dropped, so the track sees neither a gap nor doubled audio.
final class ProcessTapSource: CaptureSource {
    enum Mode { case include, exclude }

    private final class Instance {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var format: AVAudioFormat?
        let uuid = UUID()
        let generation: Int
        let objects: [AudioObjectID]
        init(generation: Int, objects: [AudioObjectID]) {
            self.generation = generation
            self.objects = objects
        }
    }

    private let mode: Mode
    private let writer: TrackWriter
    private(set) var prefixes: [String]
    private var current: Instance?
    private var retiring: [Instance] = []
    private var nextGeneration = 0
    /// Generation whose buffers reach the writer; the newest instance claims it on its first buffer.
    private let liveGeneration = Locked(0)

    init(mode: Mode, prefixes: [String], writer: TrackWriter) {
        self.mode = mode
        self.prefixes = prefixes
        self.writer = writer
    }

    func start() throws {
        let objects = matchedObjects()
        let instance = try makeInstance(objects)
        liveGeneration.set(instance.generation)
        current = instance
    }

    /// Re-point the tap at the apps' current processes (an app opened a helper, or one quit), or
    /// change which apps it covers. Does nothing when the matching processes are unchanged.
    func update(prefixes newPrefixes: [String]? = nil) {
        if let newPrefixes { prefixes = newPrefixes }
        guard let old = current else { return }
        let objects = matchedObjects()
        guard objects != old.objects else { return }
        do {
            current = try makeInstance(objects)
            retiring.append(old)
            // Tear the old tap down once the new one has had time to deliver its first buffers.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.retire(old) }
        } catch {
            fputs("Tap update failed, keeping the previous one: \(error)\n", stderr)
        }
    }

    /// The default output device changed: rebuild the aggregate around the new clock.
    func restartAggregate() {
        guard let instance = current else { return }
        stopAggregate(instance)
        try? startAggregate(instance)
    }

    func stop() {
        for instance in retiring + [current].compactMap({ $0 }) { destroy(instance) }
        retiring = []
        current = nil
    }

    // MARK: - Instances

    private func matchedObjects() -> [AudioObjectID] {
        processObjects(matching: prefixes, in: audioProcessObjects()).sorted()
    }

    private func makeInstance(_ objects: [AudioObjectID]) throws -> Instance {
        nextGeneration += 1
        let instance = Instance(generation: nextGeneration, objects: objects)
        let description = mode == .include
            ? CATapDescription(monoMixdownOfProcesses: objects)
            : CATapDescription(monoGlobalTapButExcludeProcesses: objects)
        description.uuid = instance.uuid
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "ownscribe \(writer.id)"
        var err = AudioHardwareCreateProcessTap(description, &instance.tapID)
        guard err == noErr else {
            throw TapError(code: "system_audio_permission_denied",
                           description: "Could not create an audio tap (\(err)); allow System Audio Recording for this app")
        }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(instance.tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyProcessTap(instance.tapID)
            throw TapError(code: "tap_failed", description: "Could not read the tap's audio format (\(err))")
        }
        instance.format = format
        do {
            try startAggregate(instance)
        } catch {
            destroy(instance)
            throw error
        }
        return instance
    }

    private func retire(_ instance: Instance) {
        guard let index = retiring.firstIndex(where: { $0 === instance }) else { return }
        retiring.remove(at: index)
        destroy(instance)
    }

    private func destroy(_ instance: Instance) {
        stopAggregate(instance)
        if instance.tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(instance.tapID)
            instance.tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func startAggregate(_ instance: Instance) throws {
        guard let output = audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                                         AudioDeviceID(0)),
              let outputUID = audioStringProperty(output, kAudioDevicePropertyDeviceUID) else {
            throw TapError(code: "no_output_device", description: "No default output device to clock the tap")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ownscribe \(writer.id)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: instance.uuid.uuidString]],
        ]
        var err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &instance.aggregateID)
        guard err == noErr else { throw TapError(code: "tap_failed", description: "Could not create the tap device (\(err))") }
        guard let format = instance.format else { return }
        let writer = self.writer
        let live = liveGeneration
        let generation = instance.generation
        var claimed = false  // touched only by this instance's IO thread
        err = AudioDeviceCreateIOProcIDWithBlock(&instance.procID, instance.aggregateID, nil) { _, input, inputTime, _, _ in
            // Real-time thread: claim the track on the first buffer, drop buffers once superseded.
            if !claimed {
                claimed = true
                live.update { $0 = max($0, generation) }
            }
            guard live.get() == generation else { return }
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = source.first, first.mDataByteSize > 0 else { return }
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            let frames = AVAudioFrameCount(Int(first.mDataByteSize) / max(bytesPerFrame, 1))
            guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            copy.frameLength = frames
            for (src, dst) in zip(source, UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)) {
                if let s = src.mData, let d = dst.mData { memcpy(d, s, Int(min(src.mDataByteSize, dst.mDataByteSize))) }
            }
            let hostTime = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : mach_absolute_time()
            writer.append(copy, hostTime: hostTime)
        }
        guard err == noErr else { throw TapError(code: "tap_failed", description: "Could not start the tap (\(err))") }
        err = AudioDeviceStart(instance.aggregateID, instance.procID)
        guard err == noErr else { throw TapError(code: "tap_failed", description: "Could not start the tap (\(err))") }
    }

    private func stopAggregate(_ instance: Instance) {
        if let procID = instance.procID {
            AudioDeviceStop(instance.aggregateID, procID)
            AudioDeviceDestroyIOProcID(instance.aggregateID, procID)
            instance.procID = nil
        }
        if instance.aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(instance.aggregateID)
            instance.aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

// MARK: - Apps

struct RunningAppInfo {
    let bundleID: String
    let name: String
    let pid: pid_t
}

/// Regular (Dock) apps that are running, for the "Add source" list.
func runningApps() -> [RunningAppInfo] {
    NSWorkspace.shared.runningApplications.compactMap { app in
        guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else { return nil }
        return RunningAppInfo(bundleID: bundleID, name: app.localizedName ?? bundleID, pid: app.processIdentifier)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
