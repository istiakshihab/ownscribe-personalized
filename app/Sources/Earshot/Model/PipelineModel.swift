import Foundation
import Observation

/// After-recording processing: one `ownscribe` job at a time (process, speakers, resummarize, file),
/// its stage progress, the transcript, speaker names, the summary and the Obsidian note.
@MainActor
@Observable
final class PipelineModel {
    enum Status: Equatable {
        case waiting, running, done, failed, skipped, cancelled
    }

    struct Stage: Equatable {
        var status: Status = .waiting
        var fraction: Double?
        var detail: String?
        var message: String?
    }

    struct Segment: Identifiable, Equatable {
        let id: Int
        let start: Double
        let end: Double
        let text: String
        let speaker: String?
    }

    struct Summary: Equatable {
        var title: String?
        var text: String       // as the job rendered it (current names)
        var raw: String?       // summary.raw.md, with SPEAKER_XX labels, for live renaming
        var template: String?
    }

    static let diarizationSteps = ["segmentation", "speaker_counting", "embeddings", "clustering"]
    static let stepTitles = [
        "segmentation": "Segmentation", "speaker_counting": "Speaker counting",
        "embeddings": "Embeddings", "clustering": "Clustering",
    ]

    var sessionPath: String?
    var hasRun = false
    var transcription = Stage()
    var diarization = Stage()
    var summarization = Stage()
    var substeps: [String: Stage] = [:]
    var preparingModels = false
    var downloadFraction: Double?
    var segments: [Segment] = []
    var diarized = false
    var labels: [String] = []
    var names: [String: String] = [:]
    var drafts: [String: String] = [:]
    var roles: [String: String] = [:]
    var summary: Summary?
    var summaryUnseen = false
    var lastError: String?
    var jobCommand: String?
    var templates = ["meeting", "lecture", "brief"]

    // Obsidian vault filing (`ownscribe file`): draft the note, review it unless [obsidian] says not to, write it.
    var vaultSettings: VaultSettings?
    var vault = Stage()
    var vaultDraft: VaultDraft?
    var vaultNote: VaultNote?
    var reviewingVault = false

    var diarizeOn = Prefs.bool(Prefs.diarize) { didSet { Prefs.defaults.set(diarizeOn, forKey: Prefs.diarize) } }
    var summarizeOn = Prefs.bool(Prefs.summarize) { didSet { Prefs.defaults.set(summarizeOn, forKey: Prefs.summarize) } }
    var template = Prefs.string(Prefs.template) { didSet { Prefs.defaults.set(template, forKey: Prefs.template) } }

    @ObservationIgnored var ownscribe: () throws -> ToolCommand = { throw NSError(domain: "ownscribe", code: 1) }
    @ObservationIgnored private var job: JobProcess?
    @ObservationIgnored private var sawError = false
    @ObservationIgnored private var renameTask: Task<Void, Never>?
    @ObservationIgnored private var renamePending = false
    @ObservationIgnored private var templatePending: String?
    @ObservationIgnored private var segmentCounter = 0
    private enum VaultNext { case review, write }
    /// What to do when the running draft comes back.
    @ObservationIgnored private var vaultNext: VaultNext?
    /// A draft that waits for the running job.
    @ObservationIgnored private var vaultPending: VaultNext?
    /// What the last `process` run actually did (for "Off" vs "Waits").
    var ranDiarize = true
    var ranSummarize = true

    var isRunning: Bool { jobCommand != nil }
    var isProcessing: Bool { jobCommand == "process" }

    // MARK: - Commands

    func reset() {
        renameTask?.cancel()
        renamePending = false
        templatePending = nil
        sessionPath = nil
        hasRun = false
        transcription = Stage()
        diarization = Stage()
        summarization = Stage()
        substeps = [:]
        preparingModels = false
        downloadFraction = nil
        segments = []
        diarized = false
        labels = []
        names = [:]
        drafts = [:]
        roles = [:]
        summary = nil
        summaryUnseen = false
        lastError = nil
        vault = Stage()
        vaultDraft = nil
        vaultNote = nil
        reviewingVault = false
        vaultNext = nil
        vaultPending = nil
    }

    func process(session: String) {
        reset()
        sessionPath = session
        hasRun = true
        ranDiarize = diarizeOn
        ranSummarize = summarizeOn
        if !diarizeOn { diarization.status = .skipped }
        if !summarizeOn { summarization.status = .skipped }
        var args = [session, "--template", template]
        args.append(diarizeOn ? "--diarize" : "--no-diarize")
        args.append(summarizeOn ? "--summarize" : "--no-summarize")
        run("process", args)
    }

