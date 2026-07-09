import SwiftUI
import AppKit

extension Color {
    // Appearance-adaptive design tokens (dark / light). The dynamic NSColor
    // provider re-resolves whenever the effective appearance changes, so the
    // whole UI tracks the Preferences → Appearance choice (System/Light/Dark)
    // applied via `.preferredColorScheme`.
    static let bg_base    = dynamic(dark: "0d0d10", light: "f4f4f6")
    static let bg_panel   = dynamic(dark: "141418", light: "ffffff")
    static let bg_input   = dynamic(dark: "1c1c22", light: "ececf0")
    static let bg_hover   = dynamic(dark: NSColor(white: 1.0, alpha: 0.04),
                                    light: NSColor(white: 0.0, alpha: 0.05))
    static let bg_selected = Color(hex: "4d7fff").opacity(0.12)

    static let border_subtle = dynamic(dark: NSColor(white: 1.0, alpha: 0.06),
                                       light: NSColor(white: 0.0, alpha: 0.10))
    static let border_strong = dynamic(dark: NSColor(white: 1.0, alpha: 0.12),
                                       light: NSColor(white: 0.0, alpha: 0.18))

    static let text_primary   = dynamic(dark: "e4e4ea", light: "1b1b22")
    static let text_secondary = dynamic(dark: "6a6a74", light: "6a6a74")
    static let text_muted     = dynamic(dark: "3e3e48", light: "b4b4be")

    static let accent = Color(hex: "4d7fff")
    static let accent_hover = Color(hex: "6b94ff")
    static let accent_dim = Color(hex: "4d7fff").opacity(0.25)

    static let status_ok = Color(hex: "3ecf8e")
    static let status_warn = Color(hex: "f5a623")
    static let status_err = Color(hex: "f25c5c")

    /// Builds an appearance-adaptive Color from two hex strings.
    static func dynamic(dark: String, light: String) -> Color {
        dynamic(dark: NSColor(hexString: dark), light: NSColor(hexString: light))
    }

    /// Builds an appearance-adaptive Color from two NSColors (supports alpha).
    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    init(hex hexVal: str_hex) {
        let hex = hexVal.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
    
    func toHex() -> String {
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            return "ffffff"
        }
        let r = max(0, min(255, Int(rgbColor.redComponent * 255.0)))
        let g = max(0, min(255, Int(rgbColor.greenComponent * 255.0)))
        let b = max(0, min(255, Int(rgbColor.blueComponent * 255.0)))
        let a = max(0, min(255, Int(rgbColor.alphaComponent * 255.0)))
        if a == 255 {
            return String(format: "%02x%02x%02x", r, g, b)
        } else {
            return String(format: "%02x%02x%02x%02x", a, r, g, b)
        }
    }
}

typealias str_hex = String

extension NSColor {
    /// Parses "rgb", "rrggbb", or "aarrggbb" hex into an sRGB NSColor.
    convenience init(hexString hexVal: String) {
        let hex = hexVal.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                  blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    /// "rrggbb" for the receiver, converting to sRGB first. Robust against
    /// non-RGB source spaces (grayscale/catalog) so it never silently drops to a
    /// default — those fall back to reading the raw components directly.
    func toHexString() -> String {
        let c = usingColorSpace(.sRGB) ?? usingColorSpace(.deviceRGB) ?? self
        let r = max(0, min(255, Int((c.redComponent * 255).rounded())))
        let g = max(0, min(255, Int((c.greenComponent * 255).rounded())))
        let b = max(0, min(255, Int((c.blueComponent * 255).rounded())))
        return String(format: "%02x%02x%02x", r, g, b)
    }

    /// Appearance-adaptive base window background (matches `Color.bg_base`), so
    /// NSWindow chrome behind the SwiftUI content follows the app theme (MAS-72).
    static var pathstitchWindowBackground: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hexString: "0d0d10")
                : NSColor(hexString: "f4f4f6")
        }
    }
}

struct PlasticityFont {
    static let label = Font.system(size: 11)
    static let body = Font.system(size: 12)
    static let header = Font.system(size: 13).weight(.medium)
}

struct EdgeBorder: Shape {
    var width: CGFloat
    var edges: [Edge]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            switch edge {
            case .top:
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            case .bottom:
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            case .leading:
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            case .trailing:
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            }
        }
        return path
    }
}

extension View {
    func border(width: CGFloat, edges: [Edge], color: Color) -> some View {
        overlay(EdgeBorder(width: width, edges: edges).stroke(color, lineWidth: width))
    }
}

