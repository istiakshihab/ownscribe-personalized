import AppKit
import Foundation
import Observation

/// Owns the recorder and the pipeline, resolves the tools from Settings and runs `doctor`.
@MainActor
@Observable
final class AppModel {
    let recorder = RecorderModel()
    let pipeline = PipelineModel()
    var doctor: DoctorReport?
    var doctorError: String?
    var checking = false
    var dismissedProblems: Set<String> = []

    init() {
        recorder.tools = { try Self.resolveTools() }
        recorder.outputDir = { [weak self] in self?.outputDirArgument }
        pipeline.ownscribe = { try Self.resolveTools().ownscribe }
        recorder.onRecordingStarted = { [weak self] in
            guard let self, !self.pipeline.isRunning else { return }
            self.pipeline.reset()
        }
        recorder.onSaved = { [weak self] path, _ in
            guard let self else { return }
            self.recorder.resetForIdle()
            self.pipeline.process(session: path)
        }
    }

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
        await refreshDoctor()
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
        if let doctorError { out.append(.init(id: "doctor-error", text: doctorError, kind: .error, action: .settings)) }
        for p in doctor?.problems ?? [] where !dismissedProblems.contains(p.id) {
            out.append(.init(id: "doctor-\(p.id)", text: p.message, kind: p.isWarning ? .warning : .error,
                             action: p.id == "hf_token" ? .huggingFace : .recheck))
        }
        if let e = recorder.lastError {
            out.append(.init(id: "recorder", text: e, kind: .error, action: recorder.recoverablePath != nil ? .recover : .log))
        }
        if let e = pipeline.lastError { out.append(.init(id: "pipeline", text: e, kind: .error, action: .log)) }
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
        if banner.id.hasPrefix("doctor-") { dismissedProblems.insert(String(banner.id.dropFirst(7))) }
        if banner.id == "recorder" { recorder.lastError = nil; recorder.recoverablePath = nil }
        if banner.id == "pipeline" { pipeline.lastError = nil }
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
    enum Kind { case warning, error }
    enum Action: Equatable {
        case settings, huggingFace, recheck, log, recover, dismiss
        case privacy(String)
    }

    let id: String
    let text: String
    let kind: Kind
    let action: Action
}
