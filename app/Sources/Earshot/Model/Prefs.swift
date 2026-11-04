import Foundation

/// UserDefaults keys and defaults. Views bind with @AppStorage; models read through here.
enum Prefs {
    static let ownscribeCommand = "ownscribeCommand"
    static let helperCommand = "helperCommand"
    static let outputDir = "outputDir"          // "" = ownscribe's [output] dir
    static let recentDirs = "recentDirs"
    static let micChoice = "micChoice"          // "auto" or "device:<uid>"
    static let diarize = "diarize"
    static let summarize = "summarize"
    static let template = "template"
    static let settingsTab = "settingsTab"   // backend | huggingface

    static let defaultOwnscribe = "uv run --project ~/Codes/ownscribe ownscribe"
    static let defaultHelper = "~/Codes/ownscribe/bin/ownscribe-audio"
    /// Both halves of the protocol faked by scripts/mock_engine.py, five times faster than real time.
    static let mockCommand = "/usr/bin/python3 ~/Codes/ownscribe/scripts/mock_engine.py --speed 5"

    static var defaults: UserDefaults { .standard }

    static func register() {
        defaults.register(defaults: [
            ownscribeCommand: defaultOwnscribe,
            helperCommand: defaultHelper,
            outputDir: "",
            micChoice: "auto",
            diarize: true,
            summarize: true,
            template: "meeting",
        ])
    }

    static func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }
    static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }

    static func gain(_ source: String) -> Double { defaults.double(forKey: "gain.\(source)") }
    static func muted(_ source: String) -> Bool { defaults.bool(forKey: "mute.\(source)") }
    static func setGain(_ source: String, _ db: Double) { defaults.set(db, forKey: "gain.\(source)") }
    static func setMuted(_ source: String, _ muted: Bool) { defaults.set(muted, forKey: "mute.\(source)") }

    static var recents: [String] { defaults.stringArray(forKey: recentDirs) ?? [] }
    static func addRecent(_ dir: String) {
        var list = recents.filter { $0 != dir }
        list.insert(dir, at: 0)
        defaults.set(Array(list.prefix(4)), forKey: recentDirs)
    }
}
