import AppKit
import SwiftUI

@main
struct EarshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model: AppModel

    init() {
        // Writing to a helper that just exited must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        Prefs.register()
        let model = AppModel()
        _model = ViewState(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        Window("Earshot", id: "main") {
            ContentView(app: model)
        }
        // First launch: as wide as the layout likes and as tall as the screen allows, so nothing
        // needs a scroll bar. (After that, macOS reopens the window at the size it was left.)
        .defaultWindowPlacement { content, context in
            let visible = context.defaultDisplay.visibleRect
            let width = min(1040, visible.width - 40)
            let minimum = content.sizeThatFits(.init(width: width, height: nil)).height
            let height = min(visible.height - 40, max(minimum, 940))
            return WindowPlacement(size: CGSize(width: width, height: height))
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(app: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from a terminal (swift run / the bare binary), the app would start in the background.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting mid-recording stops and saves first (the helper merges the tracks), then quits.
    /// A running processing job keeps going on its own and finishes writing its files.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let recorder = Self.model?.recorder, recorder.phase != .idle else { return .terminateNow }
            recorder.stopForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
    }
}
