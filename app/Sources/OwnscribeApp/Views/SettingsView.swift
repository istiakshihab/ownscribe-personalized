import AppKit
import SwiftUI

/// ownscribe ▸ Settings…: the backend commands, and the Hugging Face token diarization needs.
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
