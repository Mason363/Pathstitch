import SwiftUI

extension Color {
    static let bg_base = Color(hex: "0d0d10")
    static let bg_panel = Color(hex: "141418")
    static let bg_input = Color(hex: "1c1c22")
    static let bg_hover = Color(white: 1.0, opacity: 0.04)
    static let bg_selected = Color(hex: "4d7fff").opacity(0.12)
    
    static let border_subtle = Color(white: 1.0, opacity: 0.06)
    static let border_strong = Color(white: 1.0, opacity: 0.12)
    
    static let text_primary = Color(hex: "e4e4ea")
    static let text_secondary = Color(hex: "6a6a74")
    static let text_muted = Color(hex: "3e3e48")
    
    static let accent = Color(hex: "4d7fff")
    static let accent_hover = Color(hex: "6b94ff")
    static let accent_dim = Color(hex: "4d7fff").opacity(0.25)
    
    static let status_ok = Color(hex: "3ecf8e")
    static let status_warn = Color(hex: "f5a623")
    static let status_err = Color(hex: "f25c5c")
    
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
}

typealias str_hex = String

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

