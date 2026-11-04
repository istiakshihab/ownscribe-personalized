import Foundation

/// Results of one-shot commands (listings, `session new`, `doctor`, `templates`).
struct RunResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: String

    var json: JSONObject? { JSONObject(line: stdout) }
    var stderrTail: String {
        let lines = stderr.split(separator: "\n").suffix(4)
        return lines.joined(separator: "\n")
    }
}

struct AppInfo: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let playing: Bool
    var id: String { bundleID }

    /// Safari plays audio through the shared WebKit GPU process, which a per-app tap can't single out.
    var canSplit: Bool { !bundleID.hasPrefix("com.apple.Safari") }
}

struct DeviceInfo: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    let transport: String
    let sampleRate: Double
    let isDefault: Bool
    var id: String { uid }

    var isBluetooth: Bool { transport.localizedCaseInsensitiveContains("bluetooth") }
    var isVirtual: Bool { transport.localizedCaseInsensitiveContains("virtual") || transport == "aggregate" }
    var isBuiltIn: Bool { transport.localizedCaseInsensitiveContains("built") }

    var transportLabel: String { Self.transportLabel(transport) }

    static func transportLabel(_ transport: String) -> String {
        switch transport.lowercased() {
        case "built-in": return "Built-in"
        case "bluetooth", "bluetooth le": return "Bluetooth"
        case "usb": return "USB"
        case "virtual": return "Virtual device"
        default: return transport.capitalized
        }
    }

    static func rateLabel(_ rate: Double) -> String {
        rate <= 0 ? "" : (rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000))
    }
}

struct DoctorReport: Sendable {
    struct Problem: Identifiable, Hashable, Sendable {
        let id: String
        let message: String
        let isWarning: Bool
    }

    var problems: [Problem]
    var outputDir: String?
    var whisperModel: String?
    var whisperCached = true
    /// `[summarization] backend` and model, e.g. ("claude", "sonnet") or ("local", "phi-4-mini").
    var summarizerBackend: String?
    var summarizerModel: String?

    /// For the Summarization card.
    var summarizerLabel: String? {
        switch summarizerBackend {
        case nil: return nil
        case "claude": return "Claude \((summarizerModel ?? "sonnet").capitalized) · claude CLI"
        case "local": return "\(summarizerModel ?? "Local model") · on this Mac"
        case let backend?: return "\(summarizerModel ?? backend) · \(backend)"
        }
    }
}

enum Tools {
    /// Runs a command to completion and collects its output.
    static func run(_ command: ToolCommand, _ args: [String], timeout: TimeInterval = 120) async -> Result<RunResult, Error> {
        final class Box: @unchecked Sendable {
            var out = Data()
            var err = Data()
            let lock = NSLock()
        }
        let box = Box()
        return await withCheckedContinuation { cont in
            do {
                let child = try ChildProcess(
                    executable: command.executable,
                    arguments: command.arguments(args),
                    environment: ToolCommand.environment,
                    directory: NSHomeDirectory(),
                    onStdoutLine: { line in box.lock.lock(); box.out.append(line); box.out.append(0x0A); box.lock.unlock() },
                    onStderr: { chunk in box.lock.lock(); box.err.append(chunk); box.lock.unlock() },
                    onExit: { code in
                        box.lock.lock()
                        let result = RunResult(exitCode: code, stdout: box.out, stderr: String(decoding: box.err, as: UTF8.self))
                        box.lock.unlock()
                        cont.resume(returning: .success(result))
                    }
                )
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { child.signal(SIGTERM, group: true) }
            } catch {
                cont.resume(returning: .failure(error))
            }
        }
    }

    static func listApps(helper: ToolCommand) async -> [AppInfo] {
        guard case let .success(r) = await run(helper, ["list-apps", "--json"], timeout: 15), let json = r.json else { return [] }
        return json.objects("apps").compactMap { app in
            guard let id = app.string("bundle_id") else { return nil }
            return AppInfo(bundleID: id, name: app.string("name") ?? id, playing: app.bool("playing") ?? false)
        }
    }

