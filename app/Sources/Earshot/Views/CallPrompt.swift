import AppKit
import SwiftUI

/// The "Zoom call started · Record / Not now" prompt: a small floating panel in the top-right
/// corner, over other apps and full-screen calls, that never takes focus from the call.
///
/// A panel rather than a notification: macOS refuses notifications from an ad-hoc-signed app
/// ("Notifications are not allowed for this application"), which is how Earshot is built.
@MainActor
final class CallPrompt {
    static let shared = CallPrompt()
    private var panel: NSPanel?

    func show(_ name: String, record: @escaping () -> Void, notNow: @escaping () -> Void) {
        close()
        let view = CallPromptView(name: name,
                                  record: { [weak self] in self?.close(); record() },
                                  notNow: { [weak self] in self?.close(); notNow() })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let background = NSVisualEffectView(frame: hosting.frame)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.addSubview(hosting)

        let panel = NSPanel(contentRect: hosting.frame, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.contentView = background
        panel.isFloatingPanel = true
        panel.level = .statusBar  // above full-screen windows too
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CallPromptView: View {
    let name: String
    let record: () -> Void
    let notNow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) call started").font(.system(size: 13, weight: .semibold))
                Text("Record it with Earshot?").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .fixedSize()
            Spacer(minLength: 12)
            Button("Not now", action: notNow)
            Button {
                record()
            } label: {
                Label { Text("Record") } icon: { Image(systemName: "record.circle.fill").foregroundStyle(Theme.rec) }
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .fixedSize()
    }
}
