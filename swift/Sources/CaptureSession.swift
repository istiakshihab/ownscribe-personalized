import AVFAudio
import AppKit
import CoreAudio
import Foundation

let kHelperVersion = "2.3.0"  // 2.3: watch-meetings; 2.2: tap audio read at the device's real sample rate
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
        /// Accept `debug_fail_source` (tests only).
        var debugCommands = false
    }

    final class Entry {
        let id: String
        let kind: String
        var name: String
        let bundleID: String?
        let writer: TrackWriter
        /// Builds a fresh source for this track: at start, on re-adding an app, and on recovery.
        let factory: (TrackWriter) -> CaptureSource
        var source: CaptureSource?
        var gainDb: Double = 0
        var muted = false
        var state = "active"  // active | lost | removed

        // Watchdog (main queue). Host times.
        /// Since when audio has been due without a break (nil while none is due, e.g. a silent app).
        var dueSince: UInt64?
        /// Missing audio before this moment doesn't count: the source was just (re)started, the
        /// mic switched device, the output device changed or the Mac woke.
        var watchFrom: UInt64 = 0
        /// When the source was marked lost (identifies one loss for the delayed hand-over to "Other apps").
        var lostAt: UInt64?
        var nextRetry: UInt64 = 0
        var retryDelay: Double = 2
        var gapIndex: Int?
        /// `debug_fail_source`: how many recovery attempts to fail on purpose.
        var failRecoveries = 0

        init(id: String, kind: String, name: String, bundleID: String?, writer: TrackWriter,
             factory: @escaping (TrackWriter) -> CaptureSource) {
            self.id = id
            self.kind = kind
            self.name = name
            self.bundleID = bundleID
            self.writer = writer
            self.factory = factory
        }
    }

    /// Audio due but missing for this long (after any grace period) means the source is lost.
    static let stallLimit = 3.0
    /// Grace after a source (re)starts or reconfigures before missing audio counts.
    static let startGrace = 2.0
    static let maxRetryDelay = 15.0

    private let options: Options
    let sessionStart: UInt64
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var manifest: CaptureManifest
    private var micSelection: MicCapture.Selection
    private var mic: MicCapture? { entries["mic"]?.source as? MicCapture }
    private var otherApps: ProcessTapSource? { entries["sys"]?.source as? ProcessTapSource }
    private var appTaps: [ProcessTapSource] {
        entries.values.filter { $0.kind == "app" && $0.state != "removed" }.compactMap { $0.source as? ProcessTapSource }
    }
    private var levelsTimer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
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
        micSelection = options.micSelection
        sessionStart = mach_absolute_time()
        lastLoud = sessionStart
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        manifest = CaptureManifest(sessionStart: iso.string(from: Date()))
    }

    private var now: Double { HostTime.elapsed(from: sessionStart, to: mach_absolute_time()) }

    /// Session time (seconds) of a host time, rounded to the millisecond.
    private func sessionTime(_ hostTime: UInt64) -> Double {
        (max(0, HostTime.elapsed(from: sessionStart, to: hostTime)) * 1000).rounded() / 1000
    }

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

        // System audio first: "Other apps" when any app has its own source. The exclude list is
        // read when the tap is built, so a rebuilt tap still leaves out the split-out apps.
        let sysFactory: (TrackWriter) -> CaptureSource = options.testTone
            ? { TestToneSource(writer: $0, frequency: 440) }
            : { [unowned self] in
                ProcessTapSource(mode: .exclude, prefixes: self.activeAppPrefixes() + self.options.excludeBundles, writer: $0)
            }
        if let sys = makeEntry(id: "sys", kind: options.testTone ? "test" : "system", name: "System audio", bundleID: nil,
                               factory: sysFactory) {
            startSource(sys)
        }
        let micFactory: (TrackWriter) -> CaptureSource = options.testTone
            ? { TestToneSource(writer: $0, frequency: 660, level: 0.15) }
            : { [unowned self] writer in
                let capture = MicCapture(selection: self.micSelection)
                capture.sink = { buffer, hostTime in writer.append(buffer, hostTime: hostTime) }
                capture.onReport = { [weak self] report in self?.handleMicReport(report) }
                return capture
            }
        if options.mic, let micEntry = makeEntry(id: "mic", kind: options.testTone ? "test" : "mic", name: "Microphone",
                                                 bundleID: nil, factory: micFactory) {
            startSource(micEntry)
        }
        for bundleID in options.apps { addApp(bundleID, commandID: nil) }

        installHardwareListener()
        startLevelsTimer()
        startWatchdog()
        saveManifest()
        emitSources()
        if entries.values.allSatisfy({ $0.state != "active" }) {
            fail("no_sources", "No source could be started")
            stop(reason: "error")
        }
    }

    private func makeEntry(id: String, kind: String, name: String, bundleID: String?,
                           factory: @escaping (TrackWriter) -> CaptureSource) -> Entry? {
        let file = "tracks/\(id.replacingOccurrences(of: ":", with: "-")).wav"
        do {
            let writer = try TrackWriter(id: id, url: options.dir.appendingPathComponent(file), sessionStart: sessionStart)
            writer.onWriteError = { message in
                EventWriter.shared.emit("notice", ["level": "error", "code": "write_error", "source": id, "message": message])
            }
            let entry = Entry(id: id, kind: kind, name: name, bundleID: bundleID, writer: writer, factory: factory)
            entries[id] = entry
            order.append(id)
            manifest.tracks.append(.init(id: id, kind: kind, name: name, bundleID: bundleID, file: file))
            return entry
        } catch {
            fail("write_error", "Cannot create the \(name) track: \(error.localizedDescription)", source: id)
            return nil
        }
    }

    /// Start a fresh source for the track. A failure marks only that source lost (the rest keep
    /// recording) and the watchdog keeps retrying it, so granting a permission mid-recording or
    /// plugging a mic back in brings it back.
    private func startSource(_ entry: Entry) {
        let source = entry.factory(entry.writer)
        entry.source = source
        entry.dueSince = nil
        entry.watchFrom = mach_absolute_time() + HostTime.ticks(seconds: Self.startGrace)
        do {
            try source.start()
            entry.state = "active"
        } catch {
            notice("error", Self.failureCode(error), "\(entry.name): \(error)", source: entry.id)
            beginLoss(entry, from: mach_absolute_time())
        }
    }

    private static func failureCode(_ error: Error) -> String {
        if let tap = error as? TapError { return tap.code }
        if let mic = error as? MicCapture.MicError {
            if case .permissionDenied = mic { return "mic_permission_denied" }
            return "mic_failed"
        }
        return "source_failed"
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
            // A device switch pauses the mic for a moment; don't take that for a dead mic.
            entries["mic"]?.watchFrom = mach_absolute_time() + HostTime.ticks(seconds: Self.startGrace)
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
            guard let micEntry = entries["mic"], !options.testTone else { return reject("no_mic", "The microphone isn't being recorded") }
            let spec = command["mic"] as? [String: Any] ?? [:]
            switch spec["mode"] as? String {
            case "auto": micSelection = .avoidBluetooth
            case "default": micSelection = .systemDefault
            case "device":
                guard let uid = spec["uid"] as? String, !uid.isEmpty else { return reject("bad_args", "mic.uid is required") }
                micSelection = .uid(uid)
            default: return reject("bad_args", "mic.mode must be auto, default or device")
            }
            if micEntry.state == "lost" {
                attemptRecovery(micEntry)  // the new choice may be a mic that works
            } else {
                mic?.setSelection(micSelection)
            }
            ack()
        case "add_app":
            guard let bundleID = command["bundle_id"] as? String, !bundleID.isEmpty else { return reject("bad_args", "bundle_id is required") }
            addApp(bundleID, commandID: id)
        case "remove_app":
            guard let bundleID = command["bundle_id"] as? String, let entry = entries["app:\(bundleID)"], entry.state != "removed" else {
                return reject("unknown_source", "That app doesn't have its own source")
            }
            removeApp(entry)
            ack()
        case "ping":
            ack()
        case "debug_fail_source" where options.debugCommands:
            guard let entry = entries[command["source"] as? String ?? ""], entry.state == "active" else {
                return reject("unknown_source", "No such active source")
            }
            entry.failRecoveries = (command["fail_recoveries"] as? NSNumber)?.intValue ?? 0
            entry.source?.simulateFailure()
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
        if let existing = entries[id], existing.state == "lost" {
            attemptRecovery(existing)  // adding it again is a request to retry now
            if let commandID { EventWriter.shared.emit("ack", ["id": commandID]) }
            return
        }
        let name = runningApps().first { $0.bundleID == bundleID }?.name ?? bundleID
        let tone = 330 + Double(order.count) * 110
        let factory: (TrackWriter) -> CaptureSource = options.testTone
            ? { TestToneSource(writer: $0, frequency: tone, level: 0.2) }
            : { ProcessTapSource(mode: .include, prefixes: [bundleID], writer: $0) }
        guard let entry = entries[id] ?? makeEntry(id: id, kind: options.testTone ? "test" : "app", name: name,
                                                   bundleID: bundleID, factory: factory) else {
            return reject("write_error", "Cannot create a track for \(name)")
        }
        // Split order: start the app's own source, then take it out of "Other apps". A few
        // milliseconds of overlap beats a gap. A source that fails to start shows as lost.
        startSource(entry)
        if entry.state == "active" {
            otherApps?.update(prefixes: activeAppPrefixes() + options.excludeBundles)
            renameSystem()
        }
        saveManifest()
        if let commandID { EventWriter.shared.emit("ack", ["id": commandID]) }
        emitSources()
    }

    private func removeApp(_ entry: Entry) {
        // Rejoin order: give the app back to "Other apps" first, then stop its own source.
        if entry.state == "lost" { endGap(entry, at: mach_absolute_time()) }
        entry.state = "removed"
        entry.lostAt = nil
        otherApps?.update(prefixes: activeAppPrefixes() + options.excludeBundles)
        entry.source?.stop()
        entry.source = nil
        renameSystem()
        saveManifest()
        emitSources()
    }

    /// Apps with their own working source. A lost app is left out, so "Other apps" records it
    /// until its own source is back.
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
            for tap in appTaps { tap.update() }
            otherApps?.update()
        }
    }

    private func restartTaps() {
        guard !stopping else { return }
        let grace = mach_absolute_time() + HostTime.ticks(seconds: Self.startGrace)
        for id in order {
            guard let entry = entries[id], entry.state == "active", let tap = entry.source as? ProcessTapSource else { continue }
            entry.watchFrom = grace
            do {
                try tap.restartAggregate()
            } catch {
                markLost(entry, since: mach_absolute_time(), why: ": couldn't re-attach to the new output device (\(error))")
            }
        }
        EventWriter.shared.emit("notice", ["level": "info", "code": "output_device_changed",
                                           "message": "Output device changed; system and app capture re-attached."])
    }

    // MARK: - Watchdog: sources that die mid-session

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkSources() }
        timer.resume()
        watchdog = timer
        // Devices take a moment to come back after sleep.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let grace = mach_absolute_time() + HostTime.ticks(seconds: Self.startGrace + 1)
            for entry in entries.values { entry.watchFrom = max(entry.watchFrom, grace) }
        }
    }

    /// Twice a second: a source whose audio is due but hasn't arrived for `stallLimit` is lost; a
    /// lost source is back on its first buffer, and is rebuilt with backoff (2, 4, 8, 15 s...)
    /// while its audio is due. Its track holds silence for the gap, logged in capture.json.
    private func checkSources() {
        guard !stopping else { return }
        let watched = order.compactMap { entries[$0] }.filter { $0.state == "active" || $0.state == "lost" }
        guard !watched.isEmpty else { return }
        // Only taps need the process list (who is playing); it costs a few HAL calls per process.
        let processes = watched.contains { $0.source is ProcessTapSource } ? audioProcessObjects() : []
        let t = mach_absolute_time()
        for entry in watched {
            let due = entry.source?.isAudioDue(processes) ?? true
            entry.dueSince = due ? (entry.dueSince ?? t) : nil
            let last = entry.writer.lastAppendHostTime
            if entry.state == "active", let tap = entry.source as? ProcessTapSource, let note = tap.checkRate() {
                notice("info", "tap_rate_changed", "\(entry.name): \(note).", source: entry.id)
            }
            if entry.state == "active" {
                guard let dueSince = entry.dueSince else { continue }
                let since = max(dueSince, last, entry.watchFrom)
                if t > since && HostTime.elapsed(from: since, to: t) >= Self.stallLimit {
                    let why = entry.source is ProcessTapSource
                        ? ": nothing recorded for \(Int(Self.stallLimit)) s while audio was playing"
                        : " stopped delivering audio"
                    // The gap starts at the last buffer (or when audio became due), not at the end
                    // of a grace period.
                    markLost(entry, since: max(last, dueSince), why: why)
                }
            } else if let resumed = entry.writer.resumedHostTime {
                markRestored(entry, at: resumed)
            } else if due && t >= entry.nextRetry {
                attemptRecovery(entry)
            }
        }
    }

    /// Bookkeeping for a lost source: state, the gap in capture.json, the retry schedule.
    private func beginLoss(_ entry: Entry, from hostTime: UInt64) {
        let t = mach_absolute_time()
        entry.state = "lost"
        entry.lostAt = t
        entry.writer.armResume()  // its first buffer from here on means it is back
        entry.retryDelay = 2
        entry.nextRetry = t + HostTime.ticks(seconds: entry.retryDelay)
        var gaps = manifest.gaps ?? []
        entry.gapIndex = gaps.count
        gaps.append(.init(source: entry.id, from: sessionTime(hostTime), to: nil))
        manifest.gaps = gaps
    }

    private func endGap(_ entry: Entry, at hostTime: UInt64) {
        if let i = entry.gapIndex, var gaps = manifest.gaps, gaps.indices.contains(i) {
            gaps[i].to = sessionTime(hostTime)
            manifest.gaps = gaps
        }
        entry.gapIndex = nil
    }

    private func markLost(_ entry: Entry, since: UInt64, why: String) {
        beginLoss(entry, from: since)
        var message = "\(entry.name)\(why); reconnecting."
        if entry.kind == "app" { message += " \"Other apps\" records it until then." }
        notice("error", "source_lost", message, source: entry.id)
        saveManifest()
        emitSources()
        attemptRecovery(entry)
        guard entry.kind == "app", let lostAt = entry.lostAt else { return }
        // Usually the rebuilt tap works at once. Give it a moment before handing the app to
        // "Other apps": folding it in first would record it on both tracks until the next check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !stopping, entry.state == "lost", entry.lostAt == lostAt else { return }
            if let resumed = entry.writer.resumedHostTime {
                markRestored(entry, at: resumed)
            } else {
                otherApps?.update(prefixes: activeAppPrefixes() + options.excludeBundles)
                renameSystem()
                saveManifest()
                emitSources()
            }
        }
    }

    private func markRestored(_ entry: Entry, at hostTime: UInt64) {
        let gapStart = entry.gapIndex.flatMap { manifest.gaps?[$0].from }
        endGap(entry, at: hostTime)
        entry.state = "active"
        entry.lostAt = nil
        entry.dueSince = nil
        entry.retryDelay = 2
        var fields: [String: Any] = ["level": "info", "code": "source_restored", "source": entry.id]
        if let gapStart {
            let gap = (max(0, sessionTime(hostTime) - gapStart) * 10).rounded() / 10
            fields["gap"] = gap
            fields["message"] = "\(entry.name) is recording again after \(gap) s of silence."
        } else {
            fields["message"] = "\(entry.name) is recording again."
        }
        EventWriter.shared.emit("notice", fields)
        if entry.kind == "app" {  // split it out of "Other apps" again, now that its own source works
            otherApps?.update(prefixes: activeAppPrefixes() + options.excludeBundles)
            renameSystem()
        }
        saveManifest()
        emitSources()
    }

    /// Throw the old source away and start a fresh one. Success shows up as buffers, which
    /// checkSources() takes as the source being back.
    private func attemptRecovery(_ entry: Entry) {
        let t = mach_absolute_time()
        entry.nextRetry = t + HostTime.ticks(seconds: entry.retryDelay)
        entry.retryDelay = min(entry.retryDelay * 2, Self.maxRetryDelay)
        entry.source?.stop()
        let source = entry.factory(entry.writer)
        entry.source = source
        entry.watchFrom = t
        do {
            if entry.failRecoveries > 0 {
                entry.failRecoveries -= 1
                throw TapError(code: "simulated", description: "simulated failure (debug_fail_source)")
            }
            try source.start()
            fputs("\(entry.id): restarted the source\n", stderr)
        } catch {
            fputs("\(entry.id): restart failed, retrying in \(Int(entry.retryDelay / 2)) s: \(error)\n", stderr)
        }
    }

    // MARK: - Stop

    func stop(reason: String) {
        guard !stopping else { return }
        stopping = true
        EventWriter.shared.emit("stopping", ["reason": reason])
        levelsTimer?.cancel()
        levelsTimer = nil
        watchdog?.cancel()
        watchdog = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        removeHardwareListener()
        for entry in entries.values {
            entry.source?.stop()
            entry.source = nil
        }
        let duration = now
        let frames = AVAudioFramePosition(duration * kTrackSampleRate)
        for entry in entries.values { entry.writer.finish(padTo: frames) }
        manifest.duration = (duration * 1000).rounded() / 1000

        // A source still lost at the end leaves its track silent from the gap on.
        let lostAtEnd = entries.values.contains { $0.state == "lost" }
        var status = hadFailure || lostAtEnd ? "partial" : "ok"
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

    /// An error that makes the session partial whatever happens next (sources have their own state).
    private func fail(_ code: String, _ message: String, source: String? = nil) {
        hadFailure = true
        notice("error", code, message, source: source)
    }

    private func notice(_ level: String, _ code: String, _ message: String, source: String? = nil) {
        var fields: [String: Any] = ["level": level, "code": code, "message": message]
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
        case "--debug-commands": options.debugCommands = true  // tests only; not in the usage text
        case "--debug-tap-rate":  // tests only: start taps at a wrong rate, as a misreporting device would
            guard let rate = Double(value("--debug-tap-rate")), rate > 0 else { fputs("Error: --debug-tap-rate needs Hz\n", stderr); exit(64) }
            ProcessTapSource.debugInitialRate = rate
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
