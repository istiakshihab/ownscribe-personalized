import AppKit
import AVFAudio
import Foundation
import Observation

/// One past recording: a session folder in the save folder, read straight from the files the helper
/// and the jobs write (docs/engine-protocol.md, "Session folder").
struct HistoryItem: Identifiable, Hashable, Sendable {
    /// session.json's id, stable when the folder is renamed after its title; the folder name otherwise.
    let id: String
    let path: String
    let title: String
    let created: Date
    let duration: Double?
    let hasRecording: Bool
    let hasTranscript: Bool
    let hasSummary: Bool
    /// transcription, diarization, summarization, vault → pending | running | done | failed | skipped
    let stages: [String: String]
    let vaultNote: String?

    var failed: Bool { stages.values.contains("failed") }
    var folderName: String { URL(fileURLWithPath: path).lastPathComponent }

    /// "3:01 PM · 37 min"
    var subtitle: String {
        var parts = [created.formatted(date: .omitted, time: .shortened)]
        if let duration, duration >= 1 { parts.append(Self.length(duration)) }
        if !hasTranscript { parts.append(hasRecording ? "not transcribed" : "no audio") }
        return parts.joined(separator: " · ")
    }

    static func length(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s / 60 % 60) min"
    }
}

/// The save folder's recordings, newest first.
@MainActor
@Observable
final class HistoryModel {
    var items: [HistoryItem] = []
    var folder: String?
    var loading = false
    @ObservationIgnored private var generation = 0

    func refresh(folder: String) {
        self.folder = folder
        generation += 1
        let wanted = generation
        loading = true
        Task.detached(priority: .userInitiated) {
            let found = Self.scan(folder)
            await MainActor.run { [weak self] in
                guard let self, wanted == generation else { return }
                items = found
                loading = false
            }
        }
    }

    func item(_ id: String) -> HistoryItem? { items.first { $0.id == id } }

    /// Moves the session folder to the Trash (recoverable from there).
    func trash(_ item: HistoryItem) async throws {
        _ = try await NSWorkspace.shared.recycle([URL(fileURLWithPath: item.path)])
        items.removeAll { $0.id == item.id }
    }

    // MARK: - Scanning (off the main thread)

    nonisolated static func scan(_ folder: String) -> [HistoryItem] {
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.firstMatch(of: #/^\d{4}-\d{2}-\d{2}_\d{4}/#) != nil }
            .compactMap { read(root.appendingPathComponent($0)) }
            .sorted { $0.created > $1.created }
    }

    nonisolated static func read(_ dir: URL) -> HistoryItem? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        func json(_ name: String) -> [String: Any]? {
            (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        let hasRecording = has("recording.wav")
        let hasTranscript = has("transcript.json") || has("transcript.md")
        let hasSummary = has("summary.md")
        // Folders a crashed or cancelled recording left behind (empty, or only temp tracks) aren't history.
        guard hasRecording || hasTranscript || hasSummary else { return nil }

        let state = json("session.json") ?? [:]
        let capture = json("capture.json") ?? [:]
        let name = dir.lastPathComponent
        let id = (state["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        var stages: [String: String] = [:]
        for (stage, value) in state["stages"] as? [String: Any] ?? [:] {
            if let status = (value as? [String: Any])?["status"] as? String { stages[stage] = status }
        }
        if stages.isEmpty, hasTranscript { stages["transcription"] = "done" }
        if stages["summarization"] == nil, hasSummary { stages["summarization"] = "done" }
        let vault = (state["vault_note"] as? [String: Any])?["path"] as? String

        var duration = (capture["duration"] as? NSNumber)?.doubleValue
        if duration == nil || duration == 0, hasRecording,
           let file = try? AVAudioFile(forReading: dir.appendingPathComponent("recording.wav")) {
            duration = Double(file.length) / file.fileFormat.sampleRate
        }
        return HistoryItem(id: id, path: dir.path, title: title(state: state, folder: name, id: id),
                           created: created(state: state, capture: capture, folder: name), duration: duration,
                           hasRecording: hasRecording, hasTranscript: hasTranscript, hasSummary: hasSummary,
                           stages: stages, vaultNote: vault)
    }

    /// session.json's title, else the title slug the terminal pipeline put in the folder name.
    nonisolated static func title(state: [String: Any], folder: String, id: String) -> String {
        if let title = state["title"] as? String, !title.isEmpty { return title }
        var rest = Substring(folder)
        if id != folder, folder.hasPrefix(id) {
            rest = folder.dropFirst(id.count)
        } else if let m = folder.firstMatch(of: #/^\d{4}-\d{2}-\d{2}_\d{4,6}/#) {
            rest = folder[m.range.upperBound...]
        }
        let slug = rest.drop { $0 == "_" || $0 == "-" }.replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !slug.isEmpty else { return "Untitled recording" }
        return slug.prefix(1).uppercased() + slug.dropFirst()
    }

    /// When it was recorded: session.json's `created`, capture.json's `session_start`, else the folder name.
    nonisolated static func created(state: [String: Any], capture: [String: Any], folder: String) -> Date {
        let iso = ISO8601DateFormatter()
        for value in [state["created"], capture["session_start"]] {
            if let s = value as? String, let d = iso.date(from: s) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let stamp = String(folder.prefix(17))
        for format in ["yyyy-MM-dd_HHmmss", "yyyy-MM-dd_HHmm"] {
            f.dateFormat = format
            if let d = f.date(from: format.count == 17 ? stamp : String(stamp.prefix(15))) { return d }
        }
        return .distantPast
    }

    // MARK: - Sidebar sections

    struct Group: Identifiable {
        let id: String
        let items: [HistoryItem]
    }

    /// Today, Yesterday, Previous 7 Days, Previous 30 Days, then by month.
    static func groups(_ items: [HistoryItem], now: Date = .now) -> [Group] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func section(_ date: Date) -> String {
            let day = calendar.startOfDay(for: date)
            let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            switch days {
            case ..<1: return "Today"
            case 1: return "Yesterday"
            case 2..<7: return "Previous 7 Days"
            case 7..<30: return "Previous 30 Days"
            default: return date.formatted(.dateTime.month(.wide).year())
            }
        }
        var out: [Group] = []
        for item in items {
            let key = section(item.created)
            if let last = out.last, last.id == key {
                out[out.count - 1] = Group(id: key, items: last.items + [item])
            } else {
                out.append(Group(id: key, items: [item]))
            }
        }
        return out
    }
}

/// Transcripts the terminal pipeline wrote before transcript.json existed: `**SPEAKER** [MM:SS]`
/// headers, then `[MM:SS] text` lines (the first line of a turn has no time of its own).
enum MarkdownTranscript {
    static func segments(_ text: String) -> [(start: Double, text: String, speaker: String?)] {
        var out: [(Double, String, String?)] = []
        var speaker: String?
        var turnStart: Double?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = line.firstMatch(of: #/^\*\*(.+?)\*\*\s*\[(\d+(?::\d+){1,2})\]$/#) {
                speaker = String(m.1)
                turnStart = seconds(String(m.2))
            } else if let m = line.firstMatch(of: #/^\[(\d+(?::\d+){1,2})\]\s*(.*)$/#) {
                out.append((seconds(String(m.1)), String(m.2), speaker))
                turnStart = nil
            } else if let start = turnStart, !line.isEmpty {
                out.append((start, line, speaker))
                turnStart = nil
            }
        }
        return out
    }

    static func seconds(_ stamp: String) -> Double {
        stamp.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
}