    func cancel() { job?.cancel() }

    private func run(_ command: String, _ args: [String]) {
        let tool: ToolCommand
        do { tool = try ownscribe() } catch {
            lastError = error.localizedDescription
            return
        }
        let job = JobProcess(command: command)
        job.onEvent = { [weak self] e in self?.handle(e, command: command) }
        job.onExit = { [weak self] code, tail in self?.finished(command, code: code, stderr: tail) }
        do {
            try job.start(ownscribe: tool, args: args)
            self.job = job
            jobCommand = command
            sawError = false
            lastError = nil
        } catch {
            lastError = "Couldn't start `ownscribe \(command)`. \(error.localizedDescription)"
        }
    }

    private func finished(_ command: String, code: Int32, stderr: String) {
        job = nil
        jobCommand = nil
        if command == "file" {
            finishedFiling(code: code, stderr: stderr)
        } else {
            finishedProcessing(command, code: code, stderr: stderr)
        }
        // Work that waited for this job.
        guard !isRunning else { return }
        if let next = templatePending {
            templatePending = nil
            if next != summary?.template { resummarize(next) }
        } else if renamePending {
            renamePending = false
            commitNames()
        } else if let next = vaultPending {
            vaultPending = nil
            startDraft(then: next)
        }
    }

    private func finishedProcessing(_ command: String, code: Int32, stderr: String) {
        switch code {
        case 0, 2:
            for stage in [\PipelineModel.transcription, \.diarization, \.summarization] where self[keyPath: stage].status == .running {
                self[keyPath: stage].status = .done
            }
        case 130, 143:
            markRunning(.cancelled, message: "Cancelled")
        default:
            markRunning(.failed, message: nil)
            // Nothing after a failed stage ran, whatever the progress display last said.
            if diarization.status == .done && labels.isEmpty && ranDiarize {
                diarization.status = .failed
                diarization.message = diarization.message ?? "Didn't finish"
            }
            if summarization.status == .waiting && ranSummarize {
                summarization.status = .cancelled
                summarization.message = "Didn't run"
            }
            if !sawError {
                lastError = "`ownscribe \(command)` failed (exit \(code))" + (stderr.isEmpty ? "." : ": \(stderr)")
            }
        }
        preparingModels = false
        downloadFraction = nil
        loadRawSummary()
        // With confirm_before_filing = false, file right away like the terminal pipeline does.
        if command == "process", code == 0 || code == 2, canDraft, !vaultOff, vaultSettings?.asks == false {
            vaultPending = .write
            vault = Stage(status: .running, detail: "Drafting the note…")
        }
    }

    private func markRunning(_ status: Status, message: String?) {
        for stage in [\PipelineModel.transcription, \.diarization, \.summarization] where self[keyPath: stage].status == .running {
            self[keyPath: stage].status = status
            if let message { self[keyPath: stage].message = message }
        }
        for (k, v) in substeps where v.status == .running { substeps[k]?.status = status }
    }

    /// Template switch: before processing it's just remembered; afterwards it summarizes again.
    func selectTemplate(_ name: String) {
        template = name
        guard hasRun, summary != nil || summarization.status == .failed, sessionPath != nil else { return }
        if isRunning {
            templatePending = name
        } else if name != summary?.template {
            resummarize(name)
        }
    }

    private func resummarize(_ name: String) {
        guard let path = sessionPath else { return }
        summarization = Stage(status: .running, detail: "Summarizing again as \(name.capitalized)…")
        run("resummarize", [path, "--template", name])
    }

    // MARK: - Obsidian vault

    /// There's a transcript to file.
    var canDraft: Bool { hasRun && sessionPath != nil && transcription.status == .done && !segments.isEmpty }
    var vaultOff: Bool { !(vaultSettings?.enabled ?? false) || !(vaultSettings?.exists ?? false) }

    private var hasUncommittedNames: Bool {
        labels.contains { label in
            drafts[label].map { $0.trimmingCharacters(in: .whitespaces) != (names[label] ?? "") } ?? false
        }
    }

    /// "File to Obsidian…": draft the note (again if the speaker names changed since), then review it.
    func fileToVault() {
        guard canDraft, !vaultOff, vaultNote == nil, vault.status != .running else { return }
        if let draft = vaultDraft, draft.names == names, !hasUncommittedNames {
            reviewingVault = true
            return
        }
        if hasUncommittedNames { commitNames() }  // the note should have them
        if isRunning {
            vaultPending = .review
            vault = Stage(status: .running, detail: "Drafting the note after this step…")
        } else {
            startDraft(then: .review)
        }
    }

