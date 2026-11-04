import AppKit
import Foundation
import Observation

struct Notice: Identifiable, Equatable {
    var id: String { code + "|" + (source ?? "") }
    let level: String      // info | warning | error
    let code: String
    let message: String
    let source: String?

    var isProblem: Bool { level != "info" }
}

struct MicInfo: Equatable {
    let uid: String
    let name: String
    let transport: String
    let rate: Double
    let reason: String
}

enum MicChoice: Hashable {
    case auto
    case device(String)

    init(pref: String) {
        self = pref.hasPrefix("device:") ? .device(String(pref.dropFirst(7))) : .auto
    }

    var pref: String {
        switch self {
        case .auto: return "auto"
        case let .device(uid): return "device:\(uid)"
        }
    }
}

/// Capture state: the helper process, the mixer strips with their meters, the mic and notices.
@MainActor
@Observable
final class RecorderModel {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    struct Strip: Identifiable, Equatable {
        let id: String
        var kind: String           // system | mic | app | test
        var name: String
        var bundleID: String?
        var gainDb: Double
        var muted: Bool
        var state: String          // active | lost | removed | pending (added before recording)
        var colorIndex: Int
        // Meter state, post-fader, smoothed (dBFS).
        var level = DB.smoothFloor
        var peak = DB.floor
        var peakAt = 0.0
        var readout = -Double.infinity
        var micSilentFor = 0.0

        var isApp: Bool { kind == "app" || bundleID != nil }
    }

    var phase: Phase = .idle
    var strips: [Strip] = []
    var sessionPath: String?
    var elapsed = 0.0
    var micInfo: MicInfo?
    var micChoice = MicChoice(pref: Prefs.string(Prefs.micChoice))
    var notices: [Notice] = []
    var devices: [DeviceInfo] = []
    var apps: [AppInfo] = []
    var appsLoading = false
    var totalReadout = -Double.infinity
    var lastError: String?
    /// Set when the helper died mid-recording: the tracks on disk can still be merged.
    var recoverablePath: String?
    var hasRecorded = false

    @ObservationIgnored let history = LevelHistory()
    @ObservationIgnored var lastLevelsWall = Date.distantPast
    @ObservationIgnored private var helper: HelperConnection?
    @ObservationIgnored private var sawSaved = false
    @ObservationIgnored private var pendingCommands: [Int: (String, String?)] = [:]  // id → (cmd, source)
    @ObservationIgnored private var gainTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastGainSent: [String: Date] = [:]
    @ObservationIgnored private var appColors: [String: Int] = [:]
    @ObservationIgnored private var levelTicks = 0
    @ObservationIgnored private var appliedStoredMix: Set<String> = []

    /// Tool commands from Settings, resolved fresh each time (throws with a readable message).
    @ObservationIgnored var tools: () throws -> (ownscribe: ToolCommand, helper: ToolCommand) = {
        throw NSError(domain: "ownscribe", code: 1)
    }
    @ObservationIgnored var outputDir: () -> String? = { nil }
    /// Called after `saved` with the session path and status (ok | partial | failed).
    @ObservationIgnored var onSaved: ((String, String) -> Void)?
    @ObservationIgnored var onRecordingStarted: (() -> Void)?

    init() {
        strips = Self.idleStrips()
    }

    static func idleStrips() -> [Strip] {
        [
            Strip(id: "sys", kind: "system", name: "System audio", gainDb: Prefs.gain("sys"), muted: Prefs.muted("sys"),
                  state: "active", colorIndex: 0),
            Strip(id: "mic", kind: "mic", name: "Microphone", gainDb: Prefs.gain("mic"), muted: Prefs.muted("mic"),
                  state: "active", colorIndex: 1),
        ]
    }

    var isBusy: Bool { phase != .idle }
    var visibleStrips: [Strip] { strips.filter { $0.state != "removed" } }
    var appStrips: [Strip] { visibleStrips.filter(\.isApp) }

    var now: Double {
        guard phase == .recording || phase == .stopping else { return history.last?.t ?? 0 }
        let since = Date().timeIntervalSince(lastLevelsWall)
        return elapsed + min(max(since, 0), 0.2)
    }

    // MARK: - Recording

    func toggle() {
        switch phase {
        case .idle: Task { await start() }
        case .recording: stop()
        case .starting, .stopping: break
        }
    }

