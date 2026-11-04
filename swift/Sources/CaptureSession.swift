import AVFAudio
import AppKit
import CoreAudio
import Foundation

let kHelperVersion = "2.0.0"
let kProtocolVersion = 1

/// Session-mode capture (`capture --session DIR --control stdio`): any number of sources, each
/// with its own aligned track, a mixer (gain, mute), live levels, and a merge on stop.
///
/// Everything here runs on the main queue: commands, timers, listeners and stop.
final class CaptureSession {
    struct Options {
        var dir: URL
        var mic = true
        var micSelection: MicCapture.Selection = .avoidBluetooth
        var apps: [String] = []
        var excludeBundles: [String] = []
        var testTone = false
        var silenceTimeout: TimeInterval = 0
    }

    final class Entry {
        let id: String
        let kind: String
        var name: String
        let bundleID: String?
        let writer: TrackWriter
        var source: CaptureSource?
        var gainDb: Double = 0
        var muted = false
        var state = "active"  // active | lost | removed

        init(id: String, kind: String, name: String, bundleID: String?, writer: TrackWriter) {
            self.id = id
            self.kind = kind
            self.name = name
            self.bundleID = bundleID
            self.writer = writer
        }
    }

    private let options: Options
    let sessionStart: UInt64
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var manifest: CaptureManifest
    private var mic: MicCapture?
    private var otherApps: ProcessTapSource?
    private var appTaps: [String: ProcessTapSource] = [:]
    private var levelsTimer: DispatchSourceTimer?
    private var seq = 0
    private var lastLoud: UInt64
    private var warnedSilence = false
    private var stopping = false
    private var hadFailure = false
    private var refreshScheduled = false
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private static let hardwareSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyProcessObjectList,       // apps opened/closed helper processes
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,     // tap clock must follow the output device
    ]

    init(options: Options) {
        self.options = options
        sessionStart = mach_absolute_time()
        lastLoud = sessionStart
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        manifest = CaptureManifest(sessionStart: iso.string(from: Date()))
    }

    private var now: Double { HostTime.elapsed(from: sessionStart, to: mach_absolute_time()) }

    // MARK: - Start

    func start() {
        EventWriter.shared.enable(sessionStart: sessionStart)
        EventWriter.shared.emit("ready", ["version": kHelperVersion, "protocol": kProtocolVersion])
        do {
            try FileManager.default.createDirectory(at: options.dir.appendingPathComponent("tracks"),
                                                    withIntermediateDirectories: true)
        } catch {
            fail("session_dir_failed", "Cannot create the session folder: \(error.localizedDescription)")
            finishAndExit(status: "failed")
            return
        }

        // System audio first: "Other apps" when any app has its own source.
        if let sys = makeEntry(id: "sys", kind: options.testTone ? "test" : "system", name: "System audio", bundleID: nil) {
            if options.testTone {
                startSource(sys, TestToneSource(writer: sys.writer, frequency: 440))
            } else {
                let tap = ProcessTapSource(mode: .exclude, prefixes: options.apps + options.excludeBundles, writer: sys.writer)
                otherApps = tap
                startSource(sys, tap)
            }
        }
        if options.mic, let micEntry = makeEntry(id: "mic", kind: options.testTone ? "test" : "mic", name: "Microphone", bundleID: nil) {
            if options.testTone {
                startSource(micEntry, TestToneSource(writer: micEntry.writer, frequency: 660, level: 0.15))
            } else {
                startMic(micEntry)
            }
        }
        for bundleID in options.apps { addApp(bundleID, commandID: nil) }

        installHardwareListener()
        startLevelsTimer()
        saveManifest()
        emitSources()
        if entries.values.allSatisfy({ $0.state != "active" }) {
            fail("no_sources", "No source could be started")
            stop(reason: "error")
        }
    }

    private func makeEntry(id: String, kind: String, name: String, bundleID: String?) -> Entry? {
        let file = "tracks/\(id.replacingOccurrences(of: ":", with: "-")).wav"
        do {
            let writer = try TrackWriter(id: id, url: options.dir.appendingPathComponent(file), sessionStart: sessionStart)
            writer.onWriteError = { message in
                EventWriter.shared.emit("notice", ["level": "error", "code": "write_error", "source": id, "message": message])
            }
            let entry = Entry(id: id, kind: kind, name: name, bundleID: bundleID, writer: writer)
            entries[id] = entry
            order.append(id)
            manifest.tracks.append(.init(id: id, kind: kind, name: name, bundleID: bundleID, file: file))
            return entry
        } catch {
            fail("write_error", "Cannot create the \(name) track: \(error.localizedDescription)", source: id)
            return nil
        }
    }

    /// Start a source; a failure marks only that source lost, the rest keep recording.
    private func startSource(_ entry: Entry, _ source: CaptureSource) {
        do {
            try source.start()
            entry.source = source
            entry.state = "active"
        } catch {
            entry.state = "lost"
            let code = (error as? TapError)?.code ?? "source_failed"
            fail(code, "\(entry.name): \(error)", source: entry.id)
        }
    }

    private func startMic(_ entry: Entry) {
        let capture = MicCapture(selection: options.micSelection)
        capture.sink = { [writer = entry.writer] buffer, hostTime in writer.append(buffer, hostTime: hostTime) }
        capture.onReport = { [weak self] report in self?.handleMicReport(report) }
        do {
            try capture.start(outputPath: nil)
            mic = capture
            entry.source = capture
            entry.state = "active"
        } catch {
            entry.state = "lost"
            let code = (error as? MicCapture.MicError).map { if case .permissionDenied = $0 { return "mic_permission_denied" } else { return "mic_failed" } } ?? "mic_failed"
            fail(code, "Microphone: \(error)", source: "mic")
        }
    }

    private func handleMicReport(_ report: MicCapture.Report) {
        switch report {
        case let .device(uid, name, transport, rate, reason):
            if let entry = entries["mic"], entry.name != name {
                entry.name = name
                if let i = manifest.tracks.firstIndex(where: { $0.id == "mic" }) { manifest.tracks[i].name = name }
                saveManifest()
                emitSources()
            }
            EventWriter.shared.emit("mic", ["uid": uid, "name": name, "transport": transport, "rate": rate, "reason": reason])
        case let .note(code, message):
            EventWriter.shared.emit("notice", ["level": "info", "code": code, "message": message, "source": "mic"])
        case let .silent(message):
            EventWriter.shared.emit("notice", ["level": "warning", "code": "mic_silent", "message": message, "source": "mic"])
        case let .reconfigure(message):
            EventWriter.shared.emit("notice", ["level": "info", "code": "mic_reconfigure", "message": message, "source": "mic"])
        }
    }

    // MARK: - Commands

    func handle(_ command: [String: Any]) {
        let id = command["id"]
        let cmd = command["cmd"] as? String ?? ""
        func ack() { if let id { EventWriter.shared.emit("ack", ["id": id]) } }
        func reject(_ code: String, _ message: String) {
            EventWriter.shared.emit("error", ["id": id ?? NSNull(), "code": code, "message": message])
        }
        guard !stopping else { return reject("stopping", "The session is stopping") }

        switch cmd {
        case "set_gain":
            guard let entry = entries[command["source"] as? String ?? ""] else { return reject("unknown_source", "No such source") }
            guard let db = (command["db"] as? NSNumber)?.doubleValue else { return reject("bad_args", "db must be a number") }
            entry.gainDb = min(6, max(-60, db))
            manifest.gainLog.append(.init(t: now, source: entry.id, db: entry.gainDb))
            saveManifest()
            ack()
            emitSources()
        case "set_mute":
            guard let entry = entries[command["source"] as? String ?? ""] else { return reject("unknown_source", "No such source") }
            let muted = (command["muted"] as? Bool) ?? !entry.muted
            entry.muted = muted
            entry.writer.muted = muted
            manifest.muteLog.append(.init(t: now, source: entry.id, muted: muted))
            saveManifest()
            ack()
            emitSources()
        case "set_mic":
            guard let mic else { return reject("no_mic", "The microphone isn't being recorded") }
            let spec = command["mic"] as? [String: Any] ?? [:]
            switch spec["mode"] as? String {
            case "auto": mic.setSelection(.avoidBluetooth)
            case "default": mic.setSelection(.systemDefault)
            case "device":
                guard let uid = spec["uid"] as? String, !uid.isEmpty else { return reject("bad_args", "mic.uid is required") }
                mic.setSelection(.uid(uid))
            default: return reject("bad_args", "mic.mode must be auto, default or device")
            }
            ack()
        case "add_app":
            guard let bundleID = command["bundle_id"] as? String, !bundleID.isEmpty else { return reject("bad_args", "bundle_id is required") }
            addApp(bundleID, commandID: id)
        case "remove_app":
            guard let bundleID = command["bundle_id"] as? String, let entry = entries["app:\(bundleID)"], entry.state == "active" else {
                return reject("unknown_source", "That app doesn't have its own source")
            }
            removeApp(entry)
            ack()
        case "ping":
            ack()
        case "stop":
            ack()
            stop(reason: "command")
        default:
            reject("unknown_command", "Unknown cmd \(cmd)")
        }
    }

    private func addApp(_ bundleID: String, commandID: Any?) {
        let id = "app:\(bundleID)"
        func reject(_ code: String, _ message: String) {
            if commandID != nil {
                EventWriter.shared.emit("error", ["id": commandID!, "code": code, "message": message])
            } else {
                fail(code, message, source: id)
            }
        }
        if let existing = entries[id], existing.state == "active" { return reject("already_added", "\(existing.name) already has its own source") }
        let name = runningApps().first { $0.bundleID == bundleID }?.name ?? bundleID
        guard let entry = entries[id] ?? makeEntry(id: id, kind: options.testTone ? "test" : "app", name: name, bundleID: bundleID) else {
            return reject("write_error", "Cannot create a track for \(name)")
        }
        // Split order: start the app's own source, then take it out of "Other apps". A few
        // milliseconds of overlap beats a gap.
        if options.testTone {
            startSource(entry, TestToneSource(writer: entry.writer, frequency: 330 + Double(order.count) * 110, level: 0.2))
        } else {
            let tap = ProcessTapSource(mode: .include, prefixes: [bundleID], writer: entry.writer)
            startSource(entry, tap)
            if entry.state == "active" { appTaps[bundleID] = tap }
        }
        guard entry.state == "active" else { return }
        otherApps?.update(prefixes: activeAppPrefixes() + options.excludeBundles)
        renameSystem()
        saveManifest()
        if let commandID { EventWriter.shared.emit("ack", ["id": commandID]) }
        emitSources()
    }

    private func removeApp(_ entry: Entry) {
        // Rejoin order: give the app back to "Other apps" first, then stop its own source.
        entry.state = "removed"
        otherApps?.update(prefixes: activeAppPrefixes() + options.excludeBundles)
        entry.source?.stop()
        entry.source = nil
        if let bundleID = entry.bundleID { appTaps[bundleID] = nil }
        renameSystem()
        saveManifest()
        emitSources()
    }

    private func activeAppPrefixes() -> [String] {
        entries.values.filter { $0.kind != "system" && $0.bundleID != nil && $0.state == "active" }.compactMap(\.bundleID)
    }

    private func renameSystem() {
        guard let sys = entries["sys"] else { return }
        let name = activeAppPrefixes().isEmpty ? "System audio" : "Other apps"
        guard sys.name != name else { return }
        sys.name = name
        if let i = manifest.tracks.firstIndex(where: { $0.id == "sys" }) { manifest.tracks[i].name = name }
    }

    // MARK: - Levels, silence, hardware changes

    private func startLevelsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tickLevels() }
        timer.resume()
        levelsTimer = timer
    }

    private func tickLevels() {
        guard !stopping else { return }
        var sources: [String: Any] = [:]
        var loud = false
        for id in order {
            guard let entry = entries[id], entry.state == "active" else { continue }
            let (peak, rms) = entry.writer.takeMeter()
            sources[id] = ["peak": dbfs(peak) as Any, "rms": dbfs(rms) as Any]
            let threshold: Float = entry.kind == "mic" ? kMicLoudThreshold : kSystemLoudThreshold
            if !entry.muted && peak > threshold { loud = true }
        }
        seq += 1
        EventWriter.shared.emitLevels(["seq": seq, "sources": sources])

        let t = mach_absolute_time()
        if loud {
            lastLoud = t
            warnedSilence = false
        }
        guard options.silenceTimeout > 0 else { return }
        let quiet = HostTime.elapsed(from: lastLoud, to: t)
        let warnAt = max(options.silenceTimeout - 30, options.silenceTimeout * 0.8)
        if quiet >= options.silenceTimeout {
            stop(reason: "silence_timeout")
        } else if quiet >= warnAt && !warnedSilence {
            warnedSilence = true
            EventWriter.shared.emit("notice", ["level": "warning", "code": "silence_timeout_soon",
                                               "seconds_left": Int((options.silenceTimeout - quiet).rounded()),
                                               "message": "Recording stops soon: everything has been silent."])
        }
    }

    private func installHardwareListener() {
        guard !options.testTone else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            let selectors = (0..<Int(count)).map { addresses[$0].mSelector }
            if selectors.contains(kAudioHardwarePropertyProcessObjectList) {
                self?.scheduleTapRefresh()
            } else {
                self?.restartTaps()
            }
        }
        for selector in Self.hardwareSelectors {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        }
        hardwareListener = listener
    }

    private func removeHardwareListener() {
        guard let listener = hardwareListener else { return }
        for selector in Self.hardwareSelectors {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        }
        hardwareListener = nil
    }

    /// Processes come and go constantly (each browser tab, helper, etc.); refresh at most 4x/s.
    private func scheduleTapRefresh() {
        guard !refreshScheduled, !stopping else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            refreshScheduled = false
            for tap in appTaps.values { tap.update() }
            otherApps?.update()
        }
    }

    private func restartTaps() {
        guard !stopping else { return }
        for tap in appTaps.values { tap.restartAggregate() }
        otherApps?.restartAggregate()
        EventWriter.shared.emit("notice", ["level": "info", "code": "output_device_changed",
                                           "message": "Output device changed; system and app capture re-attached."])
    }

    // MARK: - Stop

    func stop(reason: String) {
        guard !stopping else { return }
        stopping = true
        EventWriter.shared.emit("stopping", ["reason": reason])
        levelsTimer?.cancel()
        levelsTimer = nil
        removeHardwareListener()
        for entry in entries.values {
            entry.source?.stop()
            entry.source = nil
        }
        let duration = now
        let frames = AVAudioFramePosition(duration * kTrackSampleRate)
        for entry in entries.values { entry.writer.finish(padTo: frames) }
        manifest.duration = (duration * 1000).rounded() / 1000

        var status = hadFailure ? "partial" : "ok"
        do {
            let result = try mergeSession(at: options.dir, manifest: manifest)
            if let recording = result.recording {
                manifest.recording = recording.lastPathComponent
                if !result.skippedTracks.isEmpty { status = "partial" }
            } else {
                status = "failed"
            }
        } catch {
            fail("merge_failed", "Mixing the tracks failed: \(error.localizedDescription)")
            status = "failed"
        }
        finishAndExit(status: status)
    }

    private func finishAndExit(status: String) {
        manifest.status = status == "ok" ? "saved" : status
        saveManifest()
        let recording = manifest.recording.map { options.dir.appendingPathComponent($0).path }
        EventWriter.shared.emit("saved", ["status": status, "recording": recording as Any,
                                          "tracks": manifest.tracks.map(\.file), "duration": manifest.duration ?? 0])
        EventWriter.shared.flush()
        exit(status == "ok" ? 0 : status == "partial" ? 2 : 1)
    }

    // MARK: - Helpers

    private func fail(_ code: String, _ message: String, source: String? = nil) {
        hadFailure = true
        var fields: [String: Any] = ["level": "error", "code": code, "message": message]
        if let source { fields["source"] = source }
        EventWriter.shared.emit("notice", fields)
    }

    private func saveManifest() {
        do { try manifest.save(to: options.dir) } catch {
            EventWriter.shared.emit("notice", ["level": "error", "code": "write_error",
                                               "message": "Cannot write capture.json: \(error.localizedDescription)"])
        }
    }

    private func emitSources() {
        let list: [[String: Any]] = order.compactMap { id in
            guard let e = entries[id] else { return nil }
            var item: [String: Any] = ["id": e.id, "kind": e.kind, "name": e.name, "gain_db": e.gainDb,
                                       "muted": e.muted, "state": e.state]
            if let bundleID = e.bundleID { item["bundle_id"] = bundleID }
            return item
        }
        EventWriter.shared.emit("sources", ["list": list])
    }
}

