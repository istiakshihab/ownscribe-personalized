import AppKit
import SwiftUI

/// After recording: Transcription → Diarization → Summarization → Obsidian in a column, the
/// transcript and summary beside it.
struct PipelinePanel: View {
    let app: AppModel
    /// This window's recording, or a past one opened from the sidebar.
    let pipeline: PipelineModel
    /// Shown on the right while nothing runs.
    var hint = "Runs on this Mac when you press Stop"
    @ViewState private var tab = Tab.transcript

    /// Room for the widest card's title beside its switch (Summarization) and the template picker.
    static let stagesWidth: CGFloat = 214

    enum Tab: Hashable { case transcript, summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                PanelTitle(text: "After recording")
                Spacer()
                if pipeline.isRunning {
                    Button("Cancel", role: .cancel) { pipeline.cancel() }
                        .controlSize(.small)
                } else {
                    Text(hint).font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                // The stages, top to bottom, each at its natural height.
                VStack(spacing: 8) {
                    transcriptionCard
                    diarizationCard
                    summarizationCard
                    vaultCard
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.stagesWidth)
                results
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panel()
        .sheet(isPresented: Binding(get: { pipeline.reviewingVault }, set: { pipeline.reviewingVault = $0 })) {
            if let draft = pipeline.vaultDraft {
                VaultReviewSheet(pipeline: pipeline, draft: draft)
            }
        }
        .onChange(of: tab) { _, new in if new == .summary { pipeline.summaryUnseen = false } }
        .onChange(of: pipeline.summaryUnseen) { _, unseen in if unseen && tab == .summary { pipeline.summaryUnseen = false } }
    }

    // MARK: Stage cards

    private var transcriptionCard: some View {
        // No switch and no label: the title needs the width in a narrow window, and it always runs.
        StageCard(title: "Transcription", status: pipeline.transcription.status, off: false, accessory: {
            EmptyView()
        }) {
            Text(whisperLabel).font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1).help(whisperLabel)
            ProgressBar(fraction: pipeline.preparingModels ? nil : (pipeline.transcription.status == .done ? 1 : pipeline.transcription.fraction ?? 0),
                        indeterminate: pipeline.preparingModels)
                .accessibilityLabel("Transcription progress")
            Text(pipeline.transcriptionFoot).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(2).help(pipeline.transcriptionFoot).monospacedDigit()
        }
    }

    private var diarizationCard: some View {
        @Bindable var p = pipeline
        return StageCard(title: "Diarization", status: pipeline.diarization.status, off: pipeline.diarizationOff, accessory: {
            Toggle("Diarization", isOn: $p.diarizeOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(pipeline.isProcessing)
        }) {
            Text("pyannote · then you name speakers").font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1)
                .help("pyannote finds who spoke when; then you name the speakers")
                .opacity(pipeline.diarizationOff ? 0.45 : 1)
            // The four sub-steps only while they run; afterwards the line below says how it went.
            if pipeline.diarization.status == .running {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(PipelineModel.diarizationSteps, id: \.self) { step in
                    HStack(spacing: 8) {
                        StatusIcon(status: pipeline.substeps[step]?.status ?? .waiting, size: 14)
                        Text(PipelineModel.stepTitles[step] ?? step)
                        if let f = pipeline.substeps[step]?.fraction, pipeline.substeps[step]?.status == .running {
                            Text("\(Int(f * 100))%").foregroundStyle(Theme.ink3).monospacedDigit()
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
            }
            .opacity(pipeline.diarizationOff ? 0.45 : 1)
            }
            Text(pipeline.diarizationFoot).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(2).help(pipeline.diarizationFoot)
            if pipeline.diarization.status == .failed, pipeline.diarization.message?.contains("Hugging Face") == true {
                HuggingFaceSettingsButton()
            }
        }
    }

    private var summarizationCard: some View {
        @Bindable var p = pipeline
        return StageCard(title: "Summarization", status: pipeline.summarization.status, off: pipeline.summarizationOff, accessory: {
            Toggle("Summarization", isOn: $p.summarizeOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(pipeline.isProcessing)
        }) {
            Text(app.doctor?.summarizerLabel ?? "Your summary template").font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1)
                .opacity(pipeline.summarizationOff ? 0.45 : 1)
            Picker("Summary template", selection: Binding(get: { pipeline.template }, set: { pipeline.selectTemplate($0) })) {
                ForEach(pipeline.templates, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .disabled(pipeline.isRunning && pipeline.jobCommand != "process")
            if pipeline.summarization.status == .running {
                ProgressBar(fraction: pipeline.downloadFraction, indeterminate: pipeline.downloadFraction == nil)
            }
            Text(pipeline.summarizationFoot).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(2).help(pipeline.summarizationFoot).monospacedDigit()
        }
    }

    private var vaultCard: some View {
        StageCard(title: "Obsidian", status: pipeline.vault.status, off: pipeline.vaultOff, accessory: {
            EmptyView()
        }) {
            Text(vaultSubtitle).font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1)
                .help(vaultHelp)
                .opacity(pipeline.vaultOff ? 0.45 : 1)
            if pipeline.vault.status == .running {
                ProgressBar(fraction: nil, indeterminate: true)
            }
            Text(pipeline.vaultFoot).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(2).help(pipeline.vaultFoot)
            if let note = pipeline.vaultNote {
                HStack(spacing: 8) {
                    Button("Open in Obsidian") { note.open() }.controlSize(.small)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: note.path)])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show the note in Finder")
                }
            } else if pipeline.canDraft, !pipeline.vaultOff, pipeline.vault.status != .running {
                Button(pipeline.vault.status == .failed ? "Try Again" : pipeline.vaultDraft != nil ? "Review Note…" : "File to Obsidian…") {
                    pipeline.fileToVault()
                }
                .controlSize(.small)
            }
        }
    }

