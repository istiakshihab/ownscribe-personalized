import AppKit
import SwiftUI

/// The mockup's select: glyph tile, main and sub line, chevron, on a glass capsule.
struct SelectButton: View {
    let systemImage: String
    let main: String
    let sub: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 30, height: 30)
                    .well(radius: 10, fill: Theme.well)
                VStack(alignment: .leading, spacing: 0) {
                    Text(main).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3)
            }
            .padding(.vertical, 8).padding(.leading, 10).padding(.trailing, 14)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct Hint: View {
    let text: String
    var warning = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.ink, Theme.warn)
                    .font(.system(size: 11))
            }
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4)
    }
}

struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink2).padding(.leading, 4)
    }
}

// MARK: - Microphone

struct MicPicker: View {
    let recorder: RecorderModel
    @ViewState private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Microphone")
            SelectButton(systemImage: "mic", main: mainText, sub: subText) { open.toggle() }
                .popover(isPresented: $open, arrowEdge: .top) { menu }
                .accessibilityLabel("Microphone: \(mainText)")
            let hint = self.hint
            if !hint.text.isEmpty { Hint(text: hint.text, warning: hint.warning) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            OptionRow(title: "Automatic", subtitle: "Default input, but skips Bluetooth headsets",
                      selected: recorder.micChoice == .auto) { pick(.auto) }
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            if recorder.devices.isEmpty {
                Text("No input devices found").font(.system(size: 12)).foregroundStyle(Theme.ink3).padding(10)
            }
            ForEach(recorder.devices) { device in
                OptionRow(title: device.name, subtitle: Self.describe(device),
                          selected: recorder.micChoice == .device(device.uid)) { pick(.device(device.uid)) }
            }
        }
        .padding(6)
        .frame(width: 300)
        .task { await recorder.refreshDevices() }
    }

    private func pick(_ choice: MicChoice) {
        recorder.setMic(choice)
        open = false
    }

    static func describe(_ d: DeviceInfo) -> String {
        var parts = [d.transportLabel]
        if !d.isVirtual, !d.isBluetooth { parts.append(DeviceInfo.rateLabel(d.sampleRate)) }
        if d.isBluetooth { parts.append("\(DeviceInfo.rateLabel(d.sampleRate)) hands-free") }
        if d.isDefault { parts.append("system default") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var chosenDevice: DeviceInfo? {
        if case let .device(uid) = recorder.micChoice { return recorder.devices.first { $0.uid == uid } }
        return nil
    }

    private var mainText: String {
        switch recorder.micChoice {
        case .auto: return "Automatic"
        case let .device(uid): return chosenDevice?.name ?? uid
        }
    }

    /// For Automatic: the device it is (or will be) using.
    private var subText: String {
        let live = recorder.phase == .recording || recorder.phase == .stopping
        if case .auto = recorder.micChoice {
            if live, let mic = recorder.micInfo {
                return [mic.name, DeviceInfo.transportLabel(mic.transport), DeviceInfo.rateLabel(mic.rate)]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            }
            if let d = recorder.predictedAutoDevice {
                return [d.name, d.transportLabel, DeviceInfo.rateLabel(d.sampleRate)].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            return "Your default input"
        }
        return chosenDevice.map(Self.describe) ?? "Not connected"
    }

    private var hint: (text: String, warning: Bool) {
        // A live problem from the helper wins (silent mic, fallback, permission).
        if let n = recorder.notices.last(where: { $0.source == "mic" && $0.isProblem }) {
            return (n.message, true)
        }
        switch recorder.micChoice {
        case .auto:
            if let skipped = recorder.skippedBluetoothDefault, let used = recorder.predictedAutoDevice, used.uid != skipped.uid {
                return ("Your default input, \(skipped.name), is a Bluetooth headset, so \(used.isBuiltIn ? "the built-in mic" : used.name) is used. Your headphones keep full sound quality.", false)
            }
            if let n = recorder.notices.last(where: { $0.source == "mic" && $0.code == "mic_bluetooth" }) {
                return (n.message, false)
            }
            return ("", false)
        case .device:
            guard let d = chosenDevice else { return ("This device isn't connected; recording uses the default input.", true) }
            if d.isBluetooth {
                return ("Headset mics record in hands-free mode (\(DeviceInfo.rateLabel(d.sampleRate))), and your headphones drop to the same quality while recording.", true)
            }
            if d.isVirtual {
                return ("This device carries another app's audio, not your voice. Pick a real microphone to be heard in the recording.", true)
            }
            return ("Clear \(DeviceInfo.rateLabel(d.sampleRate)) audio.", false)
        }
    }
}

// MARK: - Save location

struct SaveLocationPicker: View {
    let app: AppModel
    @AppStorage(Prefs.outputDir) private var chosen = ""
    @ViewState private var open = false
    @ViewState private var recents = Prefs.recents

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Save to")
            SelectButton(systemImage: "folder", main: app.outputDir.abbreviatingHome,
                         sub: chosen.isEmpty ? "Default · audio, transcript and notes" : "Audio, transcript and notes") { open.toggle() }
                .popover(isPresented: $open, arrowEdge: .top) { menu }
                .disabled(app.recorder.phase == .starting)
                .accessibilityLabel("Save to \(app.outputDir.abbreviatingHome)")
            Hint(text: "Next file: " + nextPath)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nextPath: String {
        if let path = app.recorder.sessionPath, app.recorder.phase != .idle {
            return (path + "/recording.wav").abbreviatingHome
        }
        let stamp = Self.stampFormatter.string(from: Date())
        return (app.outputDir + "/" + stamp + "/recording.wav").abbreviatingHome
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            OptionRow(title: app.defaultOutputDir.abbreviatingHome, subtitle: "Default", selected: chosen.isEmpty) {
                chosen = ""
                open = false
            }
            ForEach(recents.filter { $0 != app.defaultOutputDir }, id: \.self) { dir in
                OptionRow(title: dir.abbreviatingHome, subtitle: "Recent", selected: chosen == dir) {
                    chosen = dir
                    open = false
                }
            }
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            OptionRow(title: "Choose a folder…", selected: false) {
                open = false
                choose()
            }
            OptionRow(title: "Show in Finder", selected: false) {
                open = false
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.outputDir)])
            }
        }
        .padding(6)
        .frame(width: 280)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use"
        panel.message = "Recordings, transcripts and summaries are saved in a new folder here."
        panel.directoryURL = URL(fileURLWithPath: app.outputDir)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosen = url.path
        Prefs.addRecent(url.path)
        recents = Prefs.recents
    }
}
