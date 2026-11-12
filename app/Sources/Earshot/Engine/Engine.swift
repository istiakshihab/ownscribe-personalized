import Foundation

/// The capture helper in session mode (`ownscribe-audio capture --session DIR --control stdio`):
/// commands go to its stdin, events come back on stdout, stderr goes to the log.
@MainActor
final class HelperConnection {
    enum MicArg: Equatable {
        case auto
        case device(String)
    }

    private var child: ChildProcess?
    private var nextID = 0
    var onEvent: ((JSONObject) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { child?.isRunning ?? false }

    func start(helper: ToolCommand, session: String, mic: MicArg, apps: [String], excludeBundle: String?) throws {
        var args = ["capture", "--session", session, "--control", "stdio", "--mic"]
        switch mic {
        case .auto: args.append("--mic-auto")
        case let .device(uid): args += ["--mic-device", uid]
        }
        for app in apps { args += ["--app", app] }
        if let excludeBundle { args += ["--exclude-bundle", excludeBundle] }
        AppLog.shared.note("helper", "start: \(helper.executable) \(helper.arguments(args).joined(separator: " "))")

        child = try ChildProcess(
            executable: helper.executable,
            arguments: helper.arguments(args),
            environment: ToolCommand.environment,
            directory: NSHomeDirectory(),
            streams: .init(stdin: true),
            onStdoutLine: { [weak self] line in
                guard let event = JSONObject(line: line) else {
                    AppLog.shared.write("helper-stdout", line + Data([0x0A]))
                    return
                }
                DispatchQueue.main.async { self?.onEvent?(event) }
            },
            onStderr: { chunk in AppLog.shared.write("helper", chunk) },
            onExit: { [weak self] code in
                MainActor.assumeIsolated {
                    AppLog.shared.note("helper", "exited with \(code)")
                    self?.child = nil
                    self?.onExit?(code)
                }
            }
        )
    }

    /// Sends a command; returns its id (acked or answered with `error`).
    @discardableResult
    func send(_ cmd: String, _ fields: [String: Any] = [:]) -> Int {
        nextID += 1
        var object = fields
        object["cmd"] = cmd
        object["id"] = nextID
        child?.writeLine(JSONLine.encode(object))
        return nextID
    }

    /// Closing stdin is a stop the helper can't miss, even if a `stop` line was lost.
    func closeStdin() { child?.closeStdin() }

    func terminate() { child?.signal(SIGTERM) }
}

/// The helper's call watcher (`ownscribe-audio watch-meetings --control stdio`): events on stdout,
/// `stop` on stdin. Closing stdin also stops it, so it never outlives the app.
@MainActor
final class WatchConnection {
    private var child: ChildProcess?
    var onEvent: ((JSONObject) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { child?.isRunning ?? false }

    func start(helper: ToolCommand) throws {
        let args = ["watch-meetings", "--control", "stdio"]
        AppLog.shared.note("meetings", "start: \(helper.executable) \(helper.arguments(args).joined(separator: " "))")
        child = try ChildProcess(
            executable: helper.executable,
            arguments: helper.arguments(args),
            environment: ToolCommand.environment,
            directory: NSHomeDirectory(),
            streams: .init(stdin: true),
            onStdoutLine: { [weak self] line in
                guard let event = JSONObject(line: line) else {
                    AppLog.shared.write("meetings-stdout", line + Data([0x0A]))
                    return
                }
                DispatchQueue.main.async { self?.onEvent?(event) }
            },
            onStderr: { chunk in AppLog.shared.write("meetings", chunk) },
            onExit: { [weak self] code in
                MainActor.assumeIsolated {
                    AppLog.shared.note("meetings", "exited with \(code)")
                    self?.child = nil
                    self?.onExit?(code)
                }
            }
        )
    }

    func stop() {
        child?.writeLine(JSONLine.encode(["cmd": "stop"]))
        child?.closeStdin()
    }
}

/// One `ownscribe <command> SESSION --events-fd 3` job. Events arrive on fd 3; stdout (the `--json`
/// result, unused here) is logged with stderr. Cancel is SIGTERM to the direct child only: `uv run`
/// forwards it to Python, so signalling the whole group would deliver it twice. The job then
/// reports `cancelled` and exits 130.
@MainActor
final class JobProcess {
    let command: String
    private var child: ChildProcess?
    private var stderrTail = ""
    var onEvent: ((JSONObject) -> Void)?
    /// Exit code and the last lines of stderr.
    var onExit: ((Int32, String) -> Void)?

    init(command: String) { self.command = command }

    func start(ownscribe: ToolCommand, args: [String]) throws {
        let full = [command] + args + ["--events-fd", "3"]
        AppLog.shared.note(command, "start: \(ownscribe.executable) \(ownscribe.arguments(full).joined(separator: " "))")
        let tail = TailBuffer()
        child = try ChildProcess(
            executable: ownscribe.executable,
            arguments: ownscribe.arguments(full),
            environment: ToolCommand.environment,
            directory: NSHomeDirectory(),
            streams: .init(stdin: false, eventsFD: 3),
            onStdoutLine: { [command] line in AppLog.shared.write("\(command)-out", line + Data([0x0A])) },
            onEventLine: { [weak self] line in
                guard let event = JSONObject(line: line) else { return }
                DispatchQueue.main.async { self?.onEvent?(event) }
            },
            onStderr: { [command] chunk in
                tail.append(chunk)
                AppLog.shared.write(command, chunk)
            },
            onExit: { [weak self, command] code in
                MainActor.assumeIsolated {
                    AppLog.shared.note(command, "exited with \(code)")
                    self?.child = nil
                    self?.onExit?(code, tail.text)
                }
            }
        )
    }

    var isRunning: Bool { child?.isRunning ?? false }

    func cancel() { child?.signal(SIGTERM) }
}

/// Keeps the last few KB of a stream for error messages.
final class TailBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > 8192 { data = data.suffix(8192) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        // Skip progress-bar noise; keep the last real lines.
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(3).joined(separator: "\n")
    }
}
