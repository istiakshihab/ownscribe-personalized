import AVFAudio
import Foundation

// MARK: - capture.json

/// The helper's half of the session folder: tracks, fader and mute history, status.
/// Written atomically on every change so a crash leaves a mergeable session.
struct CaptureManifest: Codable {
    struct Track: Codable {
        var id: String
        var kind: String          // system | mic | app | test
        var name: String
        var bundleID: String?
        var file: String          // relative to the session folder

        enum CodingKeys: String, CodingKey {
            case id, kind, name, file
            case bundleID = "bundle_id"
        }
    }
    struct GainChange: Codable { var t: Double; var source: String; var db: Double }
    struct MuteChange: Codable { var t: Double; var source: String; var muted: Bool }
    /// A stretch where a source delivered nothing although it should have (its track holds
    /// silence there). `to` is nil if the source never came back before the end.
    struct Gap: Codable {
        var source: String
        var from: Double
        var to: Double?

        func encode(to encoder: Encoder) throws {  // write `"to": null`, not leave it out
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(source, forKey: .source)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        }
    }

    var version = 1
    var status = "recording"      // recording | saved | partial | failed
    var sessionStart: String
    var sampleRate = kTrackSampleRate
    var duration: Double?
    var tracks: [Track] = []
    var gainLog: [GainChange] = []
    var muteLog: [MuteChange] = []
    var gaps: [Gap]?              // optional so capture.json files from before gaps still load
    var recording: String?

    enum CodingKeys: String, CodingKey {
        case version, status, duration, tracks, recording, gaps
        case sessionStart = "session_start"
        case sampleRate = "sample_rate"
        case gainLog = "gain_log"
        case muteLog = "mute_log"
    }

    static func load(from dir: URL) throws -> CaptureManifest {
        try JSONDecoder().decode(CaptureManifest.self, from: Data(contentsOf: dir.appendingPathComponent("capture.json")))
    }

    func save(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        let target = dir.appendingPathComponent("capture.json")
        let temp = dir.appendingPathComponent(".capture.json.tmp")
        try data.write(to: temp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
    }
}

// MARK: - Header repair (crash recovery)

/// A WAV whose writer was killed still says "0 bytes of data" in its header. Recompute the RIFF
/// and data chunk sizes from the file length so the audio can be read. Returns true if patched.
@discardableResult
func repairWavHeader(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forUpdating: url) else { return false }
    defer { try? handle.close() }
    guard let fileSize = try? handle.seekToEnd(), fileSize > 12 else { return false }
    try? handle.seek(toOffset: 0)
    guard let header = try? handle.read(upToCount: 12), header.count == 12,
          header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else { return false }
    var offset: UInt64 = 12
    while offset + 8 <= fileSize {
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.read(upToCount: 8), chunk.count == 8 else { return false }
        let size = chunk.suffix(4).withUnsafeBytes { UInt64($0.loadUnaligned(as: UInt32.self).littleEndian) }
        if chunk.prefix(4) == Data("data".utf8) {
            let actual = fileSize - (offset + 8)
            guard size != actual, actual <= UInt64(UInt32.max) else { return false }
            var dataSize = UInt32(actual).littleEndian
            var riffSize = UInt32(min(fileSize - 8, UInt64(UInt32.max))).littleEndian
            try? handle.seek(toOffset: offset + 4)
            try? handle.write(contentsOf: Data(bytes: &dataSize, count: 4))
            try? handle.seek(toOffset: 4)
            try? handle.write(contentsOf: Data(bytes: &riffSize, count: 4))
            return true
        }
        offset += 8 + size + (size & 1)
    }
    return false
}

// MARK: - Mixdown

struct SessionMergeResult {
    var recording: URL?
    var frames: AVAudioFramePosition
    var mergedTracks: [String]
    var skippedTracks: [String]
}

