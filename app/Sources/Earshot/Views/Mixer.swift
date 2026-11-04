import SwiftUI

/// OBS-style vertical mixer: one strip per source. Strips get narrower as sources are added and the
/// row scrolls sideways past four, inside a fixed width, so the chart keeps its space.
struct MixerPanel: View {
    let recorder: RecorderModel
    @ViewState private var showAdd = false

    static let meterHeight: CGFloat = 196
    static let maxRowWidth: CGFloat = 440

    var body: some View {
        let strips = recorder.visibleStrips
        let width = Self.stripWidth(count: strips.count)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PanelTitle(text: "Mixer")
                Spacer(minLength: 12)
                Button {
                    showAdd.toggle()
                } label: {
                    Label("Add source", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                }
                .controlSize(.small)
                .disabled(recorder.phase == .starting || recorder.phase == .stopping)
                .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                    AddSourceList(recorder: recorder) { showAdd = false }
                }
            }
            let row = HStack(alignment: .top, spacing: 0) {
                ForEach(Array(strips.enumerated()), id: \.element.id) { index, strip in
                    StripView(recorder: recorder, strip: strip, first: index == 0, compact: strips.count >= 3,
                              twoLineNames: strips.count >= 3)
                        .frame(width: width + (index == 0 ? 32 : 0))
                        .padding(.leading, index == 0 ? 0 : 12)
                        .overlay(alignment: .leading) {
                            if index > 0 { Rectangle().fill(Theme.wellLine).frame(width: 1) }
                        }
                        .padding(.leading, index == 0 ? 0 : 12)
                        .id(strip.id)
                }
            }
            let natural = Self.rowWidth(count: strips.count)
            if natural > Self.maxRowWidth {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) { row.padding(.bottom, 6) }
                        .scrollIndicators(.visible)
                        .frame(width: Self.maxRowWidth)
                        .onChange(of: strips.count) { old, new in
                            if new > old, let last = strips.last { withAnimation { proxy.scrollTo(last.id, anchor: .trailing) } }
                        }
                }
            } else {
                row.frame(width: natural, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panel()
    }

    /// Roomy for two, tighter for three, compact from four.
    static func stripWidth(count: Int) -> CGFloat { count <= 2 ? 112 : count == 3 ? 96 : 84 }

    static func rowWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * stripWidth(count: count) + 32 + CGFloat(count - 1) * 24
    }
}

struct StripView: View {
    let recorder: RecorderModel
    let strip: RecorderModel.Strip
    let first: Bool
    let compact: Bool
    let twoLineNames: Bool

    static func title(_ strip: RecorderModel.Strip) -> String {
        switch strip.kind {
        case "system": return "System audio"
        case "mic": return "Microphone"
        case "test": return strip.id == "sys" ? "System audio" : strip.id == "mic" ? "Microphone" : strip.name
        default: return strip.name
        }
    }

    private var subtitle: String {
        if strip.state == "pending" { return "Starts with the recording" }
        if strip.state == "lost" { return "Reconnecting…" }
        switch strip.id {
        case "sys": return recorder.appStrips.isEmpty ? "All apps" : "Other apps"
        case "mic":
            if recorder.phase == .recording || recorder.phase == .stopping {
                return recorder.micInfo?.name ?? (strip.name == "Microphone" ? micPrediction : strip.name)
            }
            return micPrediction
        default: return strip.kind == "test" ? "Test tone" : "App audio"
        }
    }

    private var micPrediction: String {
        if case let .device(uid) = recorder.micChoice, let d = recorder.devices.first(where: { $0.uid == uid }) { return d.name }
        return recorder.predictedAutoDevice?.name ?? "Default input"
    }

    private var micSilent: Bool {
        strip.kind == "mic" && recorder.phase == .recording && !strip.muted &&
            (strip.micSilentFor >= 5 || recorder.notices.contains { $0.code == "mic_silent" })
    }