// MARK: - Entry point for `capture --session`

/// Reads commands from stdin on its own thread and runs them on the main queue, one at a time.
/// EOF (the client quit or crashed) stops and saves the session.
func startCommandReader(_ session: CaptureSession) {
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                EventWriter.shared.emit("error", ["id": NSNull(), "code": "bad_json",
                                                  "message": "Each command must be one JSON object per line"])
                continue
            }
            DispatchQueue.main.async { session.handle(object) }
        }
        DispatchQueue.main.async { session.stop(reason: "stdin_closed") }
    }
}

func runSessionCapture(_ args: [String]) -> Never {
    var dir: String?
    var options = CaptureSession.Options(dir: URL(fileURLWithPath: "."))
    var control = false
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else {
            fputs("Error: \(flag) needs a value\n", stderr)
            exit(64)
        }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--session": dir = value("--session")
        case "--control":
            let mode = value("--control")
            guard mode == "stdio" else { fputs("Error: only --control stdio is supported\n", stderr); exit(64) }
            control = true
        case "--mic": options.mic = true
        case "--no-mic": options.mic = false
        case "--mic-auto": options.micSelection = .avoidBluetooth
        case "--mic-default": options.micSelection = .systemDefault
        case "--mic-device": options.micSelection = .uid(value("--mic-device"))
        case "--app": options.apps.append(value("--app"))
        case "--exclude-bundle": options.excludeBundles.append(value("--exclude-bundle"))
        case "--source":
            guard value("--source") == "test-tone" else { fputs("Error: --source supports only test-tone\n", stderr); exit(64) }
            options.testTone = true
        case "--silence-timeout":
            guard let seconds = TimeInterval(value("--silence-timeout")), seconds >= 0 else {
                fputs("Error: --silence-timeout needs a number of seconds\n", stderr)
                exit(64)
            }
            options.silenceTimeout = seconds
        case "--capture-mode-all": break  // session mode always captures all system audio
        default:
            fputs("Unknown option for session capture: \(args[i])\n", stderr)
            exit(64)
        }
        i += 1
    }
    guard let dir else { fputs("Error: --session DIR is required\n", stderr); exit(64) }
    guard control else { fputs("Error: session capture is driven over --control stdio\n", stderr); exit(64) }
    options.dir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // An accessory app with no windows is a prime App Nap candidate; timers would be throttled.
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "ownscribe is recording")
    _ = activity

    let session = CaptureSession(options: options)
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { session.stop(reason: "signal") }
        source.resume()
        signalSources.append(source)
    }
    session.start()
    startCommandReader(session)
    app.run()
    exit(0)
}

/// Retains the signal sources for the process lifetime.
private var signalSources: [DispatchSourceSignal] = []
