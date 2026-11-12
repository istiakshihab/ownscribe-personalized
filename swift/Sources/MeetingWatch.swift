import CoreAudio
import Foundation

/// `watch-meetings --control stdio`: a long-running watcher that reports when a Zoom or Teams call
/// starts and ends, judged from Core Audio's per-process running flags (no TCC permission needed).
///
/// A call starts once one of the app's processes has had audio input running for `startAfter`
/// seconds without a break. It ends when none of them has had input or output running for
/// `endAfter` seconds (`audio_stopped`), or at once when the app has no process object left at all
/// (`app_quit`). Zoom's main process stays in the process list while idle, so an idle Zoom is not
/// a quit.
///
/// Everything here runs on the main queue: the poll timer, commands and stop.
final class MeetingWatcher {
    struct Options {
        var interval: Double = 1
        var startAfter: Double = 3
        var endAfter: Double = 20
        /// Use a fake process table driven by `debug_process` commands instead of Core Audio (tests only).
        var debugCommands = false
    }

    struct App {
        let id: String
        let name: String
        /// The app's main bundle, reported in every event whichever of its processes matched.
        let bundleID: String
        let exact: [String]
        let prefixes: [String]

        func matches(_ bundleID: String) -> Bool {
            exact.contains(bundleID) || prefixes.contains { bundleID.hasPrefix($0) }
        }

        var descriptor: [String: Any] { ["app": id, "name": name, "bundle_id": bundleID] }
    }

    static let apps: [App] = [
        App(id: "zoom", name: "Zoom", bundleID: "us.zoom.xos",
            exact: ["us.zoom.xos"], prefixes: ["us.zoom."]),
        App(id: "teams", name: "Microsoft Teams", bundleID: "com.microsoft.teams2",
            exact: ["com.microsoft.teams2", "com.microsoft.teams"],
            prefixes: ["com.microsoft.teams2.", "com.microsoft.teams."]),
    ]

    static func app(for bundleID: String) -> App? {
        bundleID.isEmpty ? nil : apps.first { $0.matches(bundleID) }
    }

    private struct AppState {
        /// Idle: since when each process's input has been running without a break (host time).
        var inputSince: [pid_t: UInt64] = [:]
        /// Active: when meeting_started was emitted.
        var activeSince: UInt64?
        /// Active: the last poll that saw any of the app's processes with input or output running.
        var lastAudio: UInt64 = 0
    }

    private let options: Options
    private let watchStart = mach_absolute_time()
    private var states: [String: AppState] = [:]
    private var timer: DispatchSourceTimer?
    private let coreAudio = AudioProcessCache()
    /// `--debug-commands`: the fake process table, by pid.
    private var fakeProcesses: [pid_t: AudioProcessInfo] = [:]

    init(options: Options) {
        self.options = options
    }

    func start() {
        EventWriter.shared.enable(sessionStart: watchStart)
        EventWriter.shared.emit("watch_ready", ["v": kHelperVersion, "apps": Self.apps.map(\.descriptor)])
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: options.interval, leeway: .milliseconds(max(1, Int(options.interval * 100))))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() -> Never {
        timer?.cancel()
        EventWriter.shared.flush()
        exit(0)
    }

    // MARK: - Commands

    func handle(_ command: [String: Any]) {
        let id = command["id"]
        let cmd = command["cmd"] as? String ?? ""
        func ack() { if let id { EventWriter.shared.emit("ack", ["id": id]) } }
        func reject(_ code: String, _ message: String) {
            EventWriter.shared.emit("error", ["id": id ?? NSNull(), "code": code, "message": message])
        }

        switch cmd {
        case "ping":
            ack()
        case "debug_process" where options.debugCommands:
            guard let bundleID = command["bundle_id"] as? String, !bundleID.isEmpty,
                  let pid = (command["pid"] as? NSNumber)?.int32Value else {
                return reject("bad_args", "bundle_id and pid are required")
            }
            if command["gone"] as? Bool == true {
                fakeProcesses[pid] = nil
            } else {
                fakeProcesses[pid] = AudioProcessInfo(object: AudioObjectID(bitPattern: pid), pid: pid, bundleID: bundleID,
                                                      isPlaying: command["output"] as? Bool ?? false,
                                                      isRecording: command["input"] as? Bool ?? false)
            }
            ack()
            poll()  // judge the change from the moment it happened, not the next tick
        case "stop":
            ack()
            stop()
        default:
            reject("unknown_command", "Unknown cmd \(cmd)")
        }
    }

    // MARK: - Polling

    private func poll() {
        let now = mach_absolute_time()
        var byApp: [String: [AudioProcessInfo]] = [:]
        let processes = options.debugCommands
            ? Array(fakeProcesses.values)
            : coreAudio.processes { Self.app(for: $0) != nil }
        for p in processes {
            if let app = Self.app(for: p.bundleID) { byApp[app.id, default: []].append(p) }
        }
        for app in Self.apps {
            update(app, processes: byApp[app.id] ?? [], now: now)
        }
    }