    var body: some View {
        let dim = strip.muted || strip.state == "lost"
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: twoLineNames ? .top : .center, spacing: 7) {
                    Circle().fill(Theme.color(for: strip)).frame(width: 9, height: 9)
                        .opacity(dim ? 0.35 : 1)
                        .padding(.top, twoLineNames ? 4 : 0)
                    Text(Self.title(strip))
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .lineLimit(twoLineNames ? 2 : 1)
                        .minimumScaleFactor(0.8)  // shrink a long single word rather than break it
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if strip.isApp {
                        Button {
                            recorder.removeApp(strip)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .frame(width: 20, height: 20)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ink3)
                        .help("Remove \(Self.title(strip))")
                        .accessibilityLabel("Remove \(Self.title(strip))")
                    }
                }
                // Same height on every strip, so the meters line up.
                .frame(height: twoLineNames ? 32 : 20, alignment: .topLeading)
                Text(subtitle)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, twoLineNames ? 0 : 16)
            }

            HStack(spacing: 6) {
                if strip.state == "lost" {
                    Chip(text: "Lost")
                } else if micSilent {
                    Chip(text: "No signal")
                } else {
                    Text(strip.muted ? "Muted" : "\(DB.format(strip.readout)) dB")
                        .font(Theme.mono).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 20)

            HStack(spacing: 8) {
                if first { ScaleView().frame(width: 24) }
                MeterView(level: strip.level, peak: strip.peak, muted: dim)
                    .frame(width: 14)
                    .accessibilityElement()
                    .accessibilityLabel("\(Self.title(strip)) level")
                    .accessibilityValue("\(DB.format(strip.readout)) dB")
                VerticalFader(value: Binding(get: { strip.gainDb }, set: { recorder.setGain(strip.id, $0) }),
                              onEnd: { recorder.setGain(strip.id, $0, final: true) },
                              label: "\(Self.title(strip)) volume")
                    .frame(width: 30)
            }
            .frame(height: MixerPanel.meterHeight)
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                MuteButton(muted: strip.muted, compact: compact, label: Self.title(strip)) { recorder.toggleMute(strip.id) }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    if !compact { Text("Fader").font(.system(size: 10.5)).foregroundStyle(Theme.ink3) }
                    Text(DB.formatGain(strip.gainDb) + (compact ? "" : " dB"))
                        .font(.system(size: compact ? 11 : 12, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                }
            }
        }
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.ink, Theme.warn)
                .font(.system(size: 10))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 1)
        .background(Capsule().fill(Theme.control))
        .overlay(Capsule().strokeBorder(Theme.wellLine))
    }
}

struct MuteButton: View {
    let muted: Bool
    let compact: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        // A plain bordered button; muted shows a red crossed-out speaker (red, not the accent colour,
        // so it stays visible when the window isn't key).
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(muted ? Theme.rec : Theme.ink)
                .frame(width: compact ? 14 : 18)
        }
        .controlSize(compact ? .small : .regular)
        .help(muted ? "Unmute \(label)" : "Mute \(label)")
        .accessibilityLabel(muted ? "Unmute \(label)" : "Mute \(label)")
    }
}

