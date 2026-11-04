import AppKit
import SwiftUI

struct ContentView: View {
    let app: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !app.banners.isEmpty { BannerStack(app: app) }
                HStack(alignment: .top, spacing: 16) {
                    SignalPanel(recorder: app.recorder)
                        .frame(minWidth: 320)
                    MixerPanel(recorder: app.recorder)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    MicPicker(recorder: app.recorder)
                    SaveLocationPicker(app: app)
                }
                PipelinePanel(app: app)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background { Wallpaper().ignoresSafeArea() }
        .navigationTitle("ownscribe")
        .navigationSubtitle(app.statusLine)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                TimerLabel(recorder: app.recorder)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                RecordButton(app: app)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .frame(minWidth: 880, minHeight: 640)
        .task { await app.launch() }
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
        let label = HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: recording ? 3 : 6, style: .continuous)
                .fill(recording ? Color.white : Theme.rec)
                .frame(width: recording ? 10 : 12, height: recording ? 10 : 12)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
        .padding(.leading, 4).padding(.trailing, 6)
        // While recording the button is solid red (like the mockup), not an accent tint that
        // turns grey whenever the window isn't key.
        Button { recorder.toggle() } label: {
            label
                .foregroundStyle(recording ? Color.white : Theme.ink)
                .padding(.vertical, 7).padding(.horizontal, 8)
                .background { if recording { Capsule().fill(Theme.rec) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .disabled(busy)
        .keyboardShortcut("r", modifiers: .command)
        .help(recording ? "Stop and save (⌘R)" : "Start recording (⌘R)")
        .animation(.snappy, value: recording)
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
                    Image(systemName: banner.kind == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, banner.kind == .error ? Theme.crit : Theme.warn)
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
                    .help("Dismiss")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular.tint((banner.kind == .error ? Theme.crit : Theme.warn).opacity(0.12)),
                             in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    @ViewBuilder private func actionButton(_ banner: Banner) -> some View {
        switch banner.action {
        case .settings:
            Button("Settings…") { openSettings() }.buttonStyle(.glass).controlSize(.small)
        case .recheck:
            Button(app.checking ? "Checking…" : "Check again") { Task { await app.refreshDoctor() } }
                .buttonStyle(.glass).controlSize(.small).disabled(app.checking)
        case .log:
            Button("Open log") { NSWorkspace.shared.open(AppLog.shared.url) }.buttonStyle(.glass).controlSize(.small)
        case .recover:
            Button("Recover recording") { Task { await app.recorder.recover() } }.buttonStyle(.glass).controlSize(.small)
        case let .privacy(code):
            Button("Open Privacy Settings") {
                let pane = code.hasPrefix("mic") ? "Privacy_Microphone" : "Privacy_AudioCapture"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.glass).controlSize(.small)
        case .dismiss:
            EmptyView()
        }
    }
}

struct SettingsView: View {
    let app: AppModel
    @AppStorage(Prefs.ownscribeCommand) private var ownscribe = Prefs.defaultOwnscribe
    @AppStorage(Prefs.helperCommand) private var helper = Prefs.defaultHelper

    var body: some View {
        Form {
            Section {
                TextField("ownscribe command", text: $ownscribe, prompt: Text(Prefs.defaultOwnscribe))
                    .font(.system(size: 12, design: .monospaced))
                TextField("Capture helper", text: $helper, prompt: Text(Prefs.defaultHelper))
                    .font(.system(size: 12, design: .monospaced))
            } header: {
                Text("Backend")
            } footer: {
                Text("Build the helper with `bash swift/build.sh` in the ownscribe repo. Jobs run as `<ownscribe command> process SESSION --events-fd 3`.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Use defaults") {
                        ownscribe = Prefs.defaultOwnscribe
                        helper = Prefs.defaultHelper
                        recheck()
                    }
                    Button("Use mock engine") {
                        ownscribe = Prefs.mockCommand
                        helper = Prefs.mockCommand
                        recheck()
                    }
                    .help("scripts/mock_engine.py fakes capture and processing with synthetic data")
                    Spacer()
                    Button("Check setup") { recheck() }
                }
                HStack {
                    Button("Open log") { NSWorkspace.shared.open(AppLog.shared.url) }
                    Text(AppLog.shared.url.path.abbreviatingHome).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
    }

    private func recheck() {
        Task { await app.launch() }
    }
}
