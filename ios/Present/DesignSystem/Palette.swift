import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

extension Color {
    /// A colour that adapts to light and dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

/// Warm, neutral palette. Everything in the UI should draw from here.
enum Palette {
    static let background = Color(light: 0xF5EFE6, dark: 0x1B1916)
    static let surface = Color(light: 0xFBF8F3, dark: 0x24211D)
    static let elevated = Color(light: 0xFFFFFF, dark: 0x2C2823).opacity(0.7)
    static let ink = Color(light: 0x2B2622, dark: 0xEEE6DA)
    static let secondaryInk = Color(light: 0x7A6E63, dark: 0xA89C8E)
    static let hairline = Color(light: 0xE4DACD, dark: 0x3A342D)
    static let accent = Color(light: 0xB5795A, dark: 0xD29B79)
    static let accentSoft = Color(light: 0xE9D5C3, dark: 0x4A3A2E)
    static let sage = Color(light: 0x8C9A80, dark: 0x9FAE93)
    static let onAccent = Color(light: 0xFFFBF6, dark: 0x1B1916)

    static let uiBackground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1B1916) : UIColor(hex: 0xF5EFE6) }
    static let uiInk = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xEEE6DA) : UIColor(hex: 0x2B2622) }
    static let uiAccent = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xD29B79) : UIColor(hex: 0xB5795A) }
}

/// Typography: New York (serif) for titles, SF Pro for everything else.
/// All styles are built on text styles so Dynamic Type is respected.
enum Typography {
    static let display = Font.system(.largeTitle, design: .serif, weight: .regular)
    static let title = Font.system(.title, design: .serif, weight: .regular)
    static let title2 = Font.system(.title2, design: .serif, weight: .regular)
    static let title3 = Font.system(.title3, design: .serif, weight: .regular)
    static let reflection = Font.system(.title2, design: .serif, weight: .regular).italic()
    static let body = Font.system(.body)
    static let callout = Font.system(.callout)
    static let caption = Font.system(.footnote)
    static let eyebrow = Font.system(.caption, design: .default, weight: .medium)
}

enum Motion {
    static let gentle = Animation.easeInOut(duration: 0.6)
}

extension View {
    /// Applies the app's warm background behind a screen.
    func presentBackground() -> some View {
        background(Palette.background.ignoresSafeArea())
    }

    /// Small-caps style label used above titles.
    func eyebrowStyle() -> some View {
        font(Typography.eyebrow)
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(Palette.secondaryInk)
    }
}
