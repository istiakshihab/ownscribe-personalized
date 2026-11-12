import AppKit
import SwiftUI

struct Hint: View {
    let text: String
    var warning = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 11))
            }
            Text(text).font(.callout).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.headline)
    }
}

// MARK: - Microphone

struct MicPicker: View {
    let recorder: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
            FieldLabel(text: "Microphone")
            Picker("Microphone", selection: Binding(get: { recorder.micChoice }, set: { recorder.setMic($0) })) {
                Text("Automatic").tag(MicChoice.auto)
                if !recorder.devices.isEmpty { Divider() }
                ForEach(recorder.devices) { device in
                    Text(device.name).tag(MicChoice.device(device.uid))
                }
                if case let .device(uid) = recorder.micChoice, chosenDevice == nil {
                    Text("\(uid) (not connected)").tag(recorder.micChoice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 280)
            }
            let hint = self.hint
            HStack(spacing: 4) {
                Text(detail).font(.callout).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                // Explanations take no room until asked for; warnings stay visible below.
                if !hint.text.isEmpty && !hint.warning {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                        .help(hint.text)
                        .accessibilityLabel(hint.text)
                }
            }
            if hint.warning { Hint(text: hint.text, warning: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await recorder.refreshDevices() }
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

    /// For Automatic: the device it is (or will be) using. For a device: its transport and rate.
    private var detail: String {
        let live = recorder.phase == .recording || recorder.phase == .stopping
        if case .auto = recorder.micChoice {
            if live, let mic = recorder.micInfo {
                return "Using " + [mic.name, DeviceInfo.transportLabel(mic.transport), DeviceInfo.rateLabel(mic.rate)]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            }
            if let d = recorder.predictedAutoDevice {
                return "Uses " + [d.name, d.transportLabel, DeviceInfo.rateLabel(d.sampleRate)].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            return "Your default input, skipping Bluetooth headsets"
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
            return ("", false)
        }
    }
}

// MARK: - Save location

struct SaveLocationPicker: View {
    let app: AppModel
    @AppStorage(Prefs.outputDir) private var chosen = ""
    @ViewState private var recents = Prefs.recents

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                FieldLabel(text: "Save to")
                Picker("Save to", selection: $chosen) {
                    Text(app.defaultOutputDir.abbreviatingHome + " (default)").tag("")
                    let others = folders
                    if !others.isEmpty { Divider() }
                    ForEach(others, id: \.self) { Text($0.abbreviatingHome).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Button("Choose…") { choose() }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.outputDir)])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
            }
            .disabled(app.recorder.phase == .starting)
            Text("Next file: " + nextPath)
                .font(.callout).foregroundStyle(Theme.ink3)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Recent folders plus the current choice, without the default.
    private var folders: [String] {
        var list = recents
        if !chosen.isEmpty, !list.contains(chosen) { list.insert(chosen, at: 0) }
        return list.filter { $0 != app.defaultOutputDir }
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

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use"
        panel.message = "Recordings, transcripts and summaries are saved in a new folder here."
        panel.directoryURL = URL(fileURLWithPath: app.outputDir)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Prefs.addRecent(url.path)
        recents = Prefs.recents
        chosen = url.path
    }
}