    /// "Claude · Personal vault · asks first"
    private var vaultSubtitle: String {
        guard let settings = pipeline.vaultSettings else { return "Claude · your vault" }
        let mode = pipeline.vaultOff ? "" : settings.asks ? " · asks first" : " · automatic"
        return "Claude · \(settings.name) vault" + mode
    }

    private var vaultHelp: String {
        guard let settings = pipeline.vaultSettings else { return "Files the recording into your Obsidian vault" }
        return settings.asks ? "[obsidian] confirm_before_filing = true: you see the note before it's filed"
                             : "[obsidian] confirm_before_filing = false: filed as soon as the transcript is ready"
    }

    private var whisperLabel: String {
        guard let model = app.doctor?.whisperModel else { return "Whisper · on this Mac" }
        var name = model.split(separator: "/").last.map(String.init) ?? model
        name = name.replacingOccurrences(of: "-mlx", with: "")
        name = name.replacingOccurrences(of: "whisper-", with: "Whisper ")
        for bits in ["8bit", "4bit"] { name = name.replacingOccurrences(of: "-\(bits)", with: " · \(bits.dropLast(3))-bit") }
        return name + (app.doctor?.whisperCached == false ? " · downloads on first use" : "")
    }

    // MARK: Results

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Results", selection: $tab) {
                    Text("Transcript").tag(Tab.transcript)
                    Text(pipeline.summaryUnseen && tab != .summary ? "Summary •" : "Summary").tag(Tab.summary)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 8)
                if pipeline.hasRun, let path = pipeline.sessionPath {
                    Text(path.abbreviatingHome + "/ · " + pipeline.savedFiles.joined(separator: ", "))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.ink2)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                    if pipeline.hasRecordingFile {
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path).appendingPathComponent("recording.wav"))
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Play the recording")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
            Group {
                switch tab {
                case .transcript: transcriptPane
                case .summary: summaryPane
                }
            }
            .frame(minHeight: 60, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pipeline.diarized && !pipeline.labels.isEmpty { SpeakerFields(pipeline: pipeline) }
            if pipeline.segments.isEmpty {
                Text(emptyTranscript).font(.system(size: 12.5)).foregroundStyle(Theme.ink3).padding(.vertical, 18).padding(.horizontal, 4)
            } else {
                TranscriptList(pipeline: pipeline, showSpeakers: pipeline.hasRun ? pipeline.ranDiarize : pipeline.diarizeOn)
            }
        }
    }

    private var emptyTranscript: String {
        if pipeline.isProcessing { return "Transcribing… segments appear here as they're recognised." }
        if pipeline.transcription.status == .failed { return pipeline.transcription.message ?? "Transcription failed." }
        if pipeline !== app.pipeline { return "Not transcribed yet. Transcribe above fills in the transcript, then who said what, then a summary." }
        return "Press Stop to transcribe this recording. The transcript fills in here, then who said what, then a summary."
    }

    private var summaryPane: some View {
        Group {
            if let text = pipeline.renderedSummary {
                ScrollView {
                    SummaryView(title: pipeline.summary?.title, markdown: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            } else {
                Text(pipeline.summarizationOff ? "Summarization is off for this recording." :
                    pipeline.summarization.status == .failed ? (pipeline.summarization.message ?? "Summarization failed.") :
                    "The summary appears here once the transcript is ready.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink3).padding(.vertical, 18).padding(.horizontal, 4)
            }
        }
    }
}

/// One stage of the pipeline.
struct StageCard<Accessory: View, Content: View>: View {
    let title: String
    let status: PipelineModel.Status
    let off: Bool
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusIcon(status: off ? .skipped : status, size: 18)
                Text(title).font(.system(size: 13, weight: .semibold)).opacity(off ? 0.45 : 1)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                accessory()
            }
            content()
        }
        .padding(.init(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .well()
        .accessibilityElement(children: .contain)
    }
}

struct StatusIcon: View {
    let status: PipelineModel.Status
    let size: CGFloat

    var body: some View {
        Group {
            switch status {
            case .running:
                ProgressView().controlSize(size > 16 ? .small : .mini)
            case .done:
                Image(systemName: "checkmark.circle.fill").resizable()
                    .symbolRenderingMode(.palette).foregroundStyle(.white, Theme.good)
            case .failed:
                Image(systemName: "xmark.circle.fill").resizable()
                    .symbolRenderingMode(.palette).foregroundStyle(.white, Theme.crit)
            case .cancelled:
                Image(systemName: "minus.circle.fill").resizable()
                    .symbolRenderingMode(.palette).foregroundStyle(.white, Theme.ink3)
            case .waiting:
                Circle().strokeBorder(Theme.ink3, lineWidth: size > 16 ? 2 : 1.5)
            case .skipped:
                Circle().strokeBorder(Theme.ink3, lineWidth: size > 16 ? 2 : 1.5).opacity(0.45)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(String(describing: status))
    }
}

/// The system's linear progress bar; indeterminate when there's no fraction.
struct ProgressBar: View {
    let fraction: Double?
    var indeterminate = false

    var body: some View {
        Group {
            if indeterminate {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: min(max(fraction ?? 0, 0), 1)).progressViewStyle(.linear)
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Transcript and speakers

struct SpeakerFields: View {
    let pipeline: PipelineModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Who's speaking?").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink2)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(pipeline.labels, id: \.self) { label in
                        HStack(spacing: 6) {
                            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink3)
                            TextField(placeholder(label), text: Binding(
                                get: { pipeline.drafts[label] ?? pipeline.names[label] ?? "" },
                                set: { pipeline.setDraft(label, $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                            .onSubmit { pipeline.commitNames() }
                            .accessibilityLabel("Name for \(label)")
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            if pipeline.jobCommand == "speakers" { ProgressView().controlSize(.mini) }
        }
    }

    private func placeholder(_ label: String) -> String {
        if let role = pipeline.roles[label], !role.isEmpty { return "e.g. \(role)" }
        return "Name"
    }
}

struct TranscriptList: View {
    let pipeline: PipelineModel
    let showSpeakers: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(pipeline.segments) { seg in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Self.mmss(seg.start)).font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.ink3).monospacedDigit().frame(width: 44, alignment: .leading)
                            if showSpeakers {
                                Group {
                                    if let label = seg.speaker {
                                        Text(pipeline.displayName(label)).font(.system(size: 12.5, weight: .semibold))
                                    } else {
                                        Text("…").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                                    }
                                }
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: 96, alignment: .leading)
                            }
                            Text(seg.text).font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(seg.id)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: pipeline.segments.count) { _, _ in
                if pipeline.isProcessing, let last = pipeline.segments.last {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    static func mmss(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: - Summary

/// Renders the summarizer's markdown: headings, bullet and numbered lists, paragraphs, inline styles.
struct SummaryView: View {
    let title: String?
    let markdown: String

    enum Block: Hashable {
        case heading(String, Int)
        case bullet(String, Int)
        case numbered(String, String, Int)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            ForEach(Array(Self.parse(markdown, skipping: title).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(text, level):
                    Text(Self.inline(text))
                        .font(level <= 1 ? .system(size: 14, weight: .semibold) : .system(size: 12, weight: .semibold))
                        .foregroundStyle(level <= 1 ? Theme.ink : Theme.ink2)
                        .padding(.top, 4)
                case let .bullet(text, indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.ink2)
                        Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 6 + CGFloat(indent) * 16)
                case let .numbered(n, text, indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(n).monospacedDigit().foregroundStyle(Theme.ink2)
                        Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 2 + CGFloat(indent) * 16)
                case let .paragraph(text):
                    Text(Self.inline(text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
        .frame(maxWidth: 620, alignment: .leading)
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func parse(_ text: String, skipping title: String?) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count / 2
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                let heading = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                // The title is shown above; drop a leading "# Title" that repeats it.
                if blocks.isEmpty, let title, heading.caseInsensitiveCompare(title) == .orderedSame { continue }
                blocks.append(.heading(heading, level))
            } else if let marker = ["- ", "* ", "+ "].first(where: line.hasPrefix) {
                flush()
                var item = String(line.dropFirst(marker.count))
                if item.hasPrefix("[ ] ") { item = "☐ " + item.dropFirst(4) }
                if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") { item = "☑ " + item.dropFirst(4) }
                blocks.append(.bullet(item, indent))
            } else if let match = line.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                flush()
                blocks.append(.numbered("\(match.1).", String(match.2), indent))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}

/// Opens Settings on the Hugging Face tab.
struct HuggingFaceSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Hugging Face Settings…") {
            Prefs.defaults.set("huggingface", forKey: Prefs.settingsTab)
            openSettings()
        }
        .controlSize(.small)
    }
}
