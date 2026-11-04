import SwiftUI

/// "Total signal": the mix of every source after faders and mutes over the last 60 s.
struct SignalPanel: View {
    let recorder: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PanelTitle(text: "Total signal")
                Text("\(DB.format(recorder.totalReadout)) dBFS")
                    .font(Theme.mono).monospacedDigit().foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            SignalChart(recorder: recorder)
                .frame(minHeight: 180, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel()
    }

    private var subtitle: String {
        let apps = recorder.appStrips.count
        return (apps == 0 ? "Mic and system audio mixed" : "Mic, apps and system audio mixed") + " · last 60 s"
    }
}

struct SignalChart: View {
    let recorder: RecorderModel
    @ViewState private var hoverX: CGFloat?

    private let pad = (l: CGFloat(32), r: CGFloat(10), t: CGFloat(8), b: CGFloat(20))

    var body: some View {
        let live = recorder.phase == .recording || recorder.phase == .stopping
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live && hoverX == nil)) { _ in
            GeometryReader { geo in
                let now = recorder.now
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in draw(&ctx, size: size, now: now) }
                    if recorder.history.samples.isEmpty {
                        Text(recorder.phase == .idle ? "Press Record to see the signal" : "Waiting for audio…")
                            .font(.system(size: 12)).foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let hoverX, let tip = tooltip(at: hoverX, size: geo.size, now: now) {
                        tip.view
                            .fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.wellLine, lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                            .alignmentGuide(.leading) { d in
                                let left = tip.x + 14 + d.width > geo.size.width ? tip.x - d.width - 14 : tip.x + 14
                                return -max(0, left)
                            }
                            .alignmentGuide(.top) { d in -max(0, min(tip.y - d.height / 2, geo.size.height - d.height)) }
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(p): hoverX = (p.x >= pad.l && p.x <= geo.size.width - pad.r) ? p.x : nil
                    case .ended: hoverX = nil
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Total signal level over the last 60 seconds")
        .accessibilityValue("\(DB.format(recorder.totalReadout)) dBFS")
    }

    private func geometry(_ size: CGSize, now: Double) -> (x: (Double) -> CGFloat, y: (Double) -> CGFloat, t0: Double, pw: CGFloat) {
        let pw = size.width - pad.l - pad.r
        let ph = size.height - pad.t - pad.b
        let t0 = now - LevelHistory.window
        return (
            { t in pad.l + CGFloat((t - t0) / LevelHistory.window) * pw },
            { db in pad.t + CGFloat(1 - DB.fraction(db)) * ph },
            t0, pw
        )
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, now: Double) {
        let g = geometry(size, now: now)
        let labelFont = Font.system(size: 10, design: .monospaced)

        for db in [-60.0, -40, -20, 0] {
            let y = (g.y(db)).rounded() + 0.5
            var line = Path()
            line.move(to: CGPoint(x: pad.l, y: y))
            line.addLine(to: CGPoint(x: size.width - pad.r, y: y))
            ctx.stroke(line, with: .color(Theme.grid), lineWidth: 1)
            let text = ctx.resolve(Text(db == 0 ? "0" : "−\(Int(abs(db)))").font(labelFont).foregroundStyle(Theme.ink3))
            ctx.draw(text, at: CGPoint(x: pad.l - 6, y: y), anchor: .trailing)
        }
        for (ago, label) in [(60.0, "60 s"), (45, "45 s"), (30, "30 s"), (15, "15 s"), (0, "now")] {
            let x = g.x(now - ago)
            let anchor: UnitPoint = ago == 60 ? .bottomLeading : ago == 0 ? .bottomTrailing : .bottom
            let text = ctx.resolve(Text(label).font(labelFont).foregroundStyle(Theme.ink3))
            ctx.draw(text, at: CGPoint(x: x, y: size.height - 2), anchor: anchor)
        }

        let pts = recorder.history.buckets(after: g.t0).map { CGPoint(x: g.x($0.t), y: g.y($0.db)) }
        guard pts.count > 1 else { return }
        var clipped = ctx
        clipped.clip(to: Path(CGRect(x: pad.l, y: 0, width: g.pw, height: size.height)))
        let base = g.y(DB.floor)

        var area = Path()
        area.move(to: CGPoint(x: pts[0].x, y: base))
        area.addLine(to: pts[0])
        curve(&area, pts)
        area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: base))
        area.closeSubpath()
        clipped.fill(area, with: .color(Theme.ink.opacity(0.1)))

        var line = Path()
        line.move(to: pts[0])
        curve(&line, pts)
        clipped.stroke(line, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        dot(&clipped, pts[pts.count - 1])

        if let hoverX, let s = sample(at: hoverX, size: size, now: now) {
            let x = g.x(s.t)
            var v = Path()
            v.move(to: CGPoint(x: x.rounded() + 0.5, y: pad.t))
            v.addLine(to: CGPoint(x: x.rounded() + 0.5, y: base))
            ctx.stroke(v, with: .color(Theme.ink3), lineWidth: 1)
            dot(&ctx, CGPoint(x: x, y: g.y(s.total.isFinite ? max(s.total, DB.floor) : DB.floor)))
        }
    }

    /// Quadratic curves through segment midpoints: smooth, and never overshoots the data.
    private func curve(_ path: inout Path, _ pts: [CGPoint]) {
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        path.addLine(to: pts[pts.count - 1])
    }

    private func dot(_ ctx: inout GraphicsContext, _ p: CGPoint) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Theme.section))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Theme.ink))
    }

    private func sample(at x: CGFloat, size: CGSize, now: Double) -> LevelHistory.Sample? {
        let g = geometry(size, now: now)
        let t = g.t0 + Double((x - pad.l) / g.pw) * LevelHistory.window
        return recorder.history.nearest(to: t)
    }

    private func tooltip(at x: CGFloat, size: CGSize, now: Double) -> (view: AnyView, x: CGFloat, y: CGFloat)? {
        guard let s = sample(at: x, size: size, now: now) else { return nil }
        let g = geometry(size, now: now)
        let ago = max(0, Int((now - s.t).rounded()))
        let strips = recorder.visibleStrips
        let view = VStack(alignment: .leading, spacing: 2) {
            Text(ago == 0 ? "now" : "\(ago) s ago").font(.system(size: 11)).foregroundStyle(Theme.ink3)
            row(nil, "Total", "\(DB.format(s.total)) dBFS")
            ForEach(strips) { strip in
                row(Theme.color(for: strip), StripView.title(strip), DB.format(s.levels[strip.id] ?? -.infinity))
            }
        }
        .frame(minWidth: 150, alignment: .leading)
        return (AnyView(view), g.x(s.t), g.y(s.total.isFinite ? max(s.total, DB.floor) : DB.floor))
    }

    private func row(_ color: Color?, _ name: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 9, height: 9) }
            Text(name)
            Spacer(minLength: 12)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }
}