    private func startDraft(then next: VaultNext) {
        guard let path = sessionPath else { return }
        vaultNext = next
        vault = Stage(status: .running, detail: "Drafting the note…")
        run("file", [path, "--preview"])
        if job == nil { vault = Stage(status: .failed, message: lastError ?? "Couldn't start ownscribe file") }
    }

    /// Write the (edited) draft into the vault.
    func writeVault(_ draft: VaultDraft) {
        guard let path = sessionPath, !isRunning else { return }
        reviewingVault = false
        vaultDraft = draft
        let edits: [String: Any] = [
            "title": draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            "category": draft.category,
            "tags": draft.tagList,
            "body_markdown": draft.body,
        ]
        let url = URL(fileURLWithPath: path).appendingPathComponent("vault-edits.json")
        do {
            try JSONSerialization.data(withJSONObject: edits, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        } catch {
            vault = Stage(status: .failed, message: "Couldn't save the edits: \(error.localizedDescription)")
            return
        }
        vaultNext = nil
        vault = Stage(status: .running, detail: "Filing the note…")
        run("file", [path, "--write", "--edits", url.path])
        if job == nil { vault = Stage(status: .failed, message: lastError ?? "Couldn't start ownscribe file") }
    }

    /// "Don't File": keep the draft, so it can still be filed later.
    func skipVault() {
        reviewingVault = false
        vault = Stage(status: .skipped)
    }

    private func finishedFiling(code: Int32, stderr: String) {
        let next = vaultNext
        vaultNext = nil
        switch code {
        case 0:
            if vaultNote != nil {
                vault = Stage(status: .done)
            } else if let draft = vaultDraft {
                if next == .write {
                    writeVault(draft)
                } else {
                    vault = Stage(status: .waiting)
                    reviewingVault = true
                }
            } else {
                vault = Stage(status: .failed, message: "ownscribe file returned no draft")
            }
        case 130, 143:
            vault = Stage(status: .cancelled, message: "Cancelled")
        default:
            if vault.status != .failed {
                vault = Stage(status: .failed, message: "Filing failed" + (stderr.isEmpty ? "" : ": \(stderr)"))
            }
        }
    }

    var vaultFoot: String {
        guard let settings = vaultSettings else { return "Checking the vault…" }
        if !settings.enabled { return "Off · [obsidian] enabled = false" }
        if !settings.exists { return "Vault not found: \(settings.dir.abbreviatingHome)" }
        if let note = vaultNote {
            let folder = note.folder(in: settings.dir)
            if vaultDraft.map({ $0.names != names }) == true { return "Filed to \(folder) · before the speakers were renamed" }
            return note.needsReview ? "Filed to \(folder) · needs review" : "Filed to \(folder)"
        }
        switch vault.status {
        case .running: return vault.detail ?? "Working…"
        case .failed: return vault.message ?? "Filing failed"
        case .cancelled: return vault.message ?? "Cancelled"
        case .skipped: return "Not filed"
        case .waiting, .done:
            if vaultDraft != nil { return "Draft ready to review" }
            if canDraft { return settings.asks ? "Name the speakers, then file the note" : "Ready to file" }
            return settings.asks ? "Waits for the transcript, then asks" : "Files when the transcript is ready"
        }
    }

    // MARK: - Speakers

    func displayName(_ label: String) -> String {
        if let draft = drafts[label]?.trimmingCharacters(in: .whitespaces), !draft.isEmpty { return draft }
        if drafts[label] != nil { return label }
        return names[label] ?? label
    }

    func setDraft(_ label: String, _ text: String) {
        drafts[label] = text
        renameTask?.cancel()
        renameTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.commitNames()
        }
    }

    /// Sends changed names with `ownscribe speakers SESSION --set LABEL=NAME…` (after any running job).
    func commitNames() {
        renameTask?.cancel()
        let changes = labels.compactMap { label -> String? in
            guard let draft = drafts[label] else { return nil }
            let name = draft.trimmingCharacters(in: .whitespaces)
            return name == (names[label] ?? "") ? nil : "\(label)=\(name)"
        }
        guard !changes.isEmpty, let path = sessionPath else { return }
        if isRunning {
            renamePending = true
            return
        }
        run("speakers", [path] + changes.flatMap { ["--set", $0] })
    }

