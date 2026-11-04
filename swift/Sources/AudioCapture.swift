import ScreenCaptureKit
import CoreMedia
import AVFAudio
import AVFoundation
import CoreGraphics
import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import IOKit.pwr_mgt

// MARK: - Constants

/// Minimum peak amplitude to consider microphone audio "loud" (silence timeout).
private let kMicLoudThreshold: Float = 1e-2
/// Minimum peak amplitude to consider system audio "loud" (silence timeout).
private let kSystemLoudThreshold: Float = 1e-4
/// System audio capture and merge output sample rate (mono float32).
private let kSystemAudioSampleRate: Double = 24000
/// Seconds of nothing but digital silence before the mic is reported as dead.
private let kMicSilentAfter: Double = 5

/// Compute peak amplitude across all channels of float audio data.
func computePeakLevel(in channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
               channels: Int, frames: Int) -> Float {
    var peak: Float = 0
    for ch in 0..<channels {
        for i in 0..<frames {
            let v = abs(channelData[ch][i])
            if v > peak { peak = v }
        }
    }
    return peak
}

// MARK: - Core Audio device helpers

private let kSystemObject = AudioObjectID(kAudioObjectSystemObject)

/// Every audio device Core Audio knows about.
func audioDeviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(kSystemObject, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(kSystemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cfName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfName) == noErr,
          let cfName else { return "(unknown)" }
    return cfName.takeRetainedValue() as String
}

/// Number of input channels across all of a device's input streams. The stream
/// configuration is a variable-length AudioBufferList, so allocate the size Core Audio
/// reports: the old single-AudioBufferList allocation overflowed the heap for devices
/// with more than one input stream.
func inputChannelCount(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, list) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
}

func transportType(_ id: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var type: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type) == noErr ? type : 0
}

func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let type = transportType(id)
    return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
}

func transportLabel(_ id: AudioDeviceID) -> String {
    switch transportType(id) {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "aggregate"
    case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
    case kAudioDeviceTransportTypeContinuityCaptureWired,
         kAudioDeviceTransportTypeContinuityCaptureWireless: return "iPhone"
    default: return "other"
    }
}

func defaultInputDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(kSystemObject, &addr, 0, nil, &size, &id) == noErr,
          id != kAudioObjectUnknown else { return nil }
    return id
}

/// The Mac's own microphone, if it has one.
func builtInInputDevice() -> AudioDeviceID? {
    audioDeviceIDs().first {
        transportType($0) == kAudioDeviceTransportTypeBuiltIn && inputChannelCount($0) > 0
    }
}

/// Find an input device by name: an exact (case-insensitive) match first, then the
/// first name containing it, so a short name can't grab whichever device enumerates first.
func findInputDevice(named name: String) throws -> AudioDeviceID {
    let wanted = name.lowercased()
    let inputs = audioDeviceIDs().filter { inputChannelCount($0) > 0 }
    if let exact = inputs.first(where: { deviceName($0).lowercased() == wanted }) {
        return exact
    }
    if let partial = inputs.first(where: { deviceName($0).lowercased().contains(wanted) }) {
        return partial
    }
    throw MicCapture.MicError.deviceNotFound(name)
}

func deviceUID(_ id: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cfUID: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfUID) == noErr,
          let cfUID else { return nil }
    return cfUID.takeRetainedValue() as String
}

func nominalSampleRate(_ id: AudioDeviceID) -> Double {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : 0
}

// MARK: - Mic Capture via AVCaptureSession

