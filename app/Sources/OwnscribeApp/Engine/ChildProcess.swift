import Darwin
import Foundation

/// A child process started with posix_spawn, with pipes for stdin/stdout/stderr and optionally an
/// extra pipe mapped to fd 3 in the child (job events, docs/engine-protocol.md section 3).
///
/// Foundation's `Process` can't map extra descriptors, hence posix_spawn. Only the mapped
/// descriptors reach the child (POSIX_SPAWN_CLOEXEC_DEFAULT), so concurrent spawns never leak
/// each other's pipe ends, which would keep an event stream open after its writer exits.
///
/// Readers run on background threads and deliver complete lines; `onExit` runs on the main queue
/// after the process has exited *and* every output stream has hit EOF, so no event is lost.
final class ChildProcess: @unchecked Sendable {
    struct Streams {
        var stdin = false
        /// Child descriptor for the events pipe (3), or nil for none.
        var eventsFD: Int32?
    }

    enum SpawnError: LocalizedError {
        case notFound(String)
        case failed(String, Int32)

        var errorDescription: String? {
            switch self {
            case let .notFound(path): return "Can't find \(path)"
            case let .failed(path, code): return "Can't start \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    let pid: pid_t
    let executable: String
    private var stdinFD: Int32
    private let writeQueue = DispatchQueue(label: "ownscribe.child.stdin")
    private let lock = NSLock()
    private var reaped = false

    /// False once the process has been reaped (its pid may then belong to someone else).
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !reaped }

    /// Launches `executable` with `arguments`. Line handlers run on background threads.
    init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String? = nil,
        streams: Streams = Streams(),
        onStdoutLine: (@Sendable (Data) -> Void)? = nil,
        onEventLine: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw SpawnError.notFound(executable) }
        self.executable = executable

        func makePipe() -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            pipe(&fds)
            return (fds[0], fds[1])
        }
        let inPipe = streams.stdin ? makePipe() : nil
        let outPipe = makePipe()
        let errPipe = makePipe()
        let evPipe = streams.eventsFD != nil ? makePipe() : nil

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let inPipe {
            posix_spawn_file_actions_adddup2(&actions, inPipe.read, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe.write, 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe.write, 2)
        if let evPipe, let fd = streams.eventsFD {
            posix_spawn_file_actions_adddup2(&actions, evPipe.write, fd)
        }
        if let directory {
            posix_spawn_file_actions_addchdir(&actions, directory)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group: a Ctrl-C in the terminal that launched the app doesn't reach jobs.
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGCHLD] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attr, &noMask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &actions, &attr, argv, envp)

        // The child's ends belong to the child now.
        if let inPipe { close(inPipe.read) }
        close(outPipe.write)
        close(errPipe.write)
        if let evPipe { close(evPipe.write) }

        guard rc == 0 else {
            if let inPipe { close(inPipe.write) }
            close(outPipe.read)
            close(errPipe.read)
            if let evPipe { close(evPipe.read) }
            throw SpawnError.failed(executable, rc)
        }
        pid = child
        stdinFD = inPipe?.write ?? -1

        let group = DispatchGroup()
        Self.readLines(outPipe.read, group: group, handler: onStdoutLine)
        Self.readChunks(errPipe.read, group: group, handler: onStderr)
        if let evPipe { Self.readLines(evPipe.read, group: group, handler: onEventLine) }

        group.enter()
        let pidCopy = child
        let statusBox = StatusBox()
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(pidCopy, &status, 0) == -1 && errno == EINTR {}
            statusBox.value = Self.exitCode(status)
            if let self { self.lock.lock(); self.reaped = true; self.lock.unlock() }
            group.leave()
        }
        group.notify(queue: .main) { onExit(statusBox.value) }
    }

    private final class StatusBox: @unchecked Sendable { var value: Int32 = -1 }

    /// Exit status as a shell would report it: the code, or 128 + signal.
    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func readLines(_ fd: Int32, group: DispatchGroup, handler: (@Sendable (Data) -> Void)?) {
        group.enter()
        Thread.detachNewThread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    if !line.isEmpty { handler?(Data(line)) }
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            if !pending.isEmpty { handler?(pending) }
            close(fd)
            group.leave()
        }
    }

    private static func readChunks(_ fd: Int32, group: DispatchGroup, handler: (@Sendable (Data) -> Void)?) {
        group.enter()
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                handler?(Data(buffer[0..<n]))
            }
            close(fd)
            group.leave()
        }
    }

    /// Writes one line to the child's stdin (off the main thread; a stuck child can't block the UI).
    func writeLine(_ line: String) {
        let data = Data((line + "\n").utf8)
        writeQueue.async { [self] in
            lock.lock()
            let fd = stdinFD
            lock.unlock()
            guard fd >= 0 else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return }  // EPIPE: the child is gone (SIGPIPE is ignored app-wide)
                    offset += n
                }
            }
        }
    }

    /// Closes stdin; the capture helper treats this as `stop`.
    func closeStdin() {
        writeQueue.async { [self] in
            lock.lock()
            if stdinFD >= 0 { close(stdinFD) }
            stdinFD = -1
            lock.unlock()
        }
    }

    func signal(_ sig: Int32, group: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped else { return }
        _ = group ? killpg(pid, sig) : kill(pid, sig)
    }
}