/// Linear gain for each frame of a chunk from a fader history: the level holds between changes
/// and ramps over 20 ms at each change (no zipper noise). Gains at or below -60 dB are silence.
struct GainAutomation {
    private let points: [(frame: AVAudioFramePosition, gain: Float)]
    private static let rampFrames = AVAudioFramePosition(0.02 * kTrackSampleRate)

    init(_ changes: [CaptureManifest.GainChange]) {
        points = changes.sorted { $0.t < $1.t }.map {
            (AVAudioFramePosition($0.t * kTrackSampleRate), $0.db <= -60 ? 0 : Float(pow(10, $0.db / 20)))
        }
    }

    func fill(_ out: UnsafeMutablePointer<Float>, from start: AVAudioFramePosition, count: Int) {
        var previous: Float = 1
        var index = 0
        // Level in force at `start`.
        while index < points.count, points[index].frame + Self.rampFrames <= start {
            previous = points[index].gain
            index += 1
        }
        for i in 0..<count {
            let frame = start + AVAudioFramePosition(i)
            while index < points.count, frame >= points[index].frame + Self.rampFrames {
                previous = points[index].gain
                index += 1
            }
            if index < points.count, frame >= points[index].frame {
                let progress = Float(frame - points[index].frame) / Float(Self.rampFrames)
                out[i] = previous + (points[index].gain - previous) * progress
            } else {
                out[i] = previous
            }
        }
    }
}

/// Soft knee above -1 dBFS instead of a hard clip, so several loud sources summed don't crackle.
@inline(__always)
func softLimit(_ x: Float) -> Float {
    let knee: Float = 0.89
    let a = abs(x)
    guard a > knee else { return x }
    let over = (a - knee) / (1 - knee)
    return (x < 0 ? -1 : 1) * (knee + (1 - knee) * tanhf(over))
}

/// Mix every track in capture.json into recording.wav, applying the fader history.
func mergeSession(at dir: URL, manifest: CaptureManifest) throws -> SessionMergeResult {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: kTrackSampleRate, channels: 1, interleaved: false)!
    var readers: [(id: String, file: AVAudioFile, gain: GainAutomation)] = []
    var skipped: [String] = []
    for track in manifest.tracks {
        let url = dir.appendingPathComponent(track.file)
        repairWavHeader(at: url)
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              file.processingFormat.sampleRate == kTrackSampleRate, file.processingFormat.channelCount == 1 else {
            skipped.append(track.id)
            continue
        }
        readers.append((track.id, file, GainAutomation(manifest.gainLog.filter { $0.source == track.id })))
    }
    guard !readers.isEmpty else { return SessionMergeResult(recording: nil, frames: 0, mergedTracks: [], skippedTracks: skipped) }

    let total = readers.map { $0.file.length }.max() ?? 0
    let outURL = dir.appendingPathComponent("recording.wav")
    let output = try AVAudioFile(forWriting: outURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    let chunk: AVAudioFrameCount = 8192
    guard let mix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
          let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw TapError(code: "merge_failed", description: "out of memory") }
    let gains = UnsafeMutablePointer<Float>.allocate(capacity: Int(chunk))
    defer { gains.deallocate() }

    var position: AVAudioFramePosition = 0
    while position < total {
        let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - position))
        mix.frameLength = count
        let out = mix.floatChannelData![0]
        out.update(repeating: 0, count: Int(count))
        for reader in readers where position < reader.file.length {
            reader.file.framePosition = position
            input.frameLength = 0
            try reader.file.read(into: input, frameCount: count)
            let n = Int(input.frameLength)
            reader.gain.fill(gains, from: position, count: n)
            let samples = input.floatChannelData![0]
            for i in 0..<n { out[i] += samples[i] * gains[i] }
        }
        for i in 0..<Int(count) { out[i] = softLimit(out[i]) }
        try output.write(from: mix)
        position += AVAudioFramePosition(count)
    }
    return SessionMergeResult(recording: outURL, frames: total, mergedTracks: readers.map(\.id), skippedTracks: skipped)
}
