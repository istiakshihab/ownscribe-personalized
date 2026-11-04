import AppKit
import Foundation

/// `[obsidian]` as `ownscribe doctor` reports it: whether recordings are filed into the vault, where,
/// and whether to show the note before filing (`confirm_before_filing`).
struct VaultSettings: Equatable, Sendable {
    var enabled: Bool
    var dir: String
    var exists: Bool
    var asks: Bool

    var name: String { URL(fileURLWithPath: dir).lastPathComponent }
}

/// The note Claude drafted (`ownscribe file SESSION --preview`), as edited in the review sheet.
struct VaultDraft: Equatable {
    var title: String
    var category: String
    var tags: String              // comma-separated while editing
    var body: String
    let date: String
    /// Category → vault folder; any other category goes to `fallback`, flagged for review.
    let folders: [String: String]
    let fallback: String
    let vaultDir: String
    /// Speaker names the draft was made with: a rename since means it should be drafted again.
    let names: [String: String]
    /// A note an earlier write already made for this recording.
    let earlierNote: String?
    let originalCategory: String

    var tagList: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var destination: String { folders[category] ?? fallback }
    var needsReview: Bool { folders[category] == nil }
    /// Roughly where it lands (the backend cleans the file name and avoids clashes).
    var notePath: String {
        let vault = URL(fileURLWithPath: vaultDir).lastPathComponent
        return "\(vault)/\(destination)/\(date) \(title.trimmingCharacters(in: .whitespacesAndNewlines)).md"
    }

    /// The vault's categories, plus one that files into the inbox.
    var categoryChoices: [String] {
        let inbox = folders[originalCategory] == nil ? originalCategory : "Unknown"
        return folders.keys.sorted() + [inbox]
    }

    func label(for category: String) -> String {
        guard folders[category] == nil else { return category }
        return "\(category.isEmpty ? "Unknown" : category) → \(fallback), needs review"
    }
}

/// The note `ownscribe file SESSION --write` wrote.
struct VaultNote: Equatable {
    let path: String
    let needsReview: Bool

    /// The vault folder it's in, e.g. "Research" or "Meetings Inbox".
    func folder(in vaultDir: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let root = URL(fileURLWithPath: vaultDir).path
        return parent.hasPrefix(root + "/") ? String(parent.dropFirst(root.count + 1)) : URL(fileURLWithPath: parent).lastPathComponent
    }

    /// Opens the note in Obsidian (obsidian://open), or in the default app when Obsidian isn't installed.
    func open() {
        let file = URL(fileURLWithPath: path)
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
        if let url = URL(string: "obsidian://open?path=\(encoded)"), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}
