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
        // First launch: a compact window with room for the history sidebar. (After that, macOS
        // reopens it at the size it was left; it can shrink to the layout's minimum.)
        .defaultWindowPlacement { content, context in
            let visible = context.defaultDisplay.visibleRect
            let width = min(1280, visible.width - 40)  // sidebar, the stages column and the transcript
            // Not the content's ideal height: the history list would ask for every row.
            let height = min(visible.height - 40, 760)
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
