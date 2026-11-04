import Foundation

/// dBFS helpers. The meter and chart scale is −60…0 dBFS; anything below is "silence".
enum DB {
    static let floor = -60.0
    static let smoothFloor = -90.0

    static func fraction(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return max(0, min(1, (db - floor) / -floor))
    }

    static func power(_ db: Double) -> Double { db.isFinite ? pow(10, db / 10) : 0 }
    static func fromPower(_ p: Double) -> Double { p > 0 ? 10 * log10(p) : -.infinity }

    /// "−18.0", "−∞"
    static func format(_ db: Double, digits: Int = 1) -> String {
        guard db.isFinite, db > floor + 0.05 else { return "−∞" }
        let text = String(format: "%.\(digits)f", abs(db))
        return db < 0 && text != String(format: "%.\(digits)f", 0.0) ? "−" + text : text
    }

    /// Fader values: "+3.0", "0.0", "−6.0", "−∞".
    static func formatGain(_ db: Double) -> String {
        if db <= floor { return "−∞" }
        if db > 0.05 { return "+" + String(format: "%.1f", db) }
        return format(db)
    }

    /// Meter ballistics: rise fast, fall slowly (one-pole in dB), so meters read as a level, not jitter.
    static func smooth(_ prev: Double, _ target: Double, dt: Double) -> Double {
        let goal = target.isFinite ? max(target, smoothFloor) : smoothFloor
        let tau = goal > prev ? 0.05 : 0.4
        return prev + (goal - prev) * (1 - exp(-dt / tau))
    }
}

/// The last minute of the mix: one sample per `levels` event (20 Hz), in helper time.
final class LevelHistory {
    struct Sample {
        let t: Double
        let total: Double
        let levels: [String: Double]
    }

    static let window = 60.0
    static let bucket = 0.25
    private(set) var samples: [Sample] = []

    func reset() { samples.removeAll() }

    func append(_ sample: Sample) {
        samples.append(sample)
        let cutoff = sample.t - Self.window - 1
        if let first = samples.firstIndex(where: { $0.t >= cutoff }), first > 0 {
            samples.removeFirst(first)
        }
    }

    var last: Sample? { samples.last }

    /// Averages samples into fixed buckets anchored to absolute time (not pixel columns), so a
    /// finished bucket never changes and the past doesn't reshape as the chart scrolls; only the
    /// live bucket at "now" moves. Returns (mean time, mean dB clamped at the floor).
    func buckets(after t0: Double) -> [(t: Double, db: Double)] {
        var out: [(t: Double, db: Double)] = []
        var key = Int.min
        var st = 0.0, sv = 0.0, n = 0.0
        for s in samples where s.t >= t0 - Self.bucket {
            let k = Int((s.t / Self.bucket).rounded(.down))
            if k != key {
                if n > 0 { out.append((st / n, sv / n)) }
                key = k
                st = 0; sv = 0; n = 0
            }
            st += s.t
            sv += s.total.isFinite ? max(s.total, DB.floor) : DB.floor
            n += 1
        }
        if n > 0 { out.append((st / n, sv / n)) }
        return out
    }

    func nearest(to t: Double) -> Sample? {
        samples.min { abs($0.t - t) < abs($1.t - t) }
    }
}
