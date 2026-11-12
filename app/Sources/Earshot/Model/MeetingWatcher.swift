import Foundation
import Observation

/// Zoom and Teams calls, as the helper's `watch-meetings` reports them (docs/engine-protocol.md,
/// "Meeting watch"). The helper decides when a call starts and ends; this keeps it running while
/// detection is on, restarts it if it dies, and hands the calls to AppModel.
@MainActor
@Observable
final class MeetingWatcher {
    struct Meeting: Equatable, Identifiable {
        let app: String       // "zoom" or "teams"
        let name: String      // "Zoom", "Microsoft Teams"
        let bundleID: String  // the app's main bundle: what a recording taps as its own source
        let started: Date
        var id: String { "\(app)@\(started.timeIntervalSinceReferenceDate)" }
    }

    enum Status: Equatable {
        case off
        case starting
        case watching([String])      // app names
        case unsupported             // the helper predates watch-meetings
        case failed(String)
    }

    /// Calls in progress, oldest first.
    private(set) var meetings: [Meeting] = []
    private(set) var status: Status = .off

    /// The newest call: the one prompts and the menu bar offer to record.
    var current: Meeting? { meetings.last }

    @ObservationIgnored var helper: (() throws -> ToolCommand)?
    @ObservationIgnored var onStarted: ((Meeting) -> Void)?
    @ObservationIgnored var onEnded: ((Meeting, String) -> Void)?

    @ObservationIgnored private var connection: WatchConnection?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var runningCommand: String?
    @ObservationIgnored private var supportChecked: [String: Bool] = [:]
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// After a restart, calls that the new watcher doesn't report again within this long ended
    /// while it was down.
    @ObservationIgnored private var unconfirmed: Set<String> = []
    @ObservationIgnored private var reconcile: Task<Void, Never>?

    private static let backoff: [Double] = [1, 5, 30]

    /// Starts or stops the watcher to match the setting and the helper command (call again after
    /// either changes).
    func update(enabled: Bool) async {
        wanted = enabled
        guard enabled, let helper = try? helper?() else {
            stop()
            status = enabled ? .failed("No capture helper is set up.") : .off
            return
        }
        let command = Prefs.string(Prefs.helperCommand)
        if connection != nil, runningCommand == command { return }
        stop(keepWanted: true)
        if supportChecked[command] == nil {
            status = .starting
            supportChecked[command] = await Self.supportsWatch(helper)
            guard wanted else { return }
        }
        guard supportChecked[command] == true else {
            AppLog.shared.note("meetings", "the capture helper has no watch-meetings; rebuild it with swift/build.sh")
            status = .unsupported
            return
        }
        launch(helper, command: command)
    }

    private func launch(_ helper: ToolCommand, command: String) {
        let c = WatchConnection()
        c.onEvent = { [weak self] e in self?.handle(e) }
        c.onExit = { [weak self, weak c] code in
            guard let self, let c, c === self.connection else { return }
            self.connection = nil
            self.exited(code)
        }
        do {
            try c.start(helper: helper)
            connection = c
            runningCommand = command
            startedAt = Date()
            status = .starting
        } catch {
            status = .failed(error.localizedDescription)
            scheduleRetry()
        }
    }

    func stop(keepWanted: Bool = false) {
        if !keepWanted { wanted = false }
        retry?.cancel()
        retry = nil
        reconcile?.cancel()
        reconcile = nil
        let c = connection
        connection = nil
        runningCommand = nil
        c?.stop()
        // A deliberate stop ends what we were tracking, without auto-stopping anything: the
        // recorder only reacts to calls the helper says have ended.
        meetings = []
        unconfirmed = []
        if !keepWanted { status = .off }
    }

    private func exited(_ code: Int32) {
        guard wanted else { return }
        // Keep the calls: the restarted watcher reports the ones still going, and the rest are
        // ended then (see `reconcile`).
        unconfirmed = Set(meetings.map(\.app))
        if Date().timeIntervalSince(startedAt) > 60 { failures = 0 }
        status = .failed("The call watcher stopped (exit \(code)). Restarting…")
        scheduleRetry()
    }

    private func scheduleRetry() {
        let delay = Self.backoff[min(failures, Self.backoff.count - 1)]
        failures += 1
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.wanted, self.connection == nil,
                  let helper = try? self.helper?() else { return }
            self.launch(helper, command: Prefs.string(Prefs.helperCommand))
        }
    }

    private func handle(_ e: JSONObject) {
        switch e.string("ev") {
        case "watch_ready":
            status = .watching(e.objects("apps").compactMap { $0.string("name") })
            if !unconfirmed.isEmpty {
                // Wait longer than the helper's start debounce for still-running calls to come back.
                reconcile?.cancel()
                reconcile = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard let self, !Task.isCancelled else { return }
                    for app in self.unconfirmed { self.end(app: app, reason: "watcher_restarted") }
                    self.unconfirmed = []
                }
            }
        case "meeting_started":
            guard let app = e.string("app") else { return }
            unconfirmed.remove(app)
            guard !meetings.contains(where: { $0.app == app }) else { return }
            let meeting = Meeting(app: app, name: e.string("name") ?? app.capitalized,
                                  bundleID: e.string("bundle_id") ?? "", started: Date())
            meetings.append(meeting)
            AppLog.shared.note("meetings", "\(meeting.name) call started")
            onStarted?(meeting)
        case "meeting_ended":
            guard let app = e.string("app") else { return }
            end(app: app, reason: e.string("reason") ?? "audio_stopped")
        default:
            break
        }
    }

    private func end(app: String, reason: String) {
        guard let i = meetings.firstIndex(where: { $0.app == app }) else { return }
        let meeting = meetings.remove(at: i)
        AppLog.shared.note("meetings", "\(meeting.name) call ended (\(reason))")
        onEnded?(meeting, reason)
    }

    /// Helpers older than 2.3.0 don't have the command; their usage text says so.
    private static func supportsWatch(_ helper: ToolCommand) async -> Bool {
        guard case let .success(r) = await Tools.run(helper, ["--help"], timeout: 10) else { return false }
        return (String(decoding: r.stdout, as: UTF8.self) + r.stderr).contains("watch-meetings")
    }
}
