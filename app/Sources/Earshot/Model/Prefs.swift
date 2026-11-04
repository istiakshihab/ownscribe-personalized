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

    /// The ownscribe checkout this app was built from: app/build.sh records it in Info.plist, so an
    /// installed copy (install.sh) finds its own backend. A bundle without it falls back to the
    /// developer checkout.
    static let backendRoot: String = {
        let recorded = Bundle.main.object(forInfoDictionaryKey: "OwnscribeRoot") as? String ?? ""
        let root = (recorded.isEmpty ? "~/Codes/ownscribe" : recorded).abbreviatingHome
        return root.contains(where: \.isWhitespace) ? "\"\(root)\"" : root  // ToolCommand splits on spaces
    }()
    /// `--frozen`: run what install.sh synced, and never rewrite uv.lock.
    static let defaultOwnscribe = "uv run --frozen --project \(backendRoot) ownscribe"
    static let defaultHelper = "\(backendRoot)/bin/ownscribe-audio"
    /// Both halves of the protocol faked by scripts/mock_engine.py, five times faster than real time.
    static let mockCommand = "/usr/bin/python3 \(backendRoot)/scripts/mock_engine.py --speed 5"

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
