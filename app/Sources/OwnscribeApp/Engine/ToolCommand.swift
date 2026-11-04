import Foundation

/// A command line from Settings, e.g. `uv run --project ~/Codes/ownscribe ownscribe`, resolved to an
/// absolute executable plus leading arguments. A GUI app gets launchd's minimal PATH, so bare names
/// are looked up in the usual install locations too (Homebrew, ~/.local/bin, cargo).
struct ToolCommand: Equatable, Sendable {
    let executable: String
    let baseArguments: [String]

    enum ParseError: LocalizedError {
        case empty
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "The command is empty"
            case let .notFound(name): return "Can't find “\(name)” (looked in \(ToolCommand.searchPath.joined(separator: ", ")))"
            }
        }
    }

    static var searchPath: [String] {
        let home = NSHomeDirectory()
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        return (extra + inherited).filter { seen.insert($0).inserted }
    }

    /// Environment for every child: the user's environment with a PATH that finds Homebrew tools.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        // The backend prefers HF_TOKEN over config.toml. An app launched from a terminal inherits the
        // shell's HF_TOKEN, so drop it when a token is saved (Settings ▸ Hugging Face): what's saved
        // there is what jobs use, however the app was opened.
        if HFConfig.load() != nil { env["HF_TOKEN"] = nil }
        return env
    }

    init(executable: String, baseArguments: [String]) {
        self.executable = executable
        self.baseArguments = baseArguments
    }

    init(parsing line: String) throws {
        let tokens = Self.split(line).map(Self.expandTilde)
        guard let first = tokens.first else { throw ParseError.empty }
        if first.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: first) else { throw ParseError.notFound(first) }
            executable = first
        } else if let found = Self.searchPath.map({ "\($0)/\(first)" }).first(where: FileManager.default.isExecutableFile) {
            executable = found
        } else {
            throw ParseError.notFound(first)
        }
        baseArguments = Array(tokens.dropFirst())
    }

    func arguments(_ extra: [String]) -> [String] { baseArguments + extra }

    /// Whitespace-separated words; "double" or 'single' quotes keep spaces.
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                inWord = true
            } else if ch.isWhitespace {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(ch)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    static func expandTilde(_ word: String) -> String {
        if word == "~" { return NSHomeDirectory() }
        if word.hasPrefix("~/") { return NSHomeDirectory() + word.dropFirst(1) }
        return word
    }
}

extension String {
    /// `/Users/me/ownscribe` → `~/ownscribe`
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }
}
