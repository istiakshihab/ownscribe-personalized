import AppKit
import UserNotifications

/// Informational notifications about detected calls ("Recording your Zoom call", "Zoom call
/// ended · transcribing"). The prompt to record is CallPrompt, not a notification.
///
/// macOS only delivers these for a properly signed app: an ad-hoc-signed Earshot (app/build.sh
/// without a signing identity) is refused, which is logged once and is otherwise harmless. A bare
/// `swift run` binary has no bundle, and UNUserNotificationCenter crashes there, so it's skipped.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// A click on a notification.
    var onOpen: (() -> Void)?

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? .current() : nil
    }

    private var setUpDone = false

    /// Asks for permission once (macOS remembers the answer).
    func setUp() {
        guard !setUpDone, let center else { return }
        setUpDone = true
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, error in
            AppLog.shared.note("notify", granted ? "allowed" : "not allowed\(error.map { ": \($0.localizedDescription)" } ?? "")")
        }
    }

    func recordingStarted(_ name: String) {
        post(id: "meeting", title: "Recording your \(name) call", body: "Earshot stops when the call ends.")
    }

    func meetingEnded(_ name: String) {
        post(id: "meeting", title: "\(name) call ended", body: "Recording saved. Transcribing now.")
    }

    private func post(id: String, title: String, body: String) {
        guard let center else { return }
        setUp()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onOpen?() }
            completionHandler()
        }
    }

    /// Show them even while Earshot is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
