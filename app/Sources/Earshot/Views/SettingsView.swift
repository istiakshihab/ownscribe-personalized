import AppKit
import ServiceManagement
import SwiftUI

/// Earshot ▸ Settings…: the backend commands, the Hugging Face token diarization needs, and call
/// detection.
struct SettingsView: View {
    let app: AppModel
    @AppStorage(Prefs.settingsTab) private var tab = "backend"

    var body: some View {
        TabView(selection: $tab) {
            BackendSettings(app: app)
                .tabItem { Label("Backend", systemImage: "terminal") }
                .tag("backend")
            HuggingFaceSettings(app: app)
                .tabItem { Label("Hugging Face", systemImage: "key") }
                .tag("huggingface")
            MeetingSettings(app: app)
                .tabItem { Label("Meetings", systemImage: "video") }
                .tag("meetings")
        }
        .frame(width: 580)
    }
}

struct BackendSettings: View {
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
            } footer: {
                Text("Build the helper with `bash swift/build.sh` in the ownscribe repo. Jobs run as `<ownscribe command> process SESSION --events-fd 3`.")
                    .font(.footnote).foregroundStyle(.secondary)
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
    }

    private func recheck() {
        Task { await app.launch() }
    }
}

/// Paste, save and test the Hugging Face token. It's saved where the backend reads it,
/// `[diarization] hf_token` in ~/.config/ownscribe/config.toml, so the terminal CLI uses it too.
struct HuggingFaceSettings: View {
    let app: AppModel
    @ViewState private var saved = HFConfig.load()
    @ViewState private var pasted = ""
    @ViewState private var status: (text: String, isError: Bool)?
    @ViewState private var testing = false
    @ViewState private var result: HFConfig.TestResult?

    private static let model = HFConfig.gatedModels[0]

