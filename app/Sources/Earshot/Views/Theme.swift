import AppKit
import SwiftUI

/// Standard macOS colours (they follow light/dark mode and accessibility settings), plus the data
/// colours from the approved mockup for sources and meter zones.
enum Theme {
    static let seriesSys = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let seriesMic = Color(light: 0xEB6834, dark: 0xD95926)
    static let series3 = Color(light: 0x1BAF7A, dark: 0x199E70)
    static let series4 = Color(light: 0xEDA100, dark: 0xC98500)
    static let series5 = Color(light: 0xE87BA4, dark: 0xD55181)
    static let series = [seriesSys, seriesMic, series3, series4, series5]

    static let good = Color(hex: 0x0CA30C)
    static let warn = Color(hex: 0xFAB219)
    static let crit = Color(hex: 0xD03B3B)
    static let rec = Color(nsColor: .systemRed)

    static let ink = Color(nsColor: .labelColor)
    static let ink2 = Color(nsColor: .secondaryLabelColor)
    static let ink3 = Color(nsColor: .tertiaryLabelColor)
    static let grid = Color(nsColor: .separatorColor)
    static let wellLine = Color(nsColor: .separatorColor)
    /// Section background: opaque, like the grouped boxes in System Settings' content area, so the
    /// frosted window shows only around the sections.
    static let section = Color(light: 0xFFFFFF, dark: 0x2B2B2D)
    /// Cards inside a section (pipeline stages): a slightly inset shade of the section.
    static let control = Color(light: 0xF5F5F7, dark: 0x232325)
    static let well = Color(nsColor: .textBackgroundColor)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let meterBg = Color(light: (0x000000, 0.07), dark: (0x000000, 0.35))
    static let meterGap = Color(light: (0xFFFFFF, 0.75), dark: (0x2B2B2D, 0.9))
    static let zoneDim = 0.22

    static func color(for strip: RecorderModel.Strip) -> Color { series[strip.colorIndex % series.count] }

    /// Meter zones like OBS: green to −20 dBFS, yellow to −9, red above.
    static let zones = LinearGradient(stops: [
        .init(color: good, location: 0), .init(color: good, location: 0.66667),
        .init(color: warn, location: 0.66667), .init(color: warn, location: 0.85),
        .init(color: crit, location: 0.85), .init(color: crit, location: 1),
    ], startPoint: .bottom, endPoint: .top)

    /// The same zones left to right, for the mixer's horizontal meters.
    static let zonesHorizontal = LinearGradient(stops: [
        .init(color: good, location: 0), .init(color: good, location: 0.66667),
        .init(color: warn, location: 0.66667), .init(color: warn, location: 0.85),
        .init(color: crit, location: 0.85), .init(color: crit, location: 1),
    ], startPoint: .leading, endPoint: .trailing)

    static let mono = Font.system(size: 13, design: .monospaced)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }

    init(light: UInt32, dark: UInt32) {
        self.init(light: (light, 1), dark: (dark, 1))
    }

    init(light: (UInt32, Double), dark: (UInt32, Double)) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (hex, alpha) = isDark ? dark : light
            return NSColor(hex: hex, alpha: alpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    /// A grouped section: subtle fill and hairline border, as in System Settings.
    func panel(radius: CGFloat = 10) -> some View {
        padding(.init(top: 12, leading: 14, bottom: 14, trailing: 14))
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.section))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.wellLine, lineWidth: 0.5))
    }

    /// A card inside a section (pipeline stages).
    func well(radius: CGFloat = 8, fill: Color = Theme.control) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.wellLine, lineWidth: 0.5))
    }
}

/// Section heading used on every panel ("Total signal", "Mixer", "After recording").
struct PanelTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.headline)
    }
}

/// SwiftUI's `State` property wrapper. In the macOS 27 SDK `@State` resolves to a compiler macro whose
/// plugin ships only with Xcode, so with the Command Line Tools we name the wrapper type directly.
typealias ViewState = SwiftUI.State