    func start() async {
        guard phase == .idle else { return }
        lastError = nil
        recoverablePath = nil
        notices = []
        let ownscribe: ToolCommand, helperCmd: ToolCommand
        do {
            (ownscribe, helperCmd) = try tools()
        } catch {
            lastError = error.localizedDescription
            return
        }
        phase = .starting
        history.reset()
        elapsed = 0
        sawSaved = false
        appliedStoredMix = []
        pendingCommands = [:]
        totalReadout = -.infinity
        for i in strips.indices {
            strips[i].level = DB.smoothFloor
            strips[i].peak = DB.floor
            strips[i].readout = -.infinity
            strips[i].micSilentFor = 0
        }
        onRecordingStarted?()

        let path: String
        do {
            path = try await Tools.newSession(ownscribe: ownscribe, outputDir: outputDir())
        } catch {
            phase = .idle
            lastError = "Couldn't create a session folder. \(error.localizedDescription)"
            return
        }
        // Stopped (app quit) while the folder was being created: don't start capturing after all.
        guard phase == .starting else {
            phase = .idle
            return
        }
        sessionPath = path
        hasRecorded = true

        let connection = HelperConnection()
        connection.onEvent = { [weak self] e in self?.handle(e) }
        connection.onExit = { [weak self] code in self?.helperExited(code) }
        let mic: HelperConnection.MicArg = {
            if case let .device(uid) = micChoice { return .device(uid) }
            return .auto
        }()
        let apps = strips.filter { $0.state == "pending" }.compactMap(\.bundleID)
        do {
            try connection.start(helper: helperCmd, session: path, mic: mic, apps: apps,
                                 excludeBundle: Bundle.main.bundleIdentifier)
            helper = connection
        } catch {
            phase = .idle
            lastError = "Couldn't start the capture helper. \(error.localizedDescription)"
        }
    }