/// Records one microphone to a WAV file.
///
/// Built on AVCaptureSession rather than AVAudioEngine. AVAudioEngine's input shares one
/// I/O unit with its output and runs both through a private aggregate of the default
/// devices. Pointing that unit at another mic was undone by the engine about 0.1 s after
/// it started (back to the default, Bluetooth headset included, with the tap left
/// silent), or failed with -10868, so neither --mic-device nor skipping a headset could
/// work. A capture session opens exactly the device it is given, never touches output
/// (so a headset stays out of hands-free mode unless it is the chosen mic), and converts
/// whatever the device delivers to one fixed format. A device or format change never
/// reaches the file.
class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Which input device to record.
    enum Selection {
        /// --mic-device: always this device (looked up by name again when devices change).
        case named(String)
        /// Follow macOS's default input wherever it moves.
        case systemDefault
        /// The default input, unless it is a Bluetooth headset and the Mac has a built-in
        /// mic. macOS makes a headset the default input the moment it connects, and opening
        /// its mic forces hands-free mode: 16 kHz, noisy, and the headphones' playback drops
        /// to the same quality. That was the usual "wrong mic".
        case avoidBluetooth
    }

    /// The mic file's format, whatever the device: the capture output converts to it.
    private static let recordSampleRate: Double = 48000

    private let selection: Selection
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "com.ownscribe.micCapture", qos: .userInitiated)

    // Written on sampleQueue; read on .main only after stop() has drained the queue.
    private var audioFile: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private(set) var startHostTime: UInt64 = 0
    // Set when a write/convert failure has been logged; reset on the next successful write
    // so a persistent failure logs once instead of once per buffer. sampleQueue only.
    private var loggedWriteError = false

    // .main only: the device being recorded and what has been reported about it.
    private var currentInput: AVCaptureDeviceInput?
    private var currentDeviceID: AudioDeviceID?
    /// The current device is the built-in mic, chosen over a Bluetooth default.
    private var usingBuiltInOverBluetooth = false
    /// The built-in mic chosen by .avoidBluetooth delivered only digital silence (a MacBook
    /// with its lid closed, say), so the default input is used from then on.
    private var builtInRejected = false
    private var isStopping = false
    private var healthTimer: DispatchSourceTimer?
    private var bindTime: UInt64 = 0
    private var silentWarningActive = false
    private var observers: [NSObjectProtocol] = []
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private static var hardwareAddresses: [AudioObjectPropertyAddress] = [
        // Default input moved (a headset connected, the user picked another mic) ...
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain),
        // ... or a device came or went (the one being recorded, or a named one returning).
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain),
    ]

    // Mute support — guarded by os_unfair_lock (sample callback runs on sampleQueue)
    private var _isMuted = false
    private var _muteLock = os_unfair_lock_s()

    // Level tracking for silence timeout (mirrors SystemAudioCapture pattern)
    private var _lastLoudTime: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var _lastLoudTimeLock = os_unfair_lock_s()

    // Mic health: when the device last delivered any non-zero sample. A live mic always
    // has a noise floor, so exact zeros mean no Microphone permission, a closed lid or a
    // dead device, which used to record silence without a word.
    private var _lastSignalTime: UInt64 = 0
    private var _lastSignalLock = os_unfair_lock_s()

    init(selection: Selection) {
        self.selection = selection
        super.init()
    }

    var lastLoudTime: UInt64 {
        os_unfair_lock_lock(&_lastLoudTimeLock)
        defer { os_unfair_lock_unlock(&_lastLoudTimeLock) }
        return _lastLoudTime
    }

    var isMuted: Bool {
        os_unfair_lock_lock(&_muteLock)
        defer { os_unfair_lock_unlock(&_muteLock) }
        return _isMuted
    }

    private var isNamedSelection: Bool {
        if case .named = selection { return true }
        return false
    }

    func toggleMute() {
        os_unfair_lock_lock(&_muteLock)
        _isMuted.toggle()
        let muted = _isMuted
        os_unfair_lock_unlock(&_muteLock)
        fputs(muted ? "[MIC_MUTED]\n" : "[MIC_UNMUTED]\n", stderr)
    }

    func start(outputPath: String) throws {
        try Self.ensureMicrophoneAccess()
        let target = try resolveTarget()

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.recordSampleRate,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath),
                                   settings: format.settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: true)
        audioFile = file
        fileFormat = file.processingFormat

        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.recordSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else { throw MicError.noInputAvailable }
        session.addOutput(output)
        try attach(target)

        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            fputs("Mic reconfigure: capture error\(error.map { ": \($0.localizedDescription)" } ?? ""); restarting.\n", stderr)
            self?.rebind(reason: "restarting after a capture error.", force: true)
        })
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebind(reason: "audio devices changed; rebinding microphone input.")
        }
        for var addr in Self.hardwareAddresses {
            AudioObjectAddPropertyListenerBlock(kSystemObject, &addr, .main, listener)
        }
        hardwareListener = listener

        session.startRunning()
        fputs("Recording microphone audio to \(outputPath)...\n", stderr)
        didBind()
        startHealthTimer()
    }

    /// Fail up front when the terminal app may not use the microphone: the capture would
    /// otherwise deliver nothing and the mic track would simply be missing.
    private static func ensureMicrophoneAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let done = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                done.signal()
            }
            done.wait()
            if !granted { throw MicError.permissionDenied }
        default:
            throw MicError.permissionDenied
        }
    }

    /// The input device the selection calls for right now.
    private func resolveTarget() throws -> AudioDeviceID {
        usingBuiltInOverBluetooth = false
        switch selection {
        case .named(let name):
            return try findInputDevice(named: name)
        case .systemDefault:
            break
        case .avoidBluetooth:
            if !builtInRejected, let def = defaultInputDevice(), isBluetooth(def),
               let builtIn = builtInInputDevice() {
                usingBuiltInOverBluetooth = true
                return builtIn
            }
        }
        guard let def = defaultInputDevice() else { throw MicError.noInputAvailable }
        return def
    }

    /// Make `id` the session's input. .main only.
    private func attach(_ id: AudioDeviceID) throws {
        guard let device = deviceUID(id).flatMap({ AVCaptureDevice(uniqueID: $0) }) else {
            throw MicError.cannotSetDevice(deviceName(id))
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let currentInput { session.removeInput(currentInput) }
        guard session.canAddInput(input) else {
            if let currentInput, session.canAddInput(currentInput) { session.addInput(currentInput) }
            throw MicError.cannotSetDevice(deviceName(id))
        }
        session.addInput(input)
        currentInput = input
        currentDeviceID = id
    }

    /// Re-pick the device after a device change (or when the health check gives up on the
    /// built-in mic) and switch to it if it differs. .main only, like stop(), so the two
    /// never overlap; isStopping drops a notification that was queued behind stop().
    ///
    /// The mic file is written continuously with no silence padding, so the moment of a
    /// switch is not represented as a gap: the mic track drifts slightly earlier relative
    /// to the system track. Acceptable for transcription and diarization.
    private func rebind(reason: String, force: Bool = false) {
        guard !isStopping else { return }
        var target: AudioDeviceID
        do {
            target = try resolveTarget()
        } catch {
            guard let def = defaultInputDevice() else {
                fputs("Mic reconfigure: \(error); no input device is available.\n", stderr)
                return
            }
            fputs("Mic reconfigure: \(error) — falling back to default input.\n", stderr)
            target = def
        }
        if target == currentDeviceID && !force {
            if !session.isRunning { session.startRunning() }
            return
        }
        fputs("Mic reconfigure: \(reason)\n", stderr)
        do {
            try attach(target)
        } catch {
            fputs("Mic reconfigure: \(error)\n", stderr)
            return
        }
        if !session.isRunning { session.startRunning() }
        didBind()
    }

    /// Reset the silence watchdog and say which mic is now recording. The Python wrapper
    /// shows [MIC_DEVICE] and [MIC_NOTE] lines live; nothing used to report the device.
    /// .main only.
    private func didBind() {
        bindTime = DispatchTime.now().uptimeNanoseconds
        silentWarningActive = false
        guard let id = currentDeviceID else { return }
        fputs("[MIC_DEVICE] \(deviceName(id)) (\(transportLabel(id)), \(Int(nominalSampleRate(id))) Hz)\n", stderr)
        if usingBuiltInOverBluetooth, let def = defaultInputDevice() {
            fputs("[MIC_NOTE] Skipped the default input '\(deviceName(def))': Bluetooth headset mics "
                  + "record in low-quality hands-free mode. Set mic_device to choose a mic yourself.\n", stderr)
        } else if isBluetooth(id) && !isNamedSelection {
            fputs("[MIC_NOTE] '\(deviceName(id))' is a Bluetooth headset mic, which records in low-quality "
                  + "hands-free mode. Use --mic-device to pick another mic.\n", stderr)
        }
    }

    // MARK: Samples (sampleQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, audioFile != nil,
              let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr
        else { return }

        if startHostTime == 0 {
            startHostTime = Self.hostTime(of: sampleBuffer)
        }

        // Peak of what the device delivered, taken before muting zeroes it: the health
        // check is about the device, the silence timeout about the recording.
        let peak = Self.peak(of: buffer)
        let now = DispatchTime.now().uptimeNanoseconds
        if peak > 0 {
            os_unfair_lock_lock(&_lastSignalLock)
            _lastSignalTime = now
            os_unfair_lock_unlock(&_lastSignalLock)
        }
        if isMuted {
            for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
            }
        } else if peak > kMicLoudThreshold {
            os_unfair_lock_lock(&_lastLoudTimeLock)
            _lastLoudTime = now
            os_unfair_lock_unlock(&_lastLoudTimeLock)
        }
        writeBuffer(buffer)
    }

    /// Host time (mach ticks) of the buffer's first sample, for aligning with the system
    /// track. Falls back to now if the timestamp is missing or not on the host clock.
    private static func hostTime(of sampleBuffer: CMSampleBuffer) -> UInt64 {
        let now = mach_absolute_time()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return now }
        let ticks = CMClockConvertHostTimeToSystemUnits(pts)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let tenSeconds = UInt64(10_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
        let diff = ticks > now ? ticks - now : now - ticks
        return diff < tenSeconds ? ticks : now
    }

    /// Peak amplitude over every float sample in the buffer, whatever its layout.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        var peak: Float = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audioBuffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<(Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size) {
                let v = abs(samples[i])
                if v > peak { peak = v }
            }
        }
        return peak
    }

    /// Write a buffer to the file, converting if its format isn't the file's. The capture
    /// output already delivers the file's format, so this is normally a straight write.
    private func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile, let fileFormat else { return }
        do {
            if buffer.format == fileFormat {
                try audioFile.write(from: buffer)
                loggedWriteError = false
                return
            }
            if audioConverter?.inputFormat != buffer.format {
                audioConverter = AVAudioConverter(from: buffer.format, to: fileFormat)
            }
            guard let converter = audioConverter else {
                logWriteErrorOnce("Mic convert error: converter unavailable for format \(buffer.format)")
                return
            }
            let ratio = fileFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat,
                                                   frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error || convError != nil {
                logWriteErrorOnce("Mic convert error: \(convError?.description ?? "unknown")")
                return
            }
            if outBuffer.frameLength > 0 {
                try audioFile.write(from: outBuffer)
                loggedWriteError = false
            }
        } catch {
            logWriteErrorOnce("Mic write error: \(error)")
        }
    }

    private func logWriteErrorOnce(_ message: String) {
        guard !loggedWriteError else { return }
        loggedWriteError = true
        fputs(message + "\n", stderr)
    }

    // MARK: Health

    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.checkMicSignal() }
        timer.resume()
        healthTimer = timer
    }

    /// Once a second on .main: notice a mic that delivers only digital silence (or nothing
    /// at all). A built-in mic picked over a Bluetooth default is given up on in favour of
    /// the default; anything else gets a [MIC_SILENT] warning, and a note when it recovers.
    private func checkMicSignal() {
        guard !isStopping else { return }
        os_unfair_lock_lock(&_lastSignalLock)
        let lastSignal = _lastSignalTime
        os_unfair_lock_unlock(&_lastSignalLock)
        let now = DispatchTime.now().uptimeNanoseconds
        let since = max(lastSignal, bindTime)
        let silentFor = now > since ? Double(now - since) / 1_000_000_000.0 : 0

        if silentFor < kMicSilentAfter {
            if silentWarningActive {
                silentWarningActive = false
                fputs("[MIC_NOTE] Microphone signal is back.\n", stderr)
            }
            return
        }
        if usingBuiltInOverBluetooth && !builtInRejected {
            builtInRejected = true
            fputs("[MIC_NOTE] The built-in mic is delivering only silence (lid closed?); "
                  + "switching to the default input.\n", stderr)
            rebind(reason: "switching from the silent built-in mic to the default input.")
            return
        }
        guard !silentWarningActive else { return }
        silentWarningActive = true
        let name = currentDeviceID.map(deviceName) ?? "the microphone"
        fputs("[MIC_SILENT] '\(name)' has delivered only digital silence for \(Int(kMicSilentAfter)) s, "
              + "so no mic audio is being recorded. Check System Settings > Privacy & Security > Microphone "
              + "for your terminal app, or pick another mic with --mic-device.\n", stderr)
    }

    func stop() {
        isStopping = true
        healthTimer?.cancel()
        healthTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let listener = hardwareListener {
            for var addr in Self.hardwareAddresses {
                AudioObjectRemovePropertyListenerBlock(kSystemObject, &addr, .main, listener)
            }
            hardwareListener = nil
        }
        session.stopRunning()
        // A sample callback may still be running; release (and so finalize) the file on its
        // queue so the two can't race.
        sampleQueue.sync { self.audioFile = nil }
    }

    enum MicError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case cannotSetDevice(String)
        case noInputAvailable
        case permissionDenied

        var description: String {
            switch self {
            case .deviceNotFound(let n): return "Input device not found: \(n)"
            case .cannotSetDevice(let n): return "Cannot record from input device: \(n)"
            case .noInputAvailable: return "No audio input device available"
            case .permissionDenied:
                return "Microphone access is denied for your terminal app "
                    + "(System Settings > Privacy & Security > Microphone)"
            }
        }
    }
}