    static func listDevices(helper: ToolCommand) async -> [DeviceInfo] {
        guard case let .success(r) = await run(helper, ["list-devices", "--json"], timeout: 15), let json = r.json else { return [] }
        return json.objects("devices").compactMap { d in
            guard let uid = d.string("uid") else { return nil }
            return DeviceInfo(uid: uid, name: d.string("name") ?? uid, transport: d.string("transport") ?? "",
                              sampleRate: d.double("sample_rate") ?? 0, isDefault: d.bool("default") ?? false)
        }
    }

    /// `ownscribe session new --json` → the new session folder.
    static func newSession(ownscribe: ToolCommand, outputDir: String?) async throws -> String {
        var args = ["session", "new", "--json"]
        if let outputDir, !outputDir.isEmpty { args += ["--output-dir", outputDir] }
        switch await run(ownscribe, args, timeout: 120) {
        case let .failure(error):
            throw error
        case let .success(r):
            guard r.exitCode == 0, let path = r.json?.string("path") else {
                throw NSError(domain: "ownscribe", code: Int(r.exitCode), userInfo: [
                    NSLocalizedDescriptionKey: "`ownscribe session new` failed" + (r.stderrTail.isEmpty ? "" : ": \(r.stderrTail)"),
                ])
            }
            return path
        }
    }

    static func templates(ownscribe: ToolCommand) async -> [String] {
        guard case let .success(r) = await run(ownscribe, ["templates", "--json"], timeout: 60), let json = r.json else { return [] }
        return json.objects("templates").compactMap { $0.string("name") }
    }

    /// `ownscribe doctor --json`, turned into the problems worth showing.
    static func doctor(ownscribe: ToolCommand) async -> Result<DoctorReport, Error> {
        switch await run(ownscribe, ["doctor", "--json"], timeout: 120) {
        case let .failure(error):
            return .failure(error)
        case let .success(r):
            guard let json = r.json, let checks = json.object("checks") else {
                return .failure(NSError(domain: "ownscribe", code: Int(r.exitCode), userInfo: [
                    NSLocalizedDescriptionKey: "`ownscribe doctor` gave no report" + (r.stderrTail.isEmpty ? "" : ": \(r.stderrTail)"),
                ]))
            }
            var report = DoctorReport(problems: [])
            func check(_ key: String) -> JSONObject? { checks.object(key) }
            if let c = check("ffmpeg"), c.bool("ok") == false {
                report.problems.append(.init(id: "ffmpeg", message: "ffmpeg is missing, so transcription can't run. Install it with Homebrew or set [paths] ffmpeg in ~/.config/ownscribe/config.toml.", isWarning: false))
            }
            if let c = check("hf_token"), c.bool("ok") == false {
                report.problems.append(.init(id: "hf_token", message: "No Hugging Face token, so diarization will be skipped. Add one in Settings → Hugging Face.", isWarning: true))
            }
            if let c = check("claude"), c.bool("ok") == false, check("summarizer")?.bool("ok") != false {
                report.problems.append(.init(id: "claude", message: "The claude CLI isn't found (needed for vault filing): \(c.string("message") ?? "set [paths] claude").", isWarning: true))
            }
            if let c = check("capture_helper"), c.bool("ok") == false || c.bool("session_mode") == false {
                report.problems.append(.init(id: "capture_helper", message: "ownscribe can't find a capture helper with session mode. Build it with `bash swift/build.sh`.", isWarning: true))
            }
            if let c = check("disk"), c.bool("ok") == false {
                let gb = (c.double("free_bytes") ?? 0) / 1_073_741_824
                report.problems.append(.init(id: "disk", message: String(format: "Only %.1f GB free where recordings are saved.", gb), isWarning: true))
            }
            report.outputDir = check("disk")?.string("path")
            if let w = check("whisper_model") {
                report.whisperModel = w.string("model")
                report.whisperCached = w.bool("cached") ?? true
            }
            if let s = check("summarizer") {
                report.summarizerBackend = s.string("backend")
                report.summarizerModel = s.string("model")
                if s.bool("ok") == false, s.string("backend") == "claude" {
                    report.problems.append(.init(id: "summarizer", message: "Summaries use the claude CLI, which isn't found. Install Claude Code or set [paths] claude in ~/.config/ownscribe/config.toml.", isWarning: true))
                }
            }
            return .success(report)
        }
    }
}
