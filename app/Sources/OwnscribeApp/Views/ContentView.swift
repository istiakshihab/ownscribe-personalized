import AppKit
import SwiftUI

struct ContentView: View {
    let app: AppModel

    var body: some View {
        // No page scrolling: the fixed parts sit on top and the results area (transcript, summary)
        // takes whatever height is left, scrolling inside itself.
        VStack(spacing: 14) {
            if !app.banners.isEmpty { BannerStack(app: app) }
            HStack(alignment: .top, spacing: 14) {
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
            .padding(.horizontal, 4)
            PipelinePanel(app: app)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        // Frosted window background: the desktop shows through, blurred, as in System Settings.
        .containerBackground(for: .window) { FrostedBackground() }
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
        }
        .frame(minWidth: 880)
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
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background((banner.kind == .error ? Theme.crit : Theme.warn).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder((banner.kind == .error ? Theme.crit : Theme.warn).opacity(0.35), lineWidth: 0.5))
            }
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
