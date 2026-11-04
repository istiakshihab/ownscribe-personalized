import Foundation
import os

// MARK: - Locking

/// A value guarded by an unfair lock that has a stable address (OSAllocatedUnfairLock), unlike
/// `os_unfair_lock_s` stored in a class property and passed with `&`, which Swift doesn't guarantee.
final class Locked<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }

    func get() -> Value { lock.withLock { $0 } }
    func set(_ value: Value) { lock.withLock { $0 = value } }
    @discardableResult
    func update<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&$0) } }
}

// MARK: - Time and levels

enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: Int64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func ticks(seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// Seconds from `start` to `t` (negative if `t` is earlier).
    static func elapsed(from start: UInt64, to t: UInt64) -> Double {
        t >= start ? seconds(Int64(t - start)) : -seconds(Int64(start - t))
    }
}

/// dBFS of a linear amplitude, or nil for digital silence (JSON has no -inf).
func dbfs(_ linear: Float) -> Double? {
    linear > 0 ? (20 * log10(Double(linear)) * 10).rounded() / 10 : nil
}

// MARK: - JSON events on stdout (the --control stdio channel)

/// Serialises protocol events onto stdout, one JSON object per line, from any thread.
///
/// Every line is a single write(2) so a reader never sees interleaved or partial lines, and
/// `levels` are coalesced: if the reader falls behind, only the newest snapshot is sent.
final class EventWriter: @unchecked Sendable {
    static let shared = EventWriter()

    private let queue = DispatchQueue(label: "com.ownscribe.events")
    private let state = Locked<(enabled: Bool, start: UInt64, pendingLevels: [String: Any]?)>((false, 0, nil))

    var isEnabled: Bool { state.get().enabled }

    func enable(sessionStart: UInt64) {
        state.update { $0.enabled = true; $0.start = sessionStart }
    }

    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        let current = state.get()
        guard current.enabled else { return }
        let line = Self.encode(event, fields, start: current.start)
        queue.async { Self.writeLine(line) }
    }

    /// Latest-wins: a levels snapshot that hasn't been written yet is replaced by a newer one.
    func emitLevels(_ fields: [String: Any]) {
        let shouldSchedule = state.update { s -> Bool in
            guard s.enabled else { return false }
            let wasEmpty = s.pendingLevels == nil
            s.pendingLevels = fields
            return wasEmpty
        }
        guard shouldSchedule else { return }
        queue.async { [self] in
            let (fields, start) = state.update { s -> ([String: Any]?, UInt64) in
                defer { s.pendingLevels = nil }
                return (s.pendingLevels, s.start)
            }
            if let fields { Self.writeLine(Self.encode("levels", fields, start: start)) }
        }
    }

    /// Block until everything queued so far has been written.
    func flush() { queue.sync {} }

    private static func encode(_ event: String, _ fields: [String: Any], start: UInt64) -> Data {
        var object = fields
        object["ev"] = event
        let t = HostTime.elapsed(from: start, to: mach_absolute_time())
        object["t"] = (t * 1000).rounded() / 1000
        var data = (try? JSONSerialization.data(withJSONObject: sanitize(object), options: [.withoutEscapingSlashes]))
            ?? Data("{\"ev\":\"error\",\"code\":\"encode_failed\"}".utf8)
        data.append(0x0A)
        return data
    }

    /// JSON can't carry NaN or infinity; map them (and nil) to null.
    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as Double: return d.isFinite ? d : NSNull()
        case let f as Float: return f.isFinite ? Double(f) : NSNull()
        case let dict as [String: Any]: return dict.mapValues(sanitize)
        case let array as [Any]: return array.map(sanitize)
        case Optional<Any>.none: return NSNull()
        default: return value
        }
    }

    private static func writeLine(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(STDOUT_FILENO, p, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return  // EPIPE: the client is gone; stdin EOF will stop the session
                }
                p += n
                remaining -= n
            }
        }
    }
}