    func stop() {
        guard phase == .recording || phase == .starting else { return }
        phase = .stopping
        flushGains()
        helper?.send("stop")
        // If the helper doesn't answer (hung), closing stdin is a second, unmissable stop.
        let connection = helper
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if connection === self.helper, self.phase == .stopping { connection?.closeStdin() }
        }
    }

    /// Stops and waits for `saved` (app quit). Calls back on the main queue.
    func stopForQuit(_ done: @escaping () -> Void) {
        guard phase != .idle else { return done() }
        stop()
        Task { @MainActor in
            for _ in 0..<150 where phase != .idle { try? await Task.sleep(for: .milliseconds(100)) }
            done()
        }
    }

    private func helperExited(_ code: Int32) {
        helper = nil
        if !sawSaved {
            let wasCapturing = phase != .idle
            phase = .idle
            if wasCapturing {
                lastError = "The capture helper stopped unexpectedly (exit \(code)). Its log is in ~/Library/Logs/ownscribe/app.log."
                if let sessionPath, FileManager.default.fileExists(atPath: sessionPath + "/capture.json") {
                    recoverablePath = sessionPath
                }
            }
        }
        for i in strips.indices { strips[i].level = DB.smoothFloor; strips[i].readout = -.infinity }
    }

    /// Crash recovery: rebuild recording.wav from the tracks (`ownscribe-audio merge --session`).
    func recover() async {
        guard let path = recoverablePath, let helperCmd = try? tools().helper else { return }
        recoverablePath = nil
        lastError = nil
        phase = .stopping
        let result = await Tools.run(helperCmd, ["merge", "--session", path], timeout: 600)
        phase = .idle
        if case let .success(r) = result, r.exitCode == 0 || r.exitCode == 2 {
            onSaved?(path, r.exitCode == 0 ? "ok" : "partial")
        } else {
            lastError = "Couldn't rebuild the recording from its tracks."
        }
    }

    // MARK: - Events

    private func handle(_ e: JSONObject) {
        guard let ev = e.string("ev") else { return }
        if let t = e.double("t"), phase == .recording || phase == .stopping { elapsed = max(elapsed, t) }
        switch ev {
        case "ready":
            phase = .recording
        case "sources":
            applySources(e.objects("list"))
        case "levels":
            applyLevels(e)
        case "mic":
            micInfo = MicInfo(uid: e.string("uid") ?? "", name: e.string("name") ?? "Microphone",
                              transport: e.string("transport") ?? "", rate: e.double("rate") ?? 0,
                              reason: e.string("reason") ?? "")
            // A new device: earlier mic notices (silent, skipped headset) no longer apply.
            if micInfo?.reason != "auto" { notices.removeAll { $0.source == "mic" && $0.level != "error" } }
        case "notice":
            addNotice(Notice(level: e.string("level") ?? "info", code: e.string("code") ?? "notice",
                             message: e.string("message") ?? "", source: e.string("source")))
        case "ack":
            if let id = e.int("id") { pendingCommands[id] = nil }
        case "error":
            let id = e.int("id")
            let what = id.flatMap { pendingCommands.removeValue(forKey: $0) }
            let message = e.string("message") ?? "The capture helper refused a command"
            addNotice(Notice(level: "warning", code: e.string("code") ?? "error",
                             message: what.map { "\($0.0): \(message)" } ?? message, source: what?.1))
        case "stopping":
            phase = .stopping
        case "saved":
            sawSaved = true
            phase = .idle
            totalReadout = -.infinity
            let status = e.string("status") ?? "failed"
            let path = sessionPath ?? ""
            if status == "failed" || e.string("recording") == nil {
                lastError = "The recording couldn't be saved."
            } else {
                onSaved?(path, status)
            }
        default:
            break
        }
    }

    private func addNotice(_ notice: Notice) {
        if notice.code == "mic_signal_back" {
            notices.removeAll { $0.code == "mic_silent" || $0.code == "mic_builtin_silent_fallback" }
            return
        }
        notices.removeAll { $0.id == notice.id }
        notices.append(notice)
    }

    func dismissNotice(_ notice: Notice) { notices.removeAll { $0.id == notice.id } }

    private func applySources(_ list: [JSONObject]) {
        var next: [Strip] = []
        for src in list {
            guard let id = src.string("id") else { continue }
            let state = src.string("state") ?? "active"
            if state == "removed" { continue }
            let kind = src.string("kind") ?? "app"
            let bundle = src.string("bundle_id")
            if var existing = strips.first(where: { $0.id == id }) {
                existing.kind = kind
                existing.name = src.string("name") ?? existing.name
                existing.state = state
                existing.bundleID = bundle ?? existing.bundleID
                next.append(existing)
            } else {
                let color: Int
                if id == "sys" { color = 0 } else if id == "mic" { color = 1 } else {
                    color = appColors[id] ?? (2 + appColors.count % 3)
                    appColors[id] = color
                }
                next.append(Strip(id: id, kind: kind, name: src.string("name") ?? id, bundleID: bundle,
                                  gainDb: src.double("gain_db") ?? 0, muted: src.bool("muted") ?? false,
                                  state: state, colorIndex: color))
            }
            // The helper starts every source at 0 dB, unmuted: apply what the mixer was set to.
            if !appliedStoredMix.contains(id), let strip = next.last {
                appliedStoredMix.insert(id)
                if abs((src.double("gain_db") ?? 0) - strip.gainDb) > 0.01 { send("set_gain", ["source": id, "db": strip.gainDb], source: id) }
                if (src.bool("muted") ?? false) != strip.muted { send("set_mute", ["source": id, "muted": strip.muted], source: id) }
            }
        }
        // Keep apps added a moment ago that the helper hasn't listed yet.
        for strip in strips where strip.state == "pending" && !next.contains(where: { $0.id == strip.id }) && phase == .starting {
            next.append(strip)
        }
        strips = next
    }

    private func applyLevels(_ e: JSONObject) {
        guard let sources = e.object("sources") else { return }
        let dt = 0.05
        lastLevelsWall = Date()
        let t = e.double("t") ?? elapsed
        levelTicks += 1
        let refreshReadouts = levelTicks % 3 == 0
        var total = 0.0
        var levels: [String: Double] = [:]
        for i in strips.indices {
            let id = strips[i].id
            let raw = sources.object(id)
            let rms = raw?.double("rms") ?? -.infinity
            let peak = raw?.double("peak") ?? -.infinity
            let gain = strips[i].gainDb
            let off = strips[i].muted || gain <= DB.floor || strips[i].state != "active"
            let post = off ? -Double.infinity : rms + gain
            strips[i].level = DB.smooth(strips[i].level, post, dt: dt)
            let postPeak = off ? -Double.infinity : max(peak + gain, strips[i].level)
            if postPeak.isFinite, postPeak >= strips[i].peak {
                strips[i].peak = postPeak
                strips[i].peakAt = t
            } else if t - strips[i].peakAt > 1.5 {
                strips[i].peak = max(DB.floor, strips[i].peak - 15 * dt)
            }
            if strips[i].kind == "mic" {
                strips[i].micSilentFor = (rms.isFinite && rms > -80) ? 0 : strips[i].micSilentFor + dt
            }
            if refreshReadouts { strips[i].readout = strips[i].level }
            levels[id] = strips[i].level
            total += DB.power(strips[i].level > DB.smoothFloor + 0.5 ? strips[i].level : -.infinity)
        }
        let totalDb = DB.fromPower(total)
        history.append(.init(t: t, total: totalDb, levels: levels))
        if refreshReadouts { totalReadout = totalDb }
    }

    // MARK: - Mixer

    @discardableResult
    private func send(_ cmd: String, _ fields: [String: Any], source: String? = nil) -> Int? {
        guard let helper, phase == .recording || phase == .starting else { return nil }
        let id = helper.send(cmd, fields)
        pendingCommands[id] = (cmd, source)
        return id
    }

    /// Fader moves are applied locally at once and sent at most every 80 ms; `final` sends now.
    func setGain(_ id: String, _ db: Double, final: Bool = false) {
        guard let i = strips.firstIndex(where: { $0.id == id }) else { return }
        let value = db <= DB.floor ? DB.floor : min(db, 6)
        strips[i].gainDb = value
        if id == "sys" || id == "mic" { Prefs.setGain(id, value) }
        gainTasks[id]?.cancel()
        let last = lastGainSent[id] ?? .distantPast
        if final || Date().timeIntervalSince(last) > 0.08 {
            lastGainSent[id] = Date()
            send("set_gain", ["source": id, "db": value], source: id)
        } else {
            gainTasks[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, let self else { return }
                self.lastGainSent[id] = Date()
                self.send("set_gain", ["source": id, "db": value], source: id)
            }
        }
    }

    private func flushGains() {
        for (id, task) in gainTasks {
            task.cancel()
            if let strip = strips.first(where: { $0.id == id }) {
                send("set_gain", ["source": id, "db": strip.gainDb], source: id)
            }
        }
        gainTasks = [:]
    }

    func toggleMute(_ id: String) {
        guard let i = strips.firstIndex(where: { $0.id == id }) else { return }
        strips[i].muted.toggle()
        if id == "sys" || id == "mic" { Prefs.setMuted(id, strips[i].muted) }
        send("set_mute", ["source": id, "muted": strips[i].muted], source: id)
    }

    func addApp(_ app: AppInfo) {
        let id = "app:\(app.bundleID)"
        if phase == .recording {
            send("add_app", ["bundle_id": app.bundleID], source: id)
        } else if phase == .idle, !strips.contains(where: { $0.id == id }) {
            let color = appColors[id] ?? (2 + appColors.count % 3)
            appColors[id] = color
            strips.append(Strip(id: id, kind: "app", name: app.name, bundleID: app.bundleID, gainDb: 0,
                                muted: false, state: "pending", colorIndex: color))
        }
    }

    func removeApp(_ strip: Strip) {
        guard let bundle = strip.bundleID else { return }
        if phase == .recording, strip.state != "pending" {
            send("remove_app", ["bundle_id": bundle], source: strip.id)
        } else {
            strips.removeAll { $0.id == strip.id }
        }
    }

    /// After a recording, app strips that were split out stay listed for the next one.
    func resetForIdle() {
        guard phase == .idle else { return }
        var next = Self.idleStrips()
        for strip in strips where strip.isApp && strip.state != "removed" {
            var s = strip
            s.state = "pending"
            s.level = DB.smoothFloor
            s.readout = -.infinity
            next.append(s)
        }
        // Keep the device name on the mic strip.
        if let mic = strips.first(where: { $0.id == "mic" }), let i = next.firstIndex(where: { $0.id == "mic" }) {
            next[i].name = mic.name
        }
        strips = next
    }

    // MARK: - Mic

    func setMic(_ choice: MicChoice) {
        micChoice = choice
        Prefs.defaults.set(choice.pref, forKey: Prefs.micChoice)
        notices.removeAll { $0.source == "mic" }
        switch choice {
        case .auto: send("set_mic", ["mic": ["mode": "auto"]], source: "mic")
        case let .device(uid): send("set_mic", ["mic": ["mode": "device", "uid": uid]], source: "mic")
        }
    }

    var micStrip: Strip? { strips.first { $0.kind == "mic" || $0.id == "mic" } }

    /// The device "Automatic" will use: the default input, unless that's a Bluetooth headset.
    var predictedAutoDevice: DeviceInfo? {
        guard let def = devices.first(where: \.isDefault) else { return devices.first(where: \.isBuiltIn) }
        if def.isBluetooth { return devices.first(where: \.isBuiltIn) ?? def }
        return def
    }

    var skippedBluetoothDefault: DeviceInfo? {
        guard let def = devices.first(where: \.isDefault), def.isBluetooth else { return nil }
        return def
    }

    func refreshDevices() async {
        guard let helperCmd = try? tools().helper else { return }
        let list = await Tools.listDevices(helper: helperCmd)
        if !list.isEmpty { devices = list }
    }

    func refreshApps() async {
        guard let helperCmd = try? tools().helper else { return }
        appsLoading = true
        let own = Bundle.main.bundleIdentifier
        let list = await Tools.listApps(helper: helperCmd)
        apps = list.filter { $0.bundleID != own }.sorted {
            $0.playing != $1.playing ? $0.playing : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        appsLoading = false
    }
}