    var body: some View {
        Form {
            Section {
                LabeledContent("Saved token") {
                    Text(saved.map(HFConfig.masked) ?? "None").font(.system(.body, design: .monospaced))
                }
                SecureField("New token", text: $pasted, prompt: Text("Paste a token (hf_…)"))
                    .onSubmit(save)
                HStack {
                    Button("Save", action: save)
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(testing ? "Testing…" : "Test token", action: test)
                        .disabled(testing || (trimmedPaste.isEmpty && saved == nil))
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Show config.toml") {
                        NSWorkspace.shared.activateFileViewerSelecting([HFConfig.configURL])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: HFConfig.configURL.path))
                }
                if let status {
                    Label(status.text, systemImage: status.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(status.isError ? Theme.crit : Theme.good)
                }
                if let result { TestResultView(result: result) }
                if HFConfig.environmentHasToken {
                    Label(saved == nil
                          ? "This app inherited HF_TOKEN from your shell, and jobs use it until you save a token here."
                          : "This app inherited HF_TOKEN from your shell but ignores it: jobs use the saved token. The terminal ownscribe still prefers HF_TOKEN.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Token for speaker diarization")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Diarization downloads \(Self.model), a gated model. Sign in to Hugging Face, accept the model's terms on its page, and create a token with read access.")
                    HStack(spacing: 14) {
                        Link("Model page", destination: URL(string: "https://huggingface.co/\(Self.model)")!)
                        Link("Your tokens", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                    }
                    Text("Saved as [diarization] hf_token in ~/.config/ownscribe/config.toml (readable only by you), which the terminal ownscribe uses too.")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { saved = HFConfig.load() }
    }

    private var trimmedPaste: String { pasted.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        let token = trimmedPaste
        if let problem = HFConfig.problem(with: token) {
            status = (problem, true)
            return
        }
        do {
            try HFConfig.save(token)
            saved = HFConfig.load()
            pasted = ""
            status = ("Saved to config.toml.", false)
            Task { await app.refreshDoctor() }
            run(token)
        } catch {
            status = ("Couldn't save: \(error.localizedDescription)", true)
        }
    }

    /// Tests the pasted token if there is one, otherwise the saved one.
    private func test() {
        guard let token = trimmedPaste.isEmpty ? saved : trimmedPaste else { return }
        status = nil
        run(token)
    }

    private func run(_ token: String) {
        testing = true
        result = nil
        Task {
            let r = await HFConfig.test(token: token)
            result = r
            testing = false
        }
    }
}

struct TestResultView: View {
    let result: HFConfig.TestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = result.networkError {
                row(false, "Couldn't reach huggingface.co: \(error)")
            } else if result.invalid {
                row(false, "Hugging Face rejected this token (mistyped, revoked or expired).")
            } else {
                row(true, result.account.map { "Valid token for \($0)." } ?? "Valid token.")
                ForEach(result.models, id: \.id) { model in
                    switch model.access {
                    case .ok:
                        row(true, "Can download \(model.id).")
                    case .needsTerms:
                        VStack(alignment: .leading, spacing: 2) {
                            row(false, "No access to \(model.id) yet.")
                            HStack(spacing: 4) {
                                Text("Open")
                                Link("its page", destination: URL(string: "https://huggingface.co/\(model.id)")!)
                                Text("signed in as \(result.account ?? "this account"), accept the terms, then test again.")
                            }
                            .font(.callout).foregroundStyle(.secondary).padding(.leading, 22)
                        }
                    case let .failed(message):
                        row(false, "Couldn't check \(model.id): \(message).")
                    }
                }
            }
        }
    }

    private func row(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? Theme.good : Theme.crit)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Zoom and Teams call detection, and running from the menu bar.
struct MeetingSettings: View {
    let app: AppModel
    @AppStorage(Prefs.detectMeetings) private var detect = true
    @AppStorage(Prefs.meetingAutoStart) private var autoStart = false
    @AppStorage(Prefs.meetingAutoStop) private var autoStop = true
    @AppStorage(Prefs.keepInMenuBar) private var menuBar = true
    @ViewState private var loginStatus = SMAppService.mainApp.status
    @ViewState private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Detect Zoom and Teams calls", isOn: $detect)
                Toggle("Start recording automatically", isOn: $autoStart)
                    .disabled(!detect)
                Toggle("Stop when the call ends", isOn: $autoStop)
                    .disabled(!detect)
            } header: {
                Text("Calls")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(watcherStatus)
                    Text("When a call starts, Earshot asks in a small panel at the top right, unless it records automatically. A recording it started stops about 20 seconds after the call ends and is transcribed as usual. Recordings you start yourself are never stopped. Calls in a web browser aren't detected.")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep running in the menu bar", isOn: $menuBar)
                Toggle("Open at login", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                                                      set: setOpenAtLogin))
            } header: {
                Text("Background")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(menuBar ? "Closing the window keeps Earshot in the menu bar, still watching for calls. Quit from its menu."
                                 : "Closing the window quits Earshot, so calls are only noticed while it's open.")
                    if loginStatus == .requiresApproval {
                        HStack {
                            Text("Allow Earshot in System Settings › General › Login Items.")
                            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                                .controlSize(.small)
                        }
                    }
                    if let loginError { Text(loginError).foregroundStyle(Theme.crit) }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: detect) { Task { await app.updateMeetingWatcher() } }
        .onChange(of: menuBar) { AppDelegate.updateAutomaticTermination() }
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private var watcherStatus: String {
        switch app.meetings.status {
        case .off: return detect ? "Starting…" : "Call detection is off."
        case .starting: return "Starting…"
        case let .watching(names):
            if let m = app.meetings.current { return "\(m.name) call in progress." }
            return names.isEmpty ? "Watching for calls." : "Watching for \(names.joined(separator: " and ")) calls."
        case .unsupported: return "The capture helper is too old for call detection. Rebuild it with `bash swift/build.sh`."
        case let .failed(message): return message
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}
