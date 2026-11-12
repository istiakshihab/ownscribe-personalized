import AppKit
import Foundation
import Observation

/// Owns the recorder, the pipeline and the history of past recordings, resolves the tools from
/// Settings and runs `doctor`.
@MainActor
@Observable
final class AppModel {
    let recorder = RecorderModel()
    /// The recording made in this window: what the recorder view shows under the mixer.
    let pipeline = PipelineModel()
    let history = HistoryModel()
    /// Zoom and Teams calls (the helper's `watch-meetings`).
    let meetings = MeetingWatcher()
    /// The call you answered "Not now" for: no more prompts until it ends.
    var dismissedMeeting: String?
    /// Opens (or brings back) the main window; set by a view that has `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    var doctor: DoctorReport? {
        didSet {
            for p in [pipeline] + Array(openPipelines.values) { p.vaultSettings = doctor?.vault }
        }
    }

    /// What the window shows: the recorder, or a past recording picked in the sidebar.
    enum Selection: Hashable {
        case recorder
        case session(String)  // HistoryItem.id
    }

    var selection: Selection = .recorder {
        didSet { if case let .session(id) = selection { openSession(id) } }
    }
    var sidebarVisible = Prefs.defaults.object(forKey: Prefs.sidebarVisible) as? Bool ?? true {
        didSet { Prefs.defaults.set(sidebarVisible, forKey: Prefs.sidebarVisible) }
    }
    /// Past recordings opened from the sidebar, by session id; kept while their jobs run.
    private(set) var openPipelines: [String: PipelineModel] = [:]
    var doctorError: String?
    var checking = false
    var dismissedProblems: Set<String> = []

    init() {
        recorder.tools = { try Self.resolveTools() }
        recorder.outputDir = { [weak self] in self?.outputDirArgument }
        pipeline.ownscribe = { try Self.resolveTools().ownscribe }
        pipeline.onJobFinished = { [weak self] in self?.refreshHistory() }
        recorder.onRecordingStarted = { [weak self] in
            guard let self else { return }
            selection = .recorder  // a new recording always shows the recorder
            CallPrompt.shared.close()
            if !pipeline.isRunning { pipeline.reset() }
            refreshHistory()
        }
        recorder.onSaved = { [weak self] path, _ in
            guard let self else { return }
            self.recorder.resetForIdle()
            if self.pipeline.isRunning {
                // A call recorded while the last one was still processing: process it on its own,
                // and keep it reachable from the sidebar.
                let p = self.makePipeline()
                p.process(session: path)
                if let id = p.sessionID { self.openPipelines[id] = p }
            } else {
                self.pipeline.process(session: path)
            }
            self.refreshHistory()
        }

        meetings.helper = { try Self.resolveTools().helper }
        meetings.onStarted = { [weak self] m in self?.meetingStarted(m) }
        meetings.onEnded = { [weak self] m, reason in self?.meetingEnded(m, reason: reason) }
        Notifier.shared.onOpen = { [weak self] in self?.showMainWindow() }
    }

    // MARK: - Calls

    /// Starts or stops call detection to match Settings (and the helper command).
    func updateMeetingWatcher() async {
        let on = Prefs.bool(Prefs.detectMeetings)
        if on { Notifier.shared.setUp() }
        await meetings.update(enabled: on)
    }

    /// The call to offer recording for: detected, not dismissed, and nothing recording yet.
    var promptedMeeting: MeetingWatcher.Meeting? {
        guard let m = meetings.current, m.id != dismissedMeeting, recorder.phase == .idle else { return nil }
        return m
    }

    private func meetingStarted(_ m: MeetingWatcher.Meeting) {
        // Already recording (you started it): system audio has the call in it already.
        guard recorder.phase == .idle else { return }
        if Prefs.bool(Prefs.meetingAutoStart) {
            recordMeeting(m)
        } else {
            CallPrompt.shared.show(m.name, record: { [weak self] in self?.recordMeeting(m) },
                                   notNow: { [weak self] in self?.dismissMeeting() })
        }
    }

    private func meetingEnded(_ m: MeetingWatcher.Meeting, reason: String) {
        if dismissedMeeting == m.id { dismissedMeeting = nil }
        CallPrompt.shared.close()
        guard recorder.origin == .meeting(m.app), recorder.phase == .recording || recorder.phase == .starting,
              Prefs.bool(Prefs.meetingAutoStop) else { return }
        recorder.stop()
        Notifier.shared.meetingEnded(m.name)
    }

    /// Records the detected call: mic and system audio as always, plus the meeting app as its own
    /// source. Allowed while the last recording is still processing (calls come back to back).
    func recordMeeting(_ meeting: MeetingWatcher.Meeting? = nil) {
        guard let m = meeting ?? meetings.current, recorder.phase == .idle else { return }
        dismissedMeeting = nil
        if !m.bundleID.isEmpty { recorder.addApp(AppInfo(bundleID: m.bundleID, name: m.name, playing: true)) }
        CallPrompt.shared.close()
        if Prefs.bool(Prefs.meetingAutoStart) { Notifier.shared.recordingStarted(m.name) }
        Task { await recorder.start(origin: .meeting(m.app)) }
    }

    func dismissMeeting() {
        dismissedMeeting = meetings.current?.id
        CallPrompt.shared.close()
    }

    func showMainWindow() {
        NSApp.activate()
        openMainWindow?()
    }

    /// The menu bar's first line.
    var menuStatus: String {
        switch recorder.phase {
        case .starting: return "Starting…"
        case .stopping: return "Saving audio…"
        case .recording:
            let time = TimerLabel.format(recorder.elapsed)
            if case let .meeting(app) = recorder.origin, let m = meetings.meetings.first(where: { $0.app == app }) {
                return "Recording \(m.name) call · \(time)"
            }
            return "Recording · \(time)"
        case .idle:
            if let m = promptedMeeting { return "\(m.name) call in progress" }
            if pipeline.isProcessing { return "Processing the last recording…" }
            return "Not recording"
        }
    }

    // MARK: - History

    func refreshHistory() { history.refresh(folder: outputDir) }

    /// The pipeline showing a past recording: this window's own when it's the same session.
    func pipeline(for id: String) -> PipelineModel? {
        if pipeline.sessionID == id { return pipeline }
        return openPipelines[id]
    }

    var selectedItem: HistoryItem? {
        if case let .session(id) = selection { return history.item(id) }
        return nil
    }

    /// Load a past recording from disk. One that is idle is read again, so it shows what's there now.
    private func openSession(_ id: String) {
        guard pipeline.sessionID != id, let item = history.item(id) else { return }
        if let open = openPipelines[id], open.isRunning { return }
        let p = openPipelines[id] ?? makePipeline()
        p.open(item)
        openPipelines[id] = p
        // Only keep pipelines that are busy, besides the one on screen.
        for (key, other) in openPipelines where key != id && !other.isRunning { openPipelines[key] = nil }
    }

    private func makePipeline() -> PipelineModel {
        let p = PipelineModel()
        p.ownscribe = { try Self.resolveTools().ownscribe }
        p.templates = pipeline.templates
        p.vaultSettings = doctor?.vault
        p.onJobFinished = { [weak self] in self?.refreshHistory() }
        return p
    }

    /// Process a past recording that never got through (or rerun it).
    func process(_ item: HistoryItem) {
        guard let p = pipeline(for: item.id), !p.isRunning else { return }
        p.process(session: item.path)
    }

    func trash(_ item: HistoryItem) async {
        if selectedItem?.id == item.id { selection = .recorder }
        openPipelines[item.id] = nil
        do { try await history.trash(item) } catch {
            historyError = "Couldn't move “\(item.title)” to the Trash: \(error.localizedDescription)"
        }
    }

    var historyError: String?

    static func resolveTools() throws -> (ownscribe: ToolCommand, helper: ToolCommand) {
        let o: ToolCommand, h: ToolCommand
        do { o = try ToolCommand(parsing: Prefs.string(Prefs.ownscribeCommand)) } catch {
            throw NSError(domain: "ownscribe", code: 2, userInfo: [NSLocalizedDescriptionKey: "ownscribe command: \(error.localizedDescription). Check Settings."])
        }
        do { h = try ToolCommand(parsing: Prefs.string(Prefs.helperCommand)) } catch {
            throw NSError(domain: "ownscribe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Capture helper: \(error.localizedDescription). Build it with `bash swift/build.sh` or check Settings."])
        }
        return (o, h)
    }

    /// Default save folder, as ownscribe's doctor reports it ([output] dir).
    var defaultOutputDir: String { doctor?.outputDir ?? (NSHomeDirectory() + "/ownscribe") }

    var outputDir: String {
        let chosen = Prefs.string(Prefs.outputDir)
        return chosen.isEmpty ? defaultOutputDir : chosen
    }

    /// `--output-dir` only when the user picked a folder; otherwise ownscribe's own setting applies.
    private var outputDirArgument: String? {
        let chosen = Prefs.string(Prefs.outputDir)
        return chosen.isEmpty ? nil : chosen
    }

    func launch() async {
        await updateMeetingWatcher()
        await refreshDoctor()
        refreshHistory()
        await recorder.refreshDevices()
        if let tool = try? Self.resolveTools().ownscribe {
            let names = await Tools.templates(ownscribe: tool)
            if !names.isEmpty { pipeline.templates = names }
        }
    }

    func refreshDoctor() async {
        checking = true
        defer { checking = false }
        doctorError = nil
        let tools: (ownscribe: ToolCommand, helper: ToolCommand)
        do { tools = try Self.resolveTools() } catch {
            doctor = nil
            doctorError = error.localizedDescription
            return
        }
        switch await Tools.doctor(ownscribe: tools.ownscribe) {
        case let .success(report):
            doctor = report
        case let .failure(error):
            doctor = nil
            doctorError = "Can't run `ownscribe doctor`: \(error.localizedDescription) Check the ownscribe command in Settings."
        }
    }

    /// Problems to show under the title bar: setup (doctor), recorder and pipeline errors, helper notices.
    var banners: [Banner] {
        var out: [Banner] = []
        if let m = promptedMeeting {
            out.append(.init(id: "meeting", text: "\(m.name) call started. Record it?", kind: .info, action: .recordMeeting))
        }
        if let doctorError { out.append(.init(id: "doctor-error", text: doctorError, kind: .error, action: .settings)) }
        for p in doctor?.problems ?? [] where !dismissedProblems.contains(p.id) {
            out.append(.init(id: "doctor-\(p.id)", text: p.message, kind: p.isWarning ? .warning : .error,
                             action: p.id == "hf_token" ? .huggingFace : .recheck))
        }
        if let e = recorder.lastError {
            out.append(.init(id: "recorder", text: e, kind: .error, action: recorder.recoverablePath != nil ? .recover : .log))
        }
        if let e = pipeline.lastError { out.append(.init(id: "pipeline", text: e, kind: .error, action: .log)) }
        if let item = selectedItem, let p = pipeline(for: item.id), p !== pipeline, let e = p.lastError {
            out.append(.init(id: "history-pipeline", text: e, kind: .error, action: .log))
        }
        if let e = historyError { out.append(.init(id: "history", text: e, kind: .error, action: .dismiss)) }
        for n in recorder.notices where n.isProblem && n.source != "mic" {
            let action: Banner.Action = n.code.contains("permission") ? .privacy(n.code) : .dismiss
            out.append(.init(id: "notice-\(n.id)", text: n.message, kind: n.level == "error" ? .error : .warning, action: action))
        }
        for n in recorder.notices where n.isProblem && n.source == "mic" && n.code == "mic_permission_denied" {
            out.append(.init(id: "notice-\(n.id)", text: n.message, kind: .error, action: .privacy(n.code)))
        }
        // Other mic notices show on the strip; a mic that died mid-recording is worth a banner.
        for n in recorder.notices where n.source == "mic" && n.code == "source_lost" {
            out.append(.init(id: "notice-\(n.id)", text: n.message, kind: .error, action: .dismiss))
        }
        return out
    }

    func dismiss(_ banner: Banner) {
        if banner.id == "meeting" { dismissMeeting() }
        if banner.id.hasPrefix("doctor-") { dismissedProblems.insert(String(banner.id.dropFirst(7))) }
        if banner.id == "recorder" { recorder.lastError = nil; recorder.recoverablePath = nil }
        if banner.id == "pipeline" { pipeline.lastError = nil }
        if banner.id == "history-pipeline", let item = selectedItem { pipeline(for: item.id)?.lastError = nil }
        if banner.id == "history" { historyError = nil }
        if banner.id.hasPrefix("notice-"), let n = recorder.notices.first(where: { "notice-\($0.id)" == banner.id }) {
            recorder.dismissNotice(n)
        }
    }

    /// The window subtitle.
    var statusLine: String {
        switch recorder.phase {
        case .starting: return "Starting…"
        case .stopping: return "Saving audio…"
        case .recording: return "Recording · " + sourcesSummary
        case .idle:
            if let activity = pipeline.activity { return activity }
            if pipeline.hasRun, let path = pipeline.sessionPath {
                let failed = [pipeline.transcription, pipeline.diarization, pipeline.summarization]
                    .contains { $0.status == .failed || $0.status == .cancelled }
                return (failed ? "Finished with problems · " : "Done · saved to ") + path.abbreviatingHome
            }
            return "Ready · " + sourcesSummary
        }
    }

    private var sourcesSummary: String {
        let apps = recorder.appStrips.map(\.name)
        return (["mic", "system audio"] + apps).joined(separator: " + ")
    }
}

struct Banner: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    enum Action: Equatable {
        case settings, huggingFace, recheck, log, recover, dismiss, recordMeeting
        case privacy(String)
    }

    let id: String
    let text: String
    let kind: Kind
    let action: Action
}
