import AppKit
import SwiftUI

/// Colours from the approved mockup, each with its dark-mode counterpart.
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
    static let rec = Color(hex: 0xD03B3B)

    static let ink = Color(light: 0x10201D, dark: 0xEEF3F1)
    static let ink2 = Color(light: 0x3D4E4A, dark: 0xB8C5C1)
    static let ink3 = Color(light: 0x66756F, dark: 0x85938F)
    static let grid = Color(light: (0x10201D, 0.09), dark: (0xEEF3F1, 0.08))
    static let wellLine = Color(light: (0x10201D, 0.08), dark: (0xEEF3F1, 0.07))
    static let well = Color(light: (0xFFFFFF, 0.5), dark: (0x080C0E, 0.42))
    static let control = Color(light: (0xFFFFFF, 0.55), dark: (0xFFFFFF, 0.08))
    static let meterBg = Color(light: (0x10201D, 0.07), dark: (0x000000, 0.32))
    static let meterGap = Color(light: (0xFFFFFF, 0.6), dark: (0x0E1416, 0.8))
    static let zoneDim = 0.22

    // Wallpaper behind the glass: glass needs colour to refract.
    static let wallBase = Color(light: 0xDDE6DF, dark: 0x0E1618)
    static let wallA = Color(light: 0x9FD3C7, dark: 0x14544D)
    static let wallB = Color(light: 0xF5C79C, dark: 0x6A3A1D)
    static let wallC = Color(light: 0xC4DBA9, dark: 0x22402A)
    static let wallD = Color(light: 0xF0A493, dark: 0x5A2531)

    static func color(for strip: RecorderModel.Strip) -> Color { series[strip.colorIndex % series.count] }

    /// Meter zones like OBS: green to −20 dBFS, yellow to −9, red above.
    static let zones = LinearGradient(stops: [
        .init(color: good, location: 0), .init(color: good, location: 0.66667),
        .init(color: warn, location: 0.66667), .init(color: warn, location: 0.85),
        .init(color: crit, location: 0.85), .init(color: crit, location: 1),
    ], startPoint: .bottom, endPoint: .top)

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

/// Soft colour fields behind the window's glass panels.
struct Wallpaper: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Theme.wallBase
                blob(Theme.wallA, at: CGPoint(x: 0.12 * w, y: 0.18 * h), size: CGSize(width: 0.84 * w, height: 1.04 * h))
                blob(Theme.wallB, at: CGPoint(x: 0.88 * w, y: 0.12 * h), size: CGSize(width: 0.76 * w, height: 0.92 * h))
                blob(Theme.wallD, at: CGPoint(x: 0.78 * w, y: 0.88 * h), size: CGSize(width: 0.92 * w, height: 1.0 * h))
                blob(Theme.wallC, at: CGPoint(x: 0.20 * w, y: 0.92 * h), size: CGSize(width: 0.80 * w, height: 0.88 * h))
            }
        }
    }

    /// CSS `radial-gradient(rx ry at x y, color 0%, transparent 70%)`.
    private func blob(_ color: Color, at center: CGPoint, size: CGSize) -> some View {
        let r = max(size.width, size.height) / 2
        return RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: r * 0.7)
            .frame(width: r * 2, height: r * 2)
            .scaleEffect(x: size.width / (r * 2), y: size.height / (r * 2))
            .position(center)
    }
}

/// The mockup's panel: a Liquid Glass slab with a hairline rim.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(.init(top: 14, leading: 16, bottom: 16, trailing: 16))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func glassPanel(radius: CGFloat = 20) -> some View { modifier(GlassPanel(radius: radius)) }

    /// The mockup's inset "well" (stage cards, text fields).
    func well(radius: CGFloat = 16, fill: Color = Theme.control) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.wellLine, lineWidth: 1))
    }
}

/// Section heading used on every panel ("Total signal", "Mixer", "After recording").
struct PanelTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink2).kerning(0.24)
    }
}

/// SwiftUI's `State` property wrapper. In the macOS 27 SDK `@State` resolves to a compiler macro whose
/// plugin ships only with Xcode, so with the Command Line Tools we name the wrapper type directly.
typealias ViewState = SwiftUI.State
