import AVFAudio
import Foundation

/// Sample rate of every session track and of the mixdown.
let kTrackSampleRate: Double = 24000

/// Writes one source to its own mono float32 WAV at 24 kHz, aligned to the session start.
///
/// Buffers arrive with the host time of their first sample. The writer converts them to the
/// track format and places them at the matching frame: a gap (source not yet added, removed,
/// device switching) is padded with silence, an overlap is trimmed. Every track therefore starts
/// at the session start and the tracks line up sample for sample, so mixing is a plain sum.
///
/// Muting writes zeros, so muted audio never reaches disk. Meters are taken before muting.
final class TrackWriter: @unchecked Sendable {
    let id: String
    let url: URL

    /// Corrections smaller than this are ignored, so clock jitter doesn't cause clicks.
    private static let toleranceFrames: AVAudioFramePosition = 720  // 30 ms

    private let sessionStart: UInt64
    private let queue: DispatchQueue
    private let format: AVAudioFormat
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var written: AVAudioFramePosition = 0
    private var loggedError = false

    private struct Meter { var peak: Float = 0; var sumSquares: Double = 0; var count = 0 }
    private let meter = Locked(Meter())
    private let mutedState = Locked(false)
    private let lastSignal = Locked<UInt64>(0)

    var onWriteError: ((String) -> Void)?

    init(id: String, url: URL, sessionStart: UInt64) throws {
        self.id = id
        self.url = url
        self.sessionStart = sessionStart
        queue = DispatchQueue(label: "com.ownscribe.track.\(id)", qos: .userInitiated)
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: kTrackSampleRate, channels: 1,
                               interleaved: false)!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                               interleaved: true)
    }

    var muted: Bool {
        get { mutedState.get() }
        set { mutedState.set(newValue) }
    }

    /// Host time of the last buffer that had any non-zero sample (0 if none yet).
    var lastSignalHostTime: UInt64 { lastSignal.get() }

    /// Hand a buffer over. The writer takes ownership; don't reuse it afterwards.
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        queue.async { [self] in write(buffer, hostTime: hostTime) }
    }

    /// Peak and RMS (linear) since the last call.
    func takeMeter() -> (peak: Float, rms: Float) {
        meter.update { m in
            defer { m = Meter() }
            return (m.peak, m.count > 0 ? Float((m.sumSquares / Double(m.count)).squareRoot()) : 0)
        }
    }

    var framesWritten: AVAudioFramePosition { queue.sync { written } }

    /// Pad with silence up to `frames` (the session length) and close the file.
    func finish(padTo frames: AVAudioFramePosition) {
        queue.sync {
            if frames > written { writeSilence(frames - written) }
            file = nil  // AVAudioFile finalises the header on release
        }
    }

    // MARK: - Writer queue

    private func write(_ input: AVAudioPCMBuffer, hostTime: UInt64) {
        guard file != nil, input.frameLength > 0 else { return }
        guard let buffer = convert(input), buffer.frameLength > 0 else { return }
        let samples = UnsafeMutableBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))

        var peak: Float = 0
        var sumSquares: Double = 0
        for v in samples {
            peak = max(peak, abs(v))
            sumSquares += Double(v) * Double(v)
        }
        meter.update { m in
            m.peak = max(m.peak, peak)
            m.sumSquares += sumSquares
            m.count += samples.count
        }
        if peak > 0 { lastSignal.set(hostTime) }
        if muted { samples.update(repeating: 0) }

        var offset: AVAudioFramePosition = 0
        let target = AVAudioFramePosition((HostTime.elapsed(from: sessionStart, to: hostTime) * kTrackSampleRate).rounded())
        if target > written + Self.toleranceFrames {
            writeSilence(target - written)
        } else if target < written - Self.toleranceFrames {
            offset = min(written - target, AVAudioFramePosition(buffer.frameLength))  // overlap: drop the start
        }
        guard offset < AVAudioFramePosition(buffer.frameLength) else { return }
        if offset > 0 {
            let remaining = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - offset)
            guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining) else { return }
            tail.frameLength = remaining
            tail.floatChannelData![0].update(from: buffer.floatChannelData![0] + Int(offset), count: Int(remaining))
            writeFrames(tail)
        } else {
            writeFrames(buffer)
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
            converter?.downmix = true
        }
        guard let converter else {
            reportOnce("cannot convert \(input.format) to the track format")
            return nil
        }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            reportOnce("convert failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        return output
    }

    private func writeSilence(_ frames: AVAudioFramePosition) {
        let chunk: AVAudioFrameCount = 8192
        guard let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        zeros.floatChannelData![0].update(repeating: 0, count: Int(chunk))
        var remaining = frames
        while remaining > 0 {
            zeros.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            writeFrames(zeros)
            remaining -= AVAudioFramePosition(zeros.frameLength)
        }
    }

    private func writeFrames(_ buffer: AVAudioPCMBuffer) {
        guard let file else { return }
        do {
            try file.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
            loggedError = false
        } catch {
            reportOnce("write failed: \(error.localizedDescription)")
        }
    }

    private func reportOnce(_ message: String) {
        guard !loggedError else { return }
        loggedError = true
        onWriteError?(message)
    }
}
