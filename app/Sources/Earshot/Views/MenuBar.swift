import AppKit
import SwiftUI

/// The menu bar icon: a waveform, with a badge while a call is waiting to be recorded and a record
/// symbol while recording.
struct MenuBarLabel: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(app.menuStatus)
            // The label is always on screen, so it's where non-view code (notifications, the Dock
            // icon) gets a way to reopen the window.
            .onAppear { app.openMainWindow = { openWindow(id: "main") } }
    }

    private var symbol: String {
        switch app.recorder.phase {
        case .recording, .stopping: return "record.circle"
        case .starting: return "record.circle"
        case .idle: return app.promptedMeeting != nil ? "waveform.badge.mic" : "waveform"
        }
    }
}

struct MenuBarMenu: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let recorder = app.recorder
        Text(app.menuStatus)
        Divider()
        if let m = app.promptedMeeting {
            Button("Record \(m.name) Call") { app.recordMeeting(m) }
        }
        if recorder.phase == .recording || recorder.phase == .starting {
            Button("Stop Recording") { recorder.stop() }
        } else {
            Button("Start Recording") { recorder.toggle() }
                .disabled(recorder.phase != .idle || app.pipeline.isProcessing)
        }
        Divider()
        Button("Open Earshot") {
            NSApp.activate()
            openWindow(id: "main")
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Earshot") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
