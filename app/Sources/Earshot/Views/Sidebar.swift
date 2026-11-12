import AppKit
import SwiftUI

/// The recorder, then every past recording in the save folder by date. Folds away with the standard
/// sidebar button in the toolbar.
struct SidebarView: View {
    let app: AppModel
    @ViewState private var query = ""
    @ViewState private var confirmTrash: HistoryItem?
    @AppStorage(Prefs.outputDir) private var chosenFolder = ""

    private var filtered: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return app.history.items }
        return app.history.items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.folderName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List(selection: Binding(get: { app.selection }, set: { app.selection = $0 ?? .recorder })) {
            RecorderRow(recorder: app.recorder, pipeline: app.pipeline)
                .tag(AppModel.Selection.recorder)
            ForEach(HistoryModel.groups(filtered)) { group in
                Section(group.id) {
                    ForEach(group.items) { item in
                        HistoryRow(item: item, busy: app.pipeline(for: item.id)?.isRunning == true)
                            .tag(AppModel.Selection.session(item.id))
                            .contextMenu { menu(item) }
                    }
                }
            }
            if filtered.isEmpty && !app.history.loading {
                Text(query.isEmpty ? "Recordings you make show up here." : "No recordings match “\(query)”.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search recordings")
        .onChange(of: chosenFolder) { app.refreshHistory() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshHistory()
        }
        .confirmationDialog(
            "Move “\(confirmTrash?.title ?? "")” to the Trash?",
            isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } }),
            presenting: confirmTrash
        ) { item in
            Button("Move to Trash", role: .destructive) { Task { await app.trash(item) } }
        } message: { _ in
            Text("The recording, transcript and summary go to the Trash, where you can still get them back. A note already filed in Obsidian stays there.")
        }
    }

    @ViewBuilder private func menu(_ item: HistoryItem) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
        if let note = item.vaultNote {
            Button("Open Note in Obsidian") { VaultNote(path: note, needsReview: false).open() }
        }
        if item.hasRecording {
            Button("Open Recording") {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path).appendingPathComponent("recording.wav"))
            }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { confirmTrash = item }
    }
}

/// The first row: back to the recorder, which says when it's busy.
struct RecorderRow: View {
    let recorder: RecorderModel
    let pipeline: PipelineModel

    var body: some View {
        let recording = recorder.phase == .recording
        HStack(spacing: 6) {
            Label {
                Text(recording ? "Recording" : "Recorder")
            } icon: {
                Image(systemName: "record.circle").foregroundStyle(recording ? Theme.rec : .secondary)
            }
            Spacer(minLength: 0)
            if recording {
                Text(TimerLabel.format(recorder.elapsed)).font(.system(size: 11, design: .monospaced))
                    .monospacedDigit().foregroundStyle(.secondary)
            } else if pipeline.isRunning {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    let busy: Bool

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.mini)
            } else if item.failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn)
                    .help("A processing step failed")
            } else if item.vaultNote != nil {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    .help("Filed to Obsidian")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A past recording: its date and actions, then the same stage cards, transcript and summary as
/// after a fresh recording, where speakers can be renamed, the summary redone and the note filed.
struct SessionDetailView: View {
    let app: AppModel
    let item: HistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !app.banners.isEmpty { BannerStack(app: app) }
            if let pipeline = app.pipeline(for: item.id) {
                header(pipeline)
                PipelinePanel(app: app, pipeline: pipeline, hint: item.created.formatted(date: .complete, time: .shortened))
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .navigationTitle(item.title)
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        var parts = [item.created.formatted(date: .abbreviated, time: .shortened)]
        if let d = item.duration, d >= 1 { parts.append(HistoryItem.length(d)) }
        return parts.joined(separator: " · ")
    }

    /// Only when there's something to do that the stage cards don't offer.
    @ViewBuilder private func header(_ pipeline: PipelineModel) -> some View {
        if pipeline.hasRecordingFile && !pipeline.isRunning && !pipeline.canDraft {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(Theme.ink3)
                Text(pipeline.segments.isEmpty ? "This recording hasn't been transcribed." :
                        "This transcript predates speaker naming, summaries and filing in Earshot.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                Spacer(minLength: 8)
                Button(pipeline.segments.isEmpty ? "Transcribe" : "Process Again") { app.process(item) }
                    .help("Transcribe, find speakers and summarize this recording")
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.ink3.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
