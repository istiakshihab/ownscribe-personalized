import SwiftUI

/// Review the note Claude drafted before it's filed into the vault: title, category (which picks
/// the folder), tags and the note itself are editable.
struct VaultReviewSheet: View {
    let pipeline: PipelineModel
    @ViewState private var draft: VaultDraft

    init(pipeline: PipelineModel, draft: VaultDraft) {
        self.pipeline = pipeline
        _draft = ViewState(initialValue: draft)
    }

    private var canFile: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pipeline.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("File to Obsidian").font(.system(size: 15, weight: .semibold))
                Text("Claude drafted this note from the transcript. Change anything before it's filed.")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
            }
            if let earlier = draft.earlierNote {
                Label("Already filed as \(URL(fileURLWithPath: earlier).lastPathComponent). Filing again adds a second note.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
            }
            Form {
                TextField("Title", text: $draft.title)
                Picker("Category", selection: $draft.category) {
                    ForEach(draft.categoryChoices, id: \.self) { Text(draft.label(for: $0)).tag($0) }
                }
                TextField("Tags", text: $draft.tags, prompt: Text("comma-separated"))
                LabeledContent("Saved as") {
                    Text(draft.notePath)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink2)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Note").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink2)
                TextEditor(text: $draft.body)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 220)
                    .accessibilityLabel("Note text")
            }
            HStack {
                if pipeline.isRunning {
                    ProgressView().controlSize(.small)
                    Text(pipeline.activity ?? "Finishing the current step…").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
                Spacer()
                Button("Don't File", role: .cancel) { pipeline.skipVault() }
                    .keyboardShortcut(.cancelAction)
                Button("File Note") { pipeline.writeVault(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canFile)
            }
        }
        .padding(20)
        .frame(width: 620, height: 600)
    }
}
