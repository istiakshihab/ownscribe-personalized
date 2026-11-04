import Foundation

/// A decoded JSON object from one protocol line. Unknown fields are ignored and missing or null
/// fields read as nil, as the protocol asks of readers.
struct JSONObject: @unchecked Sendable {
    let raw: [String: Any]

    init?(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        raw = obj
    }

    init(_ raw: [String: Any]) { self.raw = raw }

    subscript(key: String) -> Any? {
        let v = raw[key]
        return v is NSNull ? nil : v
    }

    func string(_ key: String) -> String? { self[key] as? String }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool? { (self[key] as? NSNumber)?.boolValue }
    func object(_ key: String) -> JSONObject? { (self[key] as? [String: Any]).map(JSONObject.init) }
    func objects(_ key: String) -> [JSONObject] { ((self[key] as? [Any]) ?? []).compactMap { ($0 as? [String: Any]).map(JSONObject.init) } }
    func strings(_ key: String) -> [String] { (self[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
    func stringMap(_ key: String) -> [String: String] {
        ((self[key] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }
    }
    var keys: [String] { Array(raw.keys) }
}

enum JSONLine {
    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Appends child stderr (and app notes) to ~/Library/Logs/Earshot/Earshot.log.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()
    let url: URL
    private let queue = DispatchQueue(label: "ownscribe.log")
    private var handle: FileHandle?

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Earshot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("Earshot.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ tag: String, _ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        note(tag, text, newline: false)
    }

    func note(_ tag: String, _ text: String, newline: Bool = true) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out = ""
        for (i, line) in lines.enumerated() where !(i == lines.count - 1 && line.isEmpty && !newline) {
            out += "\(stamp) [\(tag)] \(line)\n"
        }
        queue.async { [self] in try? handle?.write(contentsOf: Data(out.utf8)) }
    }
}