    // MARK: - Events

    private func handle(_ e: JSONObject, command: String) {
        guard let ev = e.string("ev") else { return }
        switch ev {
        case "stage":
            applyStage(e)
        case "segment":
            segmentCounter += 1
            segments.append(Segment(id: segmentCounter, start: e.double("start") ?? 0, end: e.double("end") ?? 0,
                                    text: (e.string("text") ?? "").trimmingCharacters(in: .whitespaces), speaker: nil))
        case "transcript":
            let list = e.objects("segments")
            segments = list.enumerated().map { i, s in
                Segment(id: segmentCounter + i + 1, start: s.double("start") ?? 0, end: s.double("end") ?? 0,
                        text: (s.string("text") ?? "").trimmingCharacters(in: .whitespaces), speaker: s.string("speaker"))
            }
            segmentCounter += list.count
            let speakers = e.strings("speakers")
            if !speakers.isEmpty {
                labels = speakers
                diarized = true
            }
        case "speakers":
            labels = e.strings("labels")
            diarized = diarized || !labels.isEmpty
            names = e.stringMap("names")
            let suggested = e.stringMap("roles")
            if !suggested.isEmpty { roles = suggested }
            // Drafts that the backend now has are settled; keep ones typed meanwhile.
            for (label, draft) in drafts where draft.trimmingCharacters(in: .whitespaces) == (names[label] ?? "") {
                drafts[label] = nil
            }
        case "summary":
            let text = e.string("text") ?? ""
            summary = Summary(title: e.string("title") ?? summary?.title, text: text, raw: nil,
                              template: e.string("template") ?? summary?.template)
            if command != "speakers" { summaryUnseen = true }
            summarization.status = .done
            summarization.message = nil
        case "vault_preview":
            let category = e.string("category") ?? ""
            vaultDraft = VaultDraft(
                title: e.string("title") ?? "", category: category, tags: e.strings("tags").joined(separator: ", "),
                body: e.string("body_markdown") ?? "", date: e.string("date") ?? "",
                folders: e.stringMap("folders"), fallback: e.string("fallback_folder") ?? "Meetings Inbox",
                vaultDir: e.string("vault_dir") ?? vaultSettings?.dir ?? "", names: names,
                earlierNote: e.object("filed")?.string("path"), originalCategory: category)
            // The config may have changed since the last doctor check: confirm_before_filing wins.
            if vaultNext == .write, e.bool("confirm") == true { vaultNext = .review }
        case "vault_note":
            vaultNote = VaultNote(path: e.string("path") ?? "", needsReview: e.bool("needs_review") ?? false)
        case "session_moved":
            if let to = e.string("to") { sessionPath = to }
        case "error":
            sawError = true
            let message = e.string("message") ?? e.string("code") ?? "Error"
            let friendly = Self.friendly(code: e.string("code"), message: message)
            // Diarization runs inside the transcriber, so a pyannote failure arrives as a transcription
            // error, and the transcript isn't saved either. Say where it really failed.
            if e.string("stage") == "transcription", Self.isDiarizationProblem(message) {
                diarization.status = .failed
                diarization.message = friendly
                transcription.status = .failed
                transcription.message = "Not saved: diarization failed. Turn Diarization off to get a transcript without speakers."
                return
            }
            switch e.string("stage") {
            case "transcription":
                transcription.status = .failed; transcription.message = friendly
            case "diarization":
                diarization.status = .failed; diarization.message = friendly
            case "summarization":
                summarization.status = .failed; summarization.message = friendly
            case "vault":
                vault = Stage(status: .failed, message: friendly)
            default:
                lastError = friendly
            }
        case "job":
            if e.string("status") == "done", let s = e.string("session") { sessionPath = s }
        default:
            break
        }
    }

    private func applyStage(_ e: JSONObject) {
        guard let name = e.string("stage") else { return }
        let status: Status = switch e.string("status") {
        case "done": .done
        case "failed": .failed
        case "skipped": .skipped
        default: .running
        }
        let fraction = e.double("fraction")
        let detail = e.string("detail")
        switch name {
        case "preparing_models":
            preparingModels = status == .running
            if status == .running, transcription.status == .waiting { transcription.status = .running }
        case "transcribing":
            preparingModels = false
            transcription.status = status
            transcription.fraction = status == .done ? 1 : fraction ?? transcription.fraction
            transcription.detail = detail
        case "diarizing":
            diarization.status = status
            diarization.detail = detail
        case _ where Self.diarizationSteps.contains(name):
            substeps[name] = Stage(status: status, fraction: fraction, detail: detail)
            if diarization.status == .waiting { diarization.status = .running }
        case "summarizing":
            summarization.status = status
            summarization.detail = detail
        case "downloading_model":
            downloadFraction = status == .running ? (fraction ?? 0) : nil
            if status == .running, summarization.status == .waiting { summarization.status = .running }
        default:
            break
        }
    }