    private func update(_ app: App, processes: [AudioProcessInfo], now: UInt64) {
        var state = states[app.id] ?? AppState()
        defer { states[app.id] = state }

        if let started = state.activeSince {
            if processes.isEmpty {
                end(app, reason: "app_quit", started: started, now: now)
                state = AppState()
            } else if processes.contains(where: { $0.isRecording || $0.isPlaying }) {
                state.lastAudio = now
            } else if HostTime.elapsed(from: state.lastAudio, to: now) >= options.endAfter {
                end(app, reason: "audio_stopped", started: started, now: now)
                state = AppState()
            }
            return
        }

        // Idle: a process whose input stopped, even briefly, starts its debounce over.
        var since: [pid_t: UInt64] = [:]
        for p in processes where p.isRecording { since[p.pid] = state.inputSince[p.pid] ?? now }
        state.inputSince = since
        guard let earliest = since.min(by: { $0.value < $1.value }),
              HostTime.elapsed(from: earliest.value, to: now) >= options.startAfter else { return }
        state = AppState(activeSince: now, lastAudio: now)
        var fields = app.descriptor
        fields["pid"] = Int(earliest.key)
        EventWriter.shared.emit("meeting_started", fields)
    }

    private func end(_ app: App, reason: String, started: UInt64, now: UInt64) {
        var fields = app.descriptor
        fields["reason"] = reason
        fields["duration"] = (HostTime.elapsed(from: started, to: now) * 1000).rounded() / 1000
        EventWriter.shared.emit("meeting_ended", fields)
    }
}

/// Core Audio's process objects with their bundle IDs and pids cached per AudioObjectID. Those are
/// re-read only when the process object list changes; the running flags are read on every call, and
/// only for the processes the caller asks about.
final class AudioProcessCache {
    private var ids: [AudioObjectID] = []
    private var identity: [AudioObjectID: (pid: pid_t, bundleID: String)] = [:]

    func processes(where wanted: (String) -> Bool) -> [AudioProcessInfo] {
        refreshIfNeeded()
        return ids.compactMap { id in
            guard let known = identity[id], wanted(known.bundleID) else { return nil }
            return AudioProcessInfo(object: id, pid: known.pid, bundleID: known.bundleID,
                                    isPlaying: (audioProperty(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0,
                                    isRecording: (audioProperty(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0)
        }
    }

    private func refreshIfNeeded() {
        let current = Self.processObjectIDs()
        guard current != ids else { return }
        ids = current
        identity = Dictionary(uniqueKeysWithValues: current.map { id in
            (id, (pid: audioProperty(id, kAudioProcessPropertyPID, pid_t(0)) ?? 0,
                  bundleID: audioStringProperty(id, kAudioProcessPropertyBundleID) ?? ""))
        })
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).sorted()
    }
}

// MARK: - Entry point for `watch-meetings`

func runMeetingWatch(_ args: [String]) -> Never {
    var options = MeetingWatcher.Options()
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
    func seconds(_ flag: String, allowZero: Bool) -> Double {
        guard let s = Double(value(flag)), s.isFinite, allowZero ? s >= 0 : s > 0 else {
            fputs("Error: \(flag) needs a number of seconds\(allowZero ? "" : " above zero")\n", stderr)
            exit(64)
        }
        return s
    }
    while i < args.count {
        switch args[i] {
        case "--control":
            guard value("--control") == "stdio" else { fputs("Error: only --control stdio is supported\n", stderr); exit(64) }
            control = true
        case "--interval": options.interval = seconds("--interval", allowZero: false)
        case "--start-after": options.startAfter = seconds("--start-after", allowZero: true)
        case "--end-after": options.endAfter = seconds("--end-after", allowZero: true)
        case "--debug-commands": options.debugCommands = true  // tests only; not in the usage text
        default:
            fputs("Unknown option for watch-meetings: \(args[i])\n", stderr)
            exit(64)
        }
        i += 1
    }
    guard control else { fputs("Error: watch-meetings is driven over --control stdio\n", stderr); exit(64) }

    // The client reads stdout through a pipe; if it goes away, writes fail with EPIPE instead of
    // killing us, and stdin EOF ends the watcher.
    signal(SIGPIPE, SIG_IGN)
    // Polls must keep their pace while the app is in the background; idle sleep is still allowed.
    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "ownscribe is watching for calls")
    _ = activity

    let watcher = MeetingWatcher(options: options)
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { watcher.stop() }
        source.resume()
        watchSignalSources.append(source)
    }
    watcher.start()

    // Commands from stdin on their own thread, run on the main queue one at a time. EOF (the client
    // quit or crashed) ends the watcher.
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
            DispatchQueue.main.async { watcher.handle(object) }
        }
        DispatchQueue.main.async { watcher.stop() }
    }
    dispatchMain()
}

/// Retains the signal sources for the process lifetime.
private var watchSignalSources: [DispatchSourceSignal] = []