/// LED-style meter: dim zone colours along the scale, the lit level, and a peak-hold line.
struct MeterView: View {
    let level: Double
    let peak: Double
    let muted: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let lvl = DB.fraction(level)
            let pk = DB.fraction(peak)
            ZStack(alignment: .bottom) {
                Theme.meterBg
                Theme.zones.opacity(Theme.zoneDim)
                Theme.zones
                    .mask(alignment: .bottom) { Rectangle().frame(height: h * lvl) }
                    .saturation(muted ? 0 : 1)
                    .opacity(muted ? 0.4 : 1)
                Canvas { ctx, size in
                    var y = size.height - 4
                    while y > 0 {
                        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Theme.meterGap))
                        y -= 5
                    }
                }
                if pk > 0 {
                    Rectangle().fill(Theme.ink).frame(height: 2)
                        .opacity(muted ? 0.25 : 0.75)
                        .offset(y: -(h * pk) + 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

/// One dB scale for the whole row, on the first strip.
struct ScaleView: View {
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ForEach([(-60.0, "−60"), (-40, "−40"), (-20, "−20"), (-9, "−9"), (0, "0")], id: \.0) { db, label in
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 24, alignment: .trailing)
                    .position(x: 12, y: min(max(h * (1 - DB.fraction(db)), 6), h - 6))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Vertical fader, −∞ (−60) to +6 dB, drawn like a system slider. Double-click returns it to 0 dB.
struct VerticalFader: View {
    @Binding var value: Double
    var onEnd: (Double) -> Void
    let label: String
    static let range = -60.0...6.0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let thumbH: CGFloat = 14
            let travel = h - thumbH
            let frac = (value - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)
            let thumbY = travel * (1 - frac)
            ZStack(alignment: .top) {
                Capsule().fill(Theme.meterBg)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                Capsule().fill(Color.accentColor)
                    .frame(width: 4, height: max(0, h - thumbY - thumbH / 2))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                // 0 dB tick
                Rectangle().fill(Theme.ink3).frame(width: 12, height: 1)
                    .offset(y: travel * (1 - (0 - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)) + thumbH / 2)
                Capsule()
                    .fill(Color(light: 0xFFFFFF, dark: 0xD2D2D2))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: 24, height: thumbH)
                    .offset(y: thumbY)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in value = Self.value(at: g.location.y, height: h, thumb: thumbH) }
                    .onEnded { g in onEnd(Self.value(at: g.location.y, height: h, thumb: thumbH)) }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                value = 0
                onEnd(0)
            })
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(DB.formatGain(value) + " dB")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 : -1.0
            let next = min(max(value + step, Self.range.lowerBound), Self.range.upperBound)
            value = next
            onEnd(next)
        }
        .help("\(label): \(DB.formatGain(value)) dB · double-click for 0 dB")
    }

    static func value(at y: CGFloat, height: CGFloat, thumb: CGFloat) -> Double {
        let travel = max(1, height - thumb)
        let frac = 1 - Double(min(max((y - thumb / 2) / travel, 0), 1))
        var db = range.lowerBound + frac * (range.upperBound - range.lowerBound)
        if abs(db) < 0.75 { db = 0 }  // detent at unity
        return (db * 2).rounded() / 2
    }
}

/// "Add source": running apps from `ownscribe-audio list-apps --json`.
struct AddSourceList: View {
    let recorder: RecorderModel
    let close: () -> Void

    var body: some View {
        let added = Set(recorder.appStrips.compactMap(\.bundleID))
        let apps = recorder.apps.filter { !added.contains($0.bundleID) }
        VStack(alignment: .leading, spacing: 2) {
            Text("Give an app its own source")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            if recorder.appsLoading && recorder.apps.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
            } else if apps.isEmpty {
                Text("No other apps are running.").font(.system(size: 12)).foregroundStyle(Theme.ink3).padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(apps) { app in
                            OptionRow(title: app.name,
                                      subtitle: !app.canSplit ? "Plays through WebKit, so it can't be split out"
                                          : app.playing ? "Playing audio now" : "App audio",
                                      selected: nil, leading: AnyView(Image(systemName: app.playing ? "speaker.wave.2.fill" : "app.dashed")
                                          .font(.system(size: 11)).foregroundStyle(app.playing ? Theme.series3 : Theme.ink3)))
                            {
                                recorder.addApp(app)
                                close()
                            }
                            .disabled(!app.canSplit)
                            .opacity(app.canSplit ? 1 : 0.5)
                        }
                    }
                }
                .frame(height: min(CGFloat(apps.count) * 48, 360))
            }
        }
        .padding(6)
        .frame(width: 260)
        .task { await recorder.refreshApps() }
    }
}

/// A menu-like row with a checkmark, title and subtitle (pickers and the add-source list).
struct OptionRow: View {
    let title: String
    var subtitle: String?
    var selected: Bool?
    var leading: AnyView?
    let action: () -> Void
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if let leading { leading } else {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.accentColor).opacity(selected == true ? 1 : 0)
                    }
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).padding(.leading, 8).padding(.trailing, 10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Theme.control : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected == true ? .isSelected : [])
    }
}