    private func loadRawSummary() {
        guard summary != nil, let path = sessionPath else { return }
        let url = URL(fileURLWithPath: path).appendingPathComponent("summary.raw.md")
        summary?.raw = try? String(contentsOf: url, encoding: .utf8)
    }

    /// The summary as shown: the raw text with the names typed so far, else the job's text.
    var renderedSummary: String? {
        guard let summary else { return nil }
        guard let raw = summary.raw else { return summary.text }
        var text = raw
        for label in labels.sorted(by: { $0.count > $1.count }) {
            let name = displayName(label)
            if name != label { text = text.replacingOccurrences(of: label, with: name) }
        }
        return text
    }

    static func isDiarizationProblem(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("pyannote") || m.contains("gated repo") || m.contains("diariz")
    }

    static func friendly(code: String?, message: String) -> String {
        if message.contains("gated repo") || message.contains("403 Client Error") {
            let model = message.firstMatch(of: #/huggingface\.co/([\w.-]+/[\w.-]+)/#).map { String($0.1) } ?? "the pyannote model"
            return "Your Hugging Face token can't download \(model). Accept the model's terms at huggingface.co/\(model), then try again."
        }
        switch code {
        case "hf_token_missing": return "Needs a Hugging Face token ([diarization] hf_token)"
        case "ffmpeg_missing": return "ffmpeg is missing"
        case "audio_silent": return "The recording is silent"
        case "audio_missing": return "No recording.wav in the session"
        case "summarizer_unavailable": return "Summarizer unavailable: \(message)"
        default: return message
        }
    }

    // MARK: - Labels for the stage cards

    var transcriptionFoot: String {
        switch transcription.status {
        case .waiting: return "Waits for the recording"
        case .running:
            if preparingModels { return "Preparing models…" }
            return transcription.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "Starting…"
        case .done: return "Done · \(segments.count) segment\(segments.count == 1 ? "" : "s")"
        case .failed: return transcription.message ?? "Failed"
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        }
    }

    var diarizationOff: Bool { hasRun ? (!ranDiarize && diarization.status == .skipped) : !diarizeOn }
    var summarizationOff: Bool { hasRun ? (!ranSummarize && summarization.status == .skipped) : !summarizeOn }

    var diarizationFoot: String {
        if diarizationOff { return "Off · transcript without speakers" }
        switch diarization.status {
        case .waiting: return "Waits for the transcript"
        case .running: return "Finding who spoke when…"
        case .done:
            let n = labels.count
            return "Done · \(n) speaker\(n == 1 ? "" : "s")"
        case .failed: return diarization.message ?? "Failed"
        case .skipped: return "Skipped"
        case .cancelled: return diarization.message ?? "Cancelled"
        }
    }

    var summarizationFoot: String {
        if summarizationOff { return "Off" }
        switch summarization.status {
        case .waiting: return "Waits for the transcript"
        case .running:
            if let f = downloadFraction { return "Downloading model · \(Int((f * 100).rounded()))%" }
            return summarization.detail ?? "Summarizing…"
        case .done:
            let t = (summary?.template ?? template).capitalized
            return "Done · \(t) summary"
        case .failed: return summarization.message ?? "Failed"
        case .skipped: return "Skipped"
        case .cancelled: return summarization.message ?? "Cancelled"
        }
    }

    /// One line for the window subtitle while a job runs.
    var activity: String? {
        guard isRunning else { return nil }
        switch jobCommand {
        case "speakers": return "Renaming speakers…"
        case "resummarize": return "Summarizing again…"
        case "file": return vaultNext == nil ? "Filing to Obsidian…" : "Drafting the Obsidian note…"
        default:
            if summarization.status == .running { return "Summarizing…" }
            if diarization.status == .running { return "Finding speakers…" }
            if preparingModels { return "Preparing models…" }
            return "Transcribing…"
        }
    }

    var savedFiles: [String] {
        guard hasRun else { return [] }
        var files = ["recording.wav"]
        if !segments.isEmpty { files.append("transcript.md") }
        if summary != nil { files.append("summary.md") }
        return files
    }
}
