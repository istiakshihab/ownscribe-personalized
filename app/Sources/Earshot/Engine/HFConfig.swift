import Foundation

/// The Hugging Face token diarization needs, kept where the backend reads it:
/// `[diarization] hf_token` in ~/.config/ownscribe/config.toml (shared with the terminal CLI).
///
/// Only that one line is touched; the rest of the file (comments included) is left as it was.
/// The file is rewritten atomically with mode 0600. The token is never logged.
enum HFConfig {
    /// Gated models diarization downloads (whisperx's DiarizationPipeline default).
    static let gatedModels = ["pyannote/speaker-diarization-community-1"]

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ownscribe/config.toml")
    }

    /// An HF_TOKEN in the app's own environment (inherited from a terminal). Jobs get it only
    /// while no token is saved in config.toml (see ToolCommand.environment).
    static var environmentHasToken: Bool {
        !(ProcessInfo.processInfo.environment["HF_TOKEN"] ?? "").isEmpty
    }

    // MARK: - Reading and writing config.toml

    static func load(from url: URL = configURL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return token(in: text)
    }

    static func save(_ token: String, to url: URL = configURL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = setting(token, in: existing)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".config.toml.earshot.tmp")
        try Data(updated.utf8).write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// `[diarization] hf_token` from TOML text, or nil if unset or empty.
    static func token(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let (index, _) = keyLine(in: lines) else { return nil }
        let value = parseValue(afterEquals: lines[index]).value
        return value.isEmpty ? nil : value
    }

    /// The TOML text with `[diarization] hf_token` set to `token`, everything else unchanged.
    static func setting(_ token: String, in text: String) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let assignment = "hf_token = \"\(escape(token))\""
        if let (index, _) = keyLine(in: lines) {
            // Keep a trailing comment on the line, e.g. `# HuggingFace token for pyannote models`.
            let trailing = parseValue(afterEquals: lines[index]).trailing
            let comment = trailing.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? trailing : ""
            lines[index] = assignment + comment
        } else if let header = sectionHeader(in: lines) {
            lines.insert(assignment, at: header + 1)
        } else {
            if let last = lines.last, last.isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += ["[diarization]", assignment, ""]
        }
        return lines.joined(separator: "\n")
    }

    static func masked(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "•", count: token.count) }
        return String(token.prefix(3)) + "…" + String(token.suffix(4))
    }

    /// Why a pasted value can't be saved, or nil if it looks like a token.
    static func problem(with token: String) -> String? {
        if token.isEmpty { return "Paste a token first." }
        if token.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }) {
            return "That doesn't look like a token: it has spaces or quotes in it."
        }
        return nil
    }

    // MARK: - TOML details

    private static func isHeader(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), let close = t.firstIndex(of: "]") else { return nil }
        let rest = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("#") || rest.hasPrefix("]") else { return nil }
        return t[t.index(after: t.startIndex)..<close].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
    }

    private static func sectionHeader(in lines: [String]) -> Int? {
        lines.firstIndex { isHeader($0) == "diarization" }
    }

    /// The `hf_token = …` line inside `[diarization]`.
    private static func keyLine(in lines: [String]) -> (Int, String)? {
        guard let header = sectionHeader(in: lines) else { return nil }
        var i = header + 1
        while i < lines.count, isHeader(lines[i]) == nil {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("hf_token"), t.dropFirst(8).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                return (i, lines[i])
            }
            i += 1
        }
        return nil
    }

    /// Value of `key = value` (basic or literal string, or bare) and whatever follows it.
    private static func parseValue(afterEquals line: String) -> (value: String, trailing: String) {
        guard let eq = line.firstIndex(of: "=") else { return ("", "") }
        let rest = line[line.index(after: eq)...].drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return ("", "") }
        if first == "\"" || first == "'" {
            var value = ""
            var i = rest.index(after: rest.startIndex)
            while i < rest.endIndex {
                let c = rest[i]
                if c == first { return (value, String(rest[rest.index(after: i)...])) }
                if first == "\"", c == "\\", rest.index(after: i) < rest.endIndex {
                    i = rest.index(after: i)
                    switch rest[i] {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    default: value.append(rest[i])
                    }
                } else {
                    value.append(c)
                }
                i = rest.index(after: i)
            }
            return (value, "")
        }
        let end = rest.firstIndex(of: "#") ?? rest.endIndex
        return (rest[..<end].trimmingCharacters(in: .whitespaces), String(rest[end...]))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Testing a token against huggingface.co

    struct TestResult: Equatable {
        enum Access: Equatable {
            case ok
            case needsTerms
            case failed(String)
        }

        var account: String?
        var invalid = false
        var networkError: String?
        var models: [(id: String, access: Access)] = []

        static func == (a: TestResult, b: TestResult) -> Bool {
            a.account == b.account && a.invalid == b.invalid && a.networkError == b.networkError
                && a.models.map(\.id) == b.models.map(\.id) && a.models.map(\.access) == b.models.map(\.access)
        }

        var allGood: Bool { !invalid && networkError == nil && models.allSatisfy { $0.access == .ok } }
    }

    /// Checks the token is valid and can download each gated model: the same request diarization
    /// makes (a file from the model repo), so a 403 here is the 403 a job would hit.
    static func test(token: String, session: URLSession = .init(configuration: .ephemeral)) async -> TestResult {
        var result = TestResult()
        func request(_ url: String, method: String = "GET") -> URLRequest {
            var r = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
            r.httpMethod = method
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return r
        }
        do {
            let (data, response) = try await session.data(for: request("https://huggingface.co/api/whoami-v2"))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                result.invalid = true
                return result
            }
            if status == 200, let json = JSONObject(line: data) {
                result.account = json.string("name")
            }
            for model in gatedModels {
                let (_, r) = try await session.data(for: request("https://huggingface.co/\(model)/resolve/main/config.yaml", method: "HEAD"))
                switch (r as? HTTPURLResponse)?.statusCode ?? 0 {
                case 200...399: result.models.append((model, .ok))
                case 401: result.invalid = true
                case 403: result.models.append((model, .needsTerms))
                case let code: result.models.append((model, .failed("HTTP \(code)")))
                }
            }
        } catch {
            result.networkError = error.localizedDescription
        }
        return result
    }
}
