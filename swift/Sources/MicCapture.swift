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
        /// A device by its Core Audio UID (the engine protocol's `set_mic`); falls back to a name match.
        case uid(String)
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

    private(set) var selection: Selection
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

    /// What the mic reports. The legacy CLI gets the old stderr markers; session mode gets JSON.
    enum Report {
        case device(uid: String, name: String, transport: String, rate: Int, reason: String)
        case note(code: String, message: String)
        case silent(message: String)
        case reconfigure(String)
    }
    /// Session mode: receive each buffer and its host time instead of writing a file here.
    var sink: ((AVAudioPCMBuffer, UInt64) -> Void)?
    var onReport: ((Report) -> Void)?

    init(selection: Selection) {
        self.selection = selection
        super.init()
    }

    private func report(_ report: Report) {
        if let onReport {
            onReport(report)
            return
        }
        switch report {
        case let .device(_, name, transport, rate, _):
            fputs("[MIC_DEVICE] \(name) (\(transport), \(rate) Hz)\n", stderr)
        case let .note(_, message):
            fputs("[MIC_NOTE] \(message)\n", stderr)
        case let .silent(message):
            fputs("[MIC_SILENT] \(message)\n", stderr)
        case let .reconfigure(message):
            fputs("Mic reconfigure: \(message)\n", stderr)
        }
    }

    private var deviceReason: String {
        if builtInRejected { return "fallback" }
        if usingBuiltInOverBluetooth { return "auto" }
        return isNamedSelection ? "device" : "default"
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
        switch selection {
        case .named, .uid: return true
        default: return false
        }
    }

    func toggleMute() {
        os_unfair_lock_lock(&_muteLock)
        _isMuted.toggle()
        let muted = _isMuted
        os_unfair_lock_unlock(&_muteLock)
        fputs(muted ? "[MIC_MUTED]\n" : "[MIC_UNMUTED]\n", stderr)
    }

    func start(outputPath: String?) throws {
        try Self.ensureMicrophoneAccess()
        let target = try resolveTarget()

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.recordSampleRate,
                                   channels: 1, interleaved: false)!
        if let outputPath {
            let file = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath),
                                       settings: format.settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: true)
            audioFile = file
            fileFormat = file.processingFormat
        }

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
        if let outputPath { fputs("Recording microphone audio to \(outputPath)...\n", stderr) }
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
        case .uid(let uid):
            if let id = audioDeviceIDs().first(where: { deviceUID($0) == uid && inputChannelCount($0) > 0 }) {
                return id
            }
            return try findInputDevice(named: uid)
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
        report(.reconfigure(reason))
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
        report(.device(uid: deviceUID(id) ?? "", name: deviceName(id), transport: transportLabel(id),
                       rate: Int(nominalSampleRate(id)), reason: deviceReason))
        if usingBuiltInOverBluetooth, let def = defaultInputDevice() {
            report(.note(code: "mic_bluetooth", message: "Skipped the default input '\(deviceName(def))': Bluetooth headset mics "
                  + "record in low-quality hands-free mode. Set mic_device to choose a mic yourself."))
        } else if isBluetooth(id) && !isNamedSelection {
            report(.note(code: "mic_bluetooth", message: "'\(deviceName(id))' is a Bluetooth headset mic, which records in low-quality "
                  + "hands-free mode. Use --mic-device to pick another mic."))
        }
    }

    /// Switch microphones mid-recording (engine protocol `set_mic`). .main only.
    func setSelection(_ newSelection: Selection) {
        selection = newSelection
        builtInRejected = false
        rebind(reason: "microphone changed.", force: true)
    }

    // MARK: Samples (sampleQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, audioFile != nil || sink != nil,
              let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr
        else { return }

        let bufferHostTime = Self.hostTime(of: sampleBuffer)
        if startHostTime == 0 {
            startHostTime = bufferHostTime
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
        if let sink { sink(buffer, bufferHostTime) } else { writeBuffer(buffer) }
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
                report(.note(code: "mic_signal_back", message: "Microphone signal is back."))
            }
            return
        }
        if usingBuiltInOverBluetooth && !builtInRejected {
            builtInRejected = true
            report(.note(code: "mic_builtin_silent_fallback",
                         message: "The built-in mic is delivering only silence (lid closed?); switching to the default input."))
            rebind(reason: "switching from the silent built-in mic to the default input.")
            return
        }
        guard !silentWarningActive else { return }
        silentWarningActive = true
        let name = currentDeviceID.map(deviceName) ?? "the microphone"
        report(.silent(message: "'\(name)' has delivered only digital silence for \(Int(kMicSilentAfter)) s, "
              + "so no mic audio is being recorded. Check System Settings > Privacy & Security > Microphone "
              + "for your terminal app, or pick another mic with --mic-device."))
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

extension MicCapture: CaptureSource {
    func start() throws { try start(outputPath: nil) }

    /// Stop the capture session behind the recorder's back, as a dead device would.
    func simulateFailure() { session.stopRunning() }
}