// MARK: - System Audio Capture via ScreenCaptureKit

class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var audioConverter: AVAudioConverter?
    private let captureQueue = DispatchQueue(label: "com.ownscribe.audioCapture", qos: .userInitiated)

    private let outputPath: String

    // Timestamp for sync alignment
    private(set) var startHostTime: UInt64 = 0

    // Silence detection
    private var peakLevel: Float = 0.0
    private var totalFrames: Int64 = 0
    private var silenceChecked: Bool = false
    private var silenceWarned: Bool = false

    // Set when a write failure has been logged; reset on the next good write, so a
    // persistent failure logs once instead of once per buffer. Capture queue only.
    private var loggedWriteError = false

    // Silence timeout auto-stop
    var silenceTimeout: TimeInterval = 0  // seconds; 0 = disabled
    var onSilenceTimeout: (() -> Void)?
    /// Called on .main when the user cancels the content picker.
    var onCancel: (() -> Void)?
    var micCapture: MicCapture?  // checked by silence timer
    private var lastLoudTime: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var lastLoudTimeLock = os_unfair_lock_s()
    private var silenceTimer: DispatchSourceTimer?

    // Power assertion to prevent display sleep during capture
    private var powerAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    // Picker continuation
    private var startContinuation: CheckedContinuation<Void, Error>?
    /// The picker has already chosen content and capture is starting or running (.main only).
    private var captureRequested = false

    init(outputPath: String) {
        self.outputPath = outputPath
        super.init()
    }

    var captureModeAll: Bool = false

    func start() async throws {
        if captureModeAll {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw CaptureError.noDisplay
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            try await self.beginCapture(with: filter)
        } else {
            let picker = SCContentSharingPicker.shared
            var pickerConfig = SCContentSharingPickerConfiguration()
            pickerConfig.allowedPickerModes = [.singleWindow, .singleDisplay, .singleApplication]
            picker.defaultConfiguration = pickerConfig
            picker.add(self)
            picker.isActive = true
            picker.present()

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.startContinuation = continuation
            }
        }
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { self.handlePickedContent(filter) }
    }

    /// The picker reports again whenever the shared content is changed later (e.g. from
    /// the menu-bar sharing indicator). Starting a second capture then reopened, and so
    /// truncated, the system audio file, and left the first stream and silence timer
    /// running. Retarget the running stream instead. .main only.
    private func handlePickedContent(_ filter: SCContentFilter) {
        guard !captureRequested else {
            guard let stream else {
                fputs("Shared content changed while capture was still starting; keeping the first choice.\n", stderr)
                return
            }
            Task {
                do {
                    try await stream.updateContentFilter(filter)
                    fputs("Shared content changed; system audio continues in the same recording.\n", stderr)
                } catch {
                    fputs("Could not switch the shared content: \(error)\n", stderr)
                }
            }
            return
        }
        captureRequested = true
        Task {
            do {
                try await self.beginCapture(with: filter)
                self.startContinuation?.resume()
                self.startContinuation = nil
            } catch {
                self.startContinuation?.resume(throwing: error)
                self.startContinuation = nil
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // This used to exit(0) on the spot, throwing away the mic audio recorded while the
        // picker was open (the mic file was never even finalised). Stop and save instead.
        fputs("Content picker cancelled; stopping and saving what was recorded.\n", stderr)
        DispatchQueue.main.async { self.onCancel?() }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        self.startContinuation?.resume(throwing: error)
        self.startContinuation = nil
    }

    // MARK: - Begin Capture

    private func beginCapture(with filter: SCContentFilter) async throws {
        // Configure stream (audio only, minimal video)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(kSystemAudioSampleRate)
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        // Create AVAudioFile for WAV output (interleaved to avoid CoreAudio warning)
        let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: kSystemAudioSampleRate, channels: 1, interleaved: true)!
        let audioFile = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath),
                                         settings: fileFormat.settings,
                                         commonFormat: .pcmFormatFloat32,
                                         interleaved: true)
        self.audioFile = audioFile

        // Create and start stream
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)

        // Initialize last-loud time before starting capture (no lock needed — callbacks haven't started)
        if silenceTimeout > 0 {
            lastLoudTime = DispatchTime.now().uptimeNanoseconds
        }

        try await stream.startCapture()
        self.stream = stream

        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "ownscribe is recording audio" as CFString,
            &powerAssertionID)

        fputs("Recording system audio to \(outputPath)... Press Ctrl+C to stop.\n", stderr)

        // Start silence timeout timer if configured.
        // Checks every 1s whether both system audio and mic (if active) have been
        // quiet longer than silenceTimeout. Uses the most recent "loud" timestamp
        // from either source so that activity on either channel prevents auto-stop.
        if silenceTimeout > 0 {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1.0)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                os_unfair_lock_lock(&self.lastLoudTimeLock)
                var effectiveLastLoud = self.lastLoudTime
                os_unfair_lock_unlock(&self.lastLoudTimeLock)
                // If mic is active, use the more recent of the two
                if let mic = self.micCapture {
                    let micLastLoud = mic.lastLoudTime
                    if micLastLoud > effectiveLastLoud {
                        effectiveLastLoud = micLastLoud
                    }
                }
                guard now >= effectiveLastLoud else { return }
                let elapsed = Double(now - effectiveLastLoud) / 1_000_000_000.0
                if elapsed > self.silenceTimeout {
                    fputs("[SILENCE_TIMEOUT]\n", stderr)
                    self.silenceTimer?.cancel()
                    self.silenceTimer = nil
                    self.onSilenceTimeout?()
                }
            }
            timer.resume()
            silenceTimer = timer
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let audioFile else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        // Capture start host time from first audio buffer
        if startHostTime == 0 {
            startHostTime = mach_absolute_time()
        }

        // Get format from sample buffer
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        guard let sampleFormat = AVAudioFormat(streamDescription: asbd) else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: sampleFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // Copy audio data into PCM buffer
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return }

        // Convert non-interleaved → interleaved if needed, then write
        do {
            if sampleFormat.isInterleaved {
                try audioFile.write(from: pcmBuffer)
            } else {
                if audioConverter?.inputFormat != sampleFormat {
                    let interleavedFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                       sampleRate: sampleFormat.sampleRate,
                                                       channels: sampleFormat.channelCount,
                                                       interleaved: true)!
                    audioConverter = AVAudioConverter(from: sampleFormat, to: interleavedFmt)
                }
                if let converter = audioConverter {
                    let outFmt = converter.outputFormat
                    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: frameCount) else { return }
                    try converter.convert(to: outBuffer, from: pcmBuffer)
                    try audioFile.write(from: outBuffer)
                }
            }
            loggedWriteError = false
        } catch {
            // Once per failure streak: at one line per buffer a persistent error used to
            // flood stderr.
            if !loggedWriteError {
                loggedWriteError = true
                fputs("Write error: \(error)\n", stderr)
            }
        }

        totalFrames += Int64(frameCount)

        // Peak detection on the pre-conversion buffer — floatChannelData returns nil
        // for interleaved buffers, so we must use the original SCK buffer
        let bufferPeak: Float = pcmBuffer.floatChannelData.map {
            computePeakLevel(in: $0, channels: Int(pcmBuffer.format.channelCount), frames: Int(pcmBuffer.frameLength))
        } ?? 0.0
        if bufferPeak > self.peakLevel { self.peakLevel = bufferPeak }

        // Update last loud time for silence timeout
        if bufferPeak > kSystemLoudThreshold {
            os_unfair_lock_lock(&lastLoudTimeLock)
            lastLoudTime = DispatchTime.now().uptimeNanoseconds
            os_unfair_lock_unlock(&lastLoudTimeLock)
        }

        // Check for silence after ~3 seconds of data
        if !silenceChecked && Double(totalFrames) > kSystemAudioSampleRate * 3 {
            silenceChecked = true
            if peakLevel < 1e-6 {
                silenceWarned = true
                if micCapture != nil {
                    fputs("[SILENCE_WARNING] System audio is silent (mic is still recording). No system audio sources detected.\n", stderr)
                } else {
                    fputs("[SILENCE_WARNING] Audio data received but peak level is near zero (\(peakLevel)). Audio may be silent.\n", stderr)
                    fputs("Check: System Settings > Privacy & Security > Screen Recording — enable your terminal app.\n", stderr)
                }
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Stream error: \(error)\n", stderr)
    }

    // MARK: - Stop

    func stop() {
        silenceTimer?.cancel()
        silenceTimer = nil

        if powerAssertionID != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(powerAssertionID)
            powerAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        }

        let sem = DispatchSemaphore(value: 0)
        Task.detached { [stream] in
            try? await stream?.stopCapture()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)

        // Release the file on the capture queue. A sample-handler call can still be running
        // (stopCapture may have timed out above), and nil-ing the file from .main raced it.
        // Later callbacks see nil and return. AVAudioFile finalizes on close.
        captureQueue.sync { self.audioFile = nil }

        let seconds = Double(totalFrames) / kSystemAudioSampleRate
        fputs("Saved \(outputPath) (\(String(format: "%.1f", seconds)) seconds, peak=\(String(format: "%.6f", peakLevel)))\n", stderr)
        if totalFrames > 0 && peakLevel < 1e-6 {
            fputs("[SILENCE_WARNING] Recording appears silent. Check Screen Recording permission.\n", stderr)
        }
    }

    enum CaptureError: Error, CustomStringConvertible {
        case cannotOpenFile(String)
        case noDisplay

        var description: String {
            switch self {
            case .cannotOpenFile(let p): return "Cannot open file: \(p)"
            case .noDisplay: return "No display found"
            }
        }
    }
}

