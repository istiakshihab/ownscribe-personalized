import SwiftUI

/// The mixer as slim rows, one per source (OBS's horizontal layout): meter, level, fader and mute on
/// one line, so the mixer costs about 30 pt of height per source instead of a full-height column.
/// It sits under the signal chart, in the same panel. Past four sources the rows scroll.
struct MixerRows: View {
    let recorder: RecorderModel

    static let rowHeight: CGFloat = 30
    static let spacing: CGFloat = 4
    static let visibleRows = 4

    var body: some View {
        let strips = recorder.visibleStrips
        let rows = VStack(spacing: Self.spacing) {
            ForEach(strips) { strip in
                MixerRow(recorder: recorder, strip: strip)
                    .frame(height: Self.rowHeight)
                    .id(strip.id)
            }
        }
        if strips.count > Self.visibleRows {
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .frame(height: CGFloat(Self.visibleRows) * (Self.rowHeight + Self.spacing) - Self.spacing)
                    .onChange(of: strips.count) { old, new in
                        if new > old, let last = strips.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
            }
        } else {
            rows
        }
    }
}

/// "+ Add source": running apps from `ownscribe-audio list-apps --json`, in a popover.
struct AddSourceButton: View {
    let recorder: RecorderModel
    @ViewState private var showAdd = false

    var body: some View {
        Button {
            showAdd.toggle()
        } label: {
            Label("Add source", systemImage: "plus")
        }
        .controlSize(.small)
        .disabled(recorder.phase == .starting || recorder.phase == .stopping)
        .popover(isPresented: $showAdd, arrowEdge: .bottom) {
            AddSourceList(recorder: recorder) { showAdd = false }
        }
    }
}

/// One source: colour dot and name, a horizontal meter, its level, the fader, gain and mute.
struct MixerRow: View {
    let recorder: RecorderModel
    let strip: RecorderModel.Strip

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
        let title = Self.title(strip)
        HStack(spacing: 10) {
            Circle().fill(Theme.color(for: strip)).frame(width: 8, height: 8)
                .opacity(dim ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            .help("\(title) · \(subtitle)")

            HorizontalMeter(level: strip.level, peak: strip.peak, muted: dim)
                .frame(minWidth: 100, maxWidth: .infinity)
                .frame(height: 8)
                .accessibilityElement()
                .accessibilityLabel("\(title) level")
                .accessibilityValue("\(DB.format(strip.readout)) dB")

            Group {
                if strip.state == "lost" {
                    Chip(text: "Lost")
                } else if micSilent {
                    Chip(text: "No signal")
                } else {
                    Text(strip.muted ? "Muted" : "\(DB.format(strip.readout)) dB")
                        .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(strip.muted ? Theme.ink3 : Theme.ink)
                }
            }
            .frame(width: 84, alignment: .trailing)

            Slider(value: Binding(get: { strip.gainDb }, set: { recorder.setGain(strip.id, Self.snap($0)) }),
                   in: -60...6, step: 0.5) { editing in
                if !editing { recorder.setGain(strip.id, strip.gainDb, final: true) }
            }
            .controlSize(.small)
            .frame(width: 120)
            .accessibilityLabel("\(title) volume")
            .accessibilityValue(DB.formatGain(strip.gainDb) + " dB")

            Text(DB.formatGain(strip.gainDb) + " dB")
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                .foregroundStyle(Theme.ink2)
                .frame(width: 58, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { recorder.setGain(strip.id, 0, final: true) }
                .help("Fader gain · double-click for 0 dB")

            MuteButton(muted: strip.muted, compact: true, label: title) { recorder.toggleMute(strip.id) }

            // Apps can be removed; the column stays so the rows line up.
            Group {
                if strip.isApp {
                    Button {
                        recorder.removeApp(strip)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ink3)
                    .help("Remove \(title)")
                    .accessibilityLabel("Remove \(title)")
                } else {
                    Color.clear
                }
            }
            .frame(width: 18)
        }
    }

    /// A detent at unity, so 0 dB is easy to hit.
    static func snap(_ db: Double) -> Double { abs(db) < 0.75 ? 0 : db }
}

/// Horizontal LED meter: dim zone colours along the scale, the lit level, and a peak-hold tick.
struct HorizontalMeter: View {
    let level: Double
    let peak: Double
    let muted: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lvl = DB.fraction(level)
            let pk = DB.fraction(peak)
            ZStack(alignment: .leading) {
                Theme.meterBg
                Theme.zonesHorizontal.opacity(Theme.zoneDim)
                Theme.zonesHorizontal
                    .mask(alignment: .leading) { Rectangle().frame(width: w * lvl) }
                    .saturation(muted ? 0 : 1)
                    .opacity(muted ? 0.4 : 1)
                Canvas { ctx, size in
                    var x: CGFloat = 4
                    while x < size.width {
                        ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Theme.meterGap))
                        x += 5
                    }
                }
                if pk > 0 {
                    Rectangle().fill(Theme.ink).frame(width: 2)
                        .opacity(muted ? 0.25 : 0.75)
                        .offset(x: w * pk - 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
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
