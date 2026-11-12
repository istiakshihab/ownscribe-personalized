import AVFAudio
import AppKit
import CoreAudio
import Foundation

/// Something that produces audio for one track.
protocol CaptureSource: AnyObject {
    func start() throws
    func stop()
    /// Whether audio should be arriving right now, so a lack of it means the source died.
    /// A mic or a test tone delivers buffers continuously, silence included. A process tap does
    /// not: its device only runs while a tapped process is playing, so a tap of a silent app
    /// legitimately delivers nothing.
    func isAudioDue(_ processes: [AudioProcessInfo]) -> Bool
    /// `debug_fail_source` (tests only): stop delivering audio without telling anyone, the way a
    /// dead device or tap would.
    func simulateFailure()
}

extension CaptureSource {
    func isAudioDue(_ processes: [AudioProcessInfo]) -> Bool { true }
    func simulateFailure() {}
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

    func simulateFailure() { stop() }

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
    /// The process has audio input running (a call or recorder has the mic open).
    let isRecording: Bool
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
                         isPlaying: (audioProperty(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0,
                         isRecording: (audioProperty(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0)
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
/// Buffers arrive at the aggregate's nominal rate, which is the output device's: 44.1 kHz for most
/// Bluetooth headphones, 16 kHz while a call uses a headset mic. kAudioTapPropertyFormat (and the
/// aggregate's input-stream format) still say 48 kHz, so the rate is taken from the device, followed
/// when it changes, and checked against the device's own sample clock.
///
/// Core Audio refuses to change a running tap's process list (kAudioTapPropertyDescription returns
/// '!hog'), so a change builds a replacement tap first. Each tap instance tags its buffers with a
/// generation; the replacement takes over the track on its first buffer and only then are the old
/// tap's buffers dropped, so the track sees neither a gap nor doubled audio.
final class ProcessTapSource: CaptureSource {
    enum Mode { case include, exclude }

    /// The device's sample clock against the host clock over the IO thread's current stretch of
    /// back-to-back callbacks (a pause starts a new one, so idle time never counts).
    struct Clock {
        var startSample = 0.0
        var startHost: UInt64 = 0
        var lastSample = 0.0
        var lastHost: UInt64 = 0
    }

    private final class Instance {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        /// The tap's own description: channels and sample type. Its sample rate is not to be trusted.
        var tapFormat = AudioStreamBasicDescription()
        /// What buffers are read as: the tap's layout at the rate the device really runs at.
        let ioFormat = Locked<AVAudioFormat?>(nil)
        let clock = Locked(Clock())
        var rateListener: AudioObjectPropertyListenerBlock?
        /// A rate change the listener adopted, for the next checkRate() to report. Main queue.
        var rateNote: String?
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
    /// `--debug-tap-rate` (tests only): start every tap at this wrong rate, for checkRate() to correct.
    nonisolated(unsafe) static var debugInitialRate: Double?
    static let standardRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000,
                                          88200, 96000, 176_400, 192_000]

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

    /// The default output device changed: rebuild the aggregate around the new clock. A failure
    /// (no output device left, say) leaves the tap dead; the caller reports it as lost.
    func restartAggregate() throws {
        guard let instance = current else { return }
        stopAggregate(instance)
        try startAggregate(instance)
    }

    func stop() {
        for instance in retiring + [current].compactMap({ $0 }) { destroy(instance) }
        retiring = []
        current = nil
    }

    /// True while a process this tap covers is playing: then its device runs and buffers must
    /// arrive. Judged by bundle-ID prefix rather than the running instance's process list, so it
    /// still answers after a failed rebuild left no instance. Our own process is never counted:
    /// running a tap device can make it look like it is playing.
    func isAudioDue(_ processes: [AudioProcessInfo]) -> Bool {
        let own = getpid()
        let matched = Set(processObjects(matching: prefixes, in: processes))
        return processes.contains { p in
            guard p.isPlaying, p.pid != own else { return false }
            return mode == .include ? matched.contains(p.object) : !matched.contains(p.object)
        }
    }

    /// Once a second from the session's watchdog: if the device's sample clock says it runs at a
    /// different rate than buffers are read at, switch to the clock's rate. Returns what changed, if
    /// anything (including a change the rate listener already adopted).
    func checkRate() -> String? {
        guard let instance = current else { return nil }
        if let note = instance.rateNote {
            instance.rateNote = nil
            return note
        }
        let c = instance.clock.get()
        guard c.startHost != 0, c.lastHost > c.startHost else { return nil }
        let span = HostTime.seconds(Int64(c.lastHost - c.startHost))
        guard span >= 1 else { return nil }
        instance.clock.update { $0.startSample = $0.lastSample; $0.startHost = $0.lastHost }  // next window
        let measured = (c.lastSample - c.startSample) / span
        guard let rate = Self.standardRates.first(where: { abs($0 - measured) / $0 < 0.02 }),
              let reading = instance.ioFormat.get()?.sampleRate, abs(rate - reading) / reading > 0.005 else { return nil }
        setRate(rate, of: instance)
        return "audio arrived at \(Self.hz(rate)) but was read as \(Self.hz(reading)); corrected"
    }

    private static func hz(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000)
    }

    private func setRate(_ rate: Double, of instance: Instance) {
        var asbd = instance.tapFormat
        asbd.mSampleRate = rate
        instance.ioFormat.set(AVAudioFormat(streamDescription: &asbd))
    }

    /// The rate the aggregate (so the output device) runs at; the tap's own rate if it can't say.
    private func deviceRate(_ instance: Instance) -> Double {
        let nominal = audioProperty(instance.aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0
        return nominal > 0 ? nominal : instance.tapFormat.mSampleRate
    }

    /// Stop the tap's device in place, as if it had died; the instance is left for stop().
    func simulateFailure() {
        for instance in retiring + [current].compactMap({ $0 }) {
            if let procID = instance.procID { AudioDeviceStop(instance.aggregateID, procID) }
        }
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
        guard err == noErr, AVAudioFormat(streamDescription: &asbd) != nil else {
            AudioHardwareDestroyProcessTap(instance.tapID)
            throw TapError(code: "tap_failed", description: "Could not read the tap's audio format (\(err))")
        }
        instance.tapFormat = asbd
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
        setRate(Self.debugInitialRate ?? deviceRate(instance), of: instance)
        instance.clock.set(Clock())
        // The device's rate changes under a running tap: a headset switching to hands-free for a call.
        let listener: AudioObjectPropertyListenerBlock = { [weak self, weak instance] _, _ in
            guard let self, let instance, instance.aggregateID != kAudioObjectUnknown else { return }
            let rate = deviceRate(instance)
            guard let reading = instance.ioFormat.get()?.sampleRate, rate != reading else { return }
            setRate(rate, of: instance)
            instance.rateNote = "the output device switched from \(Self.hz(reading)) to \(Self.hz(rate))"
        }
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(instance.aggregateID, &rateAddr, .main, listener) == noErr {
            instance.rateListener = listener
        }
        let writer = self.writer
        let live = liveGeneration
        let generation = instance.generation
        let ioFormat = instance.ioFormat
        let clock = instance.clock
        let pause = HostTime.ticks(seconds: 0.2)
        var claimed = false  // touched only by this instance's IO thread
        err = AudioDeviceCreateIOProcIDWithBlock(&instance.procID, instance.aggregateID, nil) { _, input, inputTime, _, _ in
            // Real-time thread: claim the track on the first buffer, drop buffers once superseded.
            if !claimed {
                claimed = true
                live.update { $0 = max($0, generation) }
            }
            let time = inputTime.pointee
            if time.mFlags.contains(.sampleTimeValid), time.mFlags.contains(.hostTimeValid) {
                clock.update { c in
                    if c.startHost == 0 || time.mSampleTime < c.lastSample || time.mHostTime > c.lastHost &+ pause {
                        c.startSample = time.mSampleTime
                        c.startHost = time.mHostTime
                    }
                    c.lastSample = time.mSampleTime
                    c.lastHost = time.mHostTime
                }
            }
            guard live.get() == generation, let format = ioFormat.get() else { return }
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
        if let listener = instance.rateListener {
            var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(instance.aggregateID, &rateAddr, .main, listener)
            instance.rateListener = nil
        }
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
