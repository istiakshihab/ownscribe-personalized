import AppKit
import SwiftUI

struct ContentView: View {
    let app: AppModel

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { app.sidebarVisible ? .all : .detailOnly },
            set: { app.sidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
        } detail: {
            Group {
                if let item = app.selectedItem {
                    SessionDetailView(app: app, item: item)
                } else {
                    RecorderView(app: app)
                }
            }
            // Frosted window background: the desktop shows through, blurred, as in System Settings.
            .containerBackground(for: .window) { FrostedBackground() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    TimerLabel(recorder: app.recorder)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    RecordButton(app: app)
                }
            }
            .frame(minWidth: 760)  // the mixer rows, the stages column and a readable transcript
        }
        .task { await app.launch() }
    }
}

/// The recorder: signal, mixer, mic and save folder, then this recording's processing and results.
struct RecorderView: View {
    let app: AppModel

    var body: some View {
        // No page scrolling: the fixed parts sit on top and the results area (transcript, summary)
        // takes whatever height is left, scrolling inside itself.
        VStack(spacing: 10) {
            if !app.banners.isEmpty { BannerStack(app: app) }
            HStack(alignment: .top, spacing: 16) {
                MicPicker(recorder: app.recorder)
                SaveLocationPicker(app: app)
            }
            .padding(.horizontal, 4)
            // The signal strip with the mixer's rows under it, then the stages and the transcript,
            // which get the full width and whatever height is left.
            SignalPanel(recorder: app.recorder)
            PipelinePanel(app: app, pipeline: app.pipeline)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .navigationTitle("Earshot")
        .navigationSubtitle(app.statusLine)
    }
}

struct TimerLabel: View {
    let recorder: RecorderModel

    var body: some View {
        let live = recorder.phase == .recording || recorder.phase == .stopping
        HStack(spacing: 6) {
            if recorder.phase == .recording {
                Circle().fill(Theme.rec).frame(width: 7, height: 7)
                    .symbolEffect(.pulse, options: .repeating)
            }
            Text(Self.format(recorder.elapsed))
                .font(.system(size: 15, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(live ? Theme.ink : Theme.ink3)
        }
        .padding(.horizontal, 10)
        .accessibilityLabel("Elapsed time \(Self.format(recorder.elapsed))")
    }

    static func format(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }
}

struct RecordButton: View {
    let app: AppModel

    var body: some View {
        let recorder = app.recorder
        let recording = recorder.phase == .recording
        let busy = recorder.phase == .starting || recorder.phase == .stopping || (recorder.phase == .idle && app.pipeline.isProcessing)
        Group {
            if recording {
                Button { recorder.toggle() } label: { Label(title, systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.rec)
            } else {
                Button { recorder.toggle() } label: {
                    Label { Text(title) } icon: { Image(systemName: "record.circle.fill").foregroundStyle(Theme.rec) }
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .disabled(busy)
        .keyboardShortcut("r", modifiers: .command)
        .help(recording ? "Stop and save (⌘R)" : "Start recording (⌘R)")
    }

    private var title: String {
        switch app.recorder.phase {
        case .starting: return "Starting…"
        case .stopping: return "Saving…"
        case .recording: return "Stop"
        case .idle: return app.pipeline.isProcessing ? "Processing…" : "Record"
        }
    }
}

struct BannerStack: View {
    let app: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(app.banners) { banner in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    icon(banner.kind)
                    Text(banner.text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    actionButton(banner)
                    Button {
                        app.dismiss(banner)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink3)
                    .help(banner.action == .recordMeeting ? "Not now" : "Dismiss")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(tint(banner.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint(banner.kind).opacity(0.35), lineWidth: 0.5))
            }
        }
    }

    private func tint(_ kind: Banner.Kind) -> Color {
        switch kind {
        case .info: return .accentColor
        case .warning: return Theme.warn
        case .error: return Theme.crit
        }
    }

    @ViewBuilder private func icon(_ kind: Banner.Kind) -> some View {
        switch kind {
        case .info:
            Image(systemName: "video.fill").foregroundStyle(Color.accentColor)
        case .warning, .error:
            Image(systemName: kind == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint(kind))
        }
    }

    @ViewBuilder private func actionButton(_ banner: Banner) -> some View {
        switch banner.action {
        case .settings:
            Button("Settings…") { openSettings() }.controlSize(.small)
        case .huggingFace:
            Button("Hugging Face Settings…") {
                Prefs.defaults.set("huggingface", forKey: Prefs.settingsTab)
                openSettings()
            }
            .controlSize(.small)
        case .recheck:
            Button(app.checking ? "Checking…" : "Check again") { Task { await app.refreshDoctor() } }
                .controlSize(.small).disabled(app.checking)
        case .log:
            Button("Open log") { NSWorkspace.shared.open(AppLog.shared.url) }.controlSize(.small)
        case .recover:
            Button("Recover recording") { Task { await app.recorder.recover() } }.controlSize(.small)
        case let .privacy(code):
            Button("Open Privacy Settings") {
                let pane = code.hasPrefix("mic") ? "Privacy_Microphone" : "Privacy_AudioCapture"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        case .recordMeeting:
            Button {
                app.recordMeeting()
            } label: {
                Label { Text("Record") } icon: { Image(systemName: "record.circle.fill").foregroundStyle(Theme.rec) }
            }
            .controlSize(.small)
        case .dismiss:
            EmptyView()
        }
    }
}

/// AppKit's behind-window material (the frosted, vibrant background of sidebars in System Settings
/// and Finder). Kept frosted when the window isn't focused too: a recorder mostly sits beside the
/// app you're in, and standard materials would turn flat grey there.
struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