// MARK: - List apps

func listAudioApps() {
    print("Running apps:")
    for app in NSWorkspace.shared.runningApplications {
        if app.activationPolicy == .regular, let name = app.localizedName {
            print("  PID \(app.processIdentifier): \(name)")
        }
    }
}

// MARK: - List input devices

func listInputDevices() {
    let defaultDevice = defaultInputDevice()
    print("Input devices:")
    for id in audioDeviceIDs() where inputChannelCount(id) > 0 {
        var tags = [transportLabel(id)]
        if id == defaultDevice { tags.append("default") }
        print("  \(deviceName(id)) (\(tags.joined(separator: ", ")))")
    }
}

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

// MARK: - Main

func printUsage() {
    fputs("""
    ownscribe-audio — system audio capture helper

    USAGE:
        ownscribe-audio capture --output FILE [--mic] [--mic-device NAME] [--avoid-bluetooth-mic]
                                [--capture-mode-all] [--silence-timeout N]
        ownscribe-audio list-apps
        ownscribe-audio list-devices

    OPTIONS:
        --output, -o FILE    Output WAV file path (required for capture)
        --mic                Also capture microphone input
        --mic-device NAME    Use specific mic input device (implies --mic)
        --avoid-bluetooth-mic
                             With --mic and no --mic-device: when the default input is a
                             Bluetooth headset, record the built-in mic instead
        --capture-mode-all   Capture all system audio without showing the source picker
        --silence-timeout N  Auto-stop after N seconds of silence (0 = disabled)
        --help, -h           Show this help

    SUBCOMMANDS:
        capture              Record audio to a WAV file
        list-apps            Show running applications
        list-devices         Show available audio input devices

    """, stderr)
}

func main() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        printUsage()
        exit(1)
    }

    let command = args[1]

    switch command {
    case "list-apps":
        listAudioApps()

    case "list-devices":
        listInputDevices()

    case "capture":
        // The Python wrapper reads our stderr through a pipe. If it goes away (a second
        // Ctrl+C, a crash), the next write would raise SIGPIPE and kill us mid-merge,
        // losing the recording. Ignore it: writes then just fail with EPIPE.
        signal(SIGPIPE, SIG_IGN)

        // Initialize NSApplication so the picker GUI can render
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var outputPath: String?
        var enableMic = false
        var micDeviceName: String?
        var avoidBluetoothMic = false
        var captureModeAll = false
        var silenceTimeout: TimeInterval = 0

        var i = 2
        while i < args.count {
            switch args[i] {
            case "--output", "-o":
                i += 1
                guard i < args.count else {
                    fputs("Error: --output requires a file path\n", stderr)
                    exit(1)
                }
                outputPath = args[i]
            case "--capture-mode-all":
                captureModeAll = true
            case "--mic":
                enableMic = true
            case "--mic-device":
                i += 1
                guard i < args.count else {
                    fputs("Error: --mic-device requires a device name\n", stderr)
                    exit(1)
                }
                micDeviceName = args[i]
                enableMic = true  // --mic-device implies --mic
            case "--avoid-bluetooth-mic":
                avoidBluetoothMic = true
            case "--silence-timeout":
                i += 1
                guard i < args.count, let val = TimeInterval(args[i]) else {
                    fputs("Error: --silence-timeout requires a number of seconds\n", stderr)
                    exit(1)
                }
                if val < 0 {
                    fputs("Error: --silence-timeout must be zero (disabled) or a positive number of seconds\n", stderr)
                    exit(1)
                }
                silenceTimeout = val
            default:
                fputs("Unknown option: \(args[i])\n", stderr)
                printUsage()
                exit(1)
            }
            i += 1
        }

        guard let output = outputPath else {
            fputs("Error: --output is required\n", stderr)
            printUsage()
            exit(1)
        }

        // Determine paths: if mic enabled, use temp files then merge
        let systemPath = enableMic ? output + ".sys.tmp.wav" : output
        let micPath = output + ".mic.tmp.wav"

        let capture = SystemAudioCapture(outputPath: systemPath)
        capture.captureModeAll = captureModeAll
        capture.silenceTimeout = silenceTimeout
        var micCapture: MicCapture?

        // Host time before either track can start: the merge rejects any track start
        // time earlier than this (or 0, meaning the track never delivered audio).
        let sessionStartHostTime = mach_absolute_time()

        // Shared shutdown logic for SIGINT, SIGTERM, the silence timeout and a cancelled
        // picker. All of them arrive on .main; only the first one may run.
        var shuttingDown = false
        let shutdown: () -> Void = {
            guard !shuttingDown else { return }
            shuttingDown = true
            capture.stop()
            if let mic = micCapture {
                mic.stop()
                do {
                    try mergeAudioFiles(
                        systemPath: systemPath,
                        micPath: micPath,
                        systemStartHostTime: capture.startHostTime,
                        micStartHostTime: mic.startHostTime,
                        sessionStartHostTime: sessionStartHostTime,
                        outputPath: output)
                } catch {
                    fputs("Error merging audio: \(error)\n", stderr)
                }
            }
            exit(0)
        }

        capture.onSilenceTimeout = shutdown
        capture.onCancel = shutdown

        // Handle Ctrl+C gracefully. Installed before the mic starts, so an early SIGINT
        // can't hit the default action and kill the process with nothing saved.
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigintSource.setEventHandler { shutdown() }
        sigintSource.resume()

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        sigtermSource.setEventHandler { shutdown() }
        sigtermSource.resume()

        if enableMic {
            let selection: MicCapture.Selection
            if let name = micDeviceName {
                selection = .named(name)
            } else if avoidBluetoothMic {
                selection = .avoidBluetooth
            } else {
                selection = .systemDefault
            }
            let mic = MicCapture(selection: selection)
            do {
                try mic.start(outputPath: micPath)
            } catch {
                fputs("Error starting mic capture: \(error)\n", stderr)
                exit(1)
            }
            micCapture = mic
            capture.micCapture = mic
        }

        // Toggle mic mute on SIGUSR1 (sent by Python wrapper)
        var _sigusr1Source: DispatchSourceSignal?  // retained to keep source alive
        if let mic = micCapture {
            signal(SIGUSR1, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            src.setEventHandler { mic.toggleMute() }
            src.resume()
            _sigusr1Source = src
        }
        _ = _sigusr1Source

        Task {
            do {
                try await capture.start()
            } catch {
                fputs("Error: \(error)\n", stderr)
                exit(1)
            }
        }

        app.run()

    case "--help", "-h":
        printUsage()

    default:
        fputs("Unknown command: \(command)\n", stderr)
        printUsage()
        exit(1)
    }
}

main()
