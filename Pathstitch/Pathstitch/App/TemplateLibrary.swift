import Foundation
import Observation

/// A real-world object template inserted as a guide to design around (a wallet's
/// card slot, a phone sleeve, a coin pocket). Dimensions are in millimetres.
struct DesignTemplate: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var category: String
    var shape: String          // rect | roundedRect | circle | polygon
    var width: Double?
    var height: Double?
    var radius: Double?        // corner radius for roundedRect
    var diameter: Double?      // for circle / polygon (circumscribed)
    var sides: Int?            // for polygon
    var note: String?

    /// Human-readable size, e.g. "85.6 × 53.98 mm" or "Ø24.26 mm".
    var dimensionLabel: String {
        if shape == "circle" || shape == "polygon", let d = diameter {
            return String(format: "Ø%.2f mm", d)
        }
        if let w = width, let h = height {
            return String(format: "%.2f × %.2f mm", w, h)
        }
        return ""
    }
}

private struct TemplateFile: Codable {
    var version: Int
    var templates: [DesignTemplate]
}

/// Loads the bundled `templates.json` catalog (with a compiled fallback) and
/// merges user templates saved to Application Support.
@Observable
final class TemplateStore {
    static let shared = TemplateStore()

    private(set) var builtins: [DesignTemplate] = []
    private(set) var userTemplates: [DesignTemplate] = []

    var all: [DesignTemplate] { builtins + userTemplates }

    /// Distinct categories in display order (built-ins first, "My Templates" last).
    var categories: [String] {
        var seen: [String] = []
        for t in all where !seen.contains(t.category) { seen.append(t.category) }
        return seen
    }

    func templates(in category: String) -> [DesignTemplate] {
        all.filter { $0.category == category }
    }

    private init() {
        builtins = Self.loadBuiltins()
        userTemplates = Self.loadUser()
    }

    func saveUserTemplate(_ t: DesignTemplate) {
        var copy = t
        copy.category = "My Templates"
        if let idx = userTemplates.firstIndex(where: { $0.id == copy.id }) {
            userTemplates[idx] = copy
        } else {
            userTemplates.append(copy)
        }
        persist()
    }

    func deleteUserTemplate(id: String) {
        userTemplates.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Persistence

    private static func appSupportURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Pathstitch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("templates.json")
    }

    private static func loadBuiltins() -> [DesignTemplate] {
        if let url = Bundle.main.url(forResource: "templates", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(TemplateFile.self, from: data),
           !file.templates.isEmpty {
            return file.templates
        }
        return embeddedDefaults
    }

    private static func loadUser() -> [DesignTemplate] {
        guard let url = appSupportURL(), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(TemplateFile.self, from: data)
        else { return [] }
        return file.templates
    }

    private func persist() {
        guard let url = Self.appSupportURL() else { return }
        let file = TemplateFile(version: 1, templates: userTemplates)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Minimal compiled fallback so the gallery is never empty.
    static let embeddedDefaults: [DesignTemplate] = [
        DesignTemplate(id: "card-credit", name: "Credit / Bank Card", category: "Cards",
                       shape: "roundedRect", width: 85.6, height: 53.98, radius: 3.18,
                       diameter: nil, sides: nil, note: "ISO/IEC 7810 ID-1"),
        DesignTemplate(id: "note-usd", name: "US Dollar (any)", category: "Banknotes",
                       shape: "rect", width: 156.0, height: 66.3, radius: nil,
                       diameter: nil, sides: nil, note: "All US denominations"),
        DesignTemplate(id: "coin-us-quarter", name: "US Quarter (25¢)", category: "Coins",
                       shape: "circle", width: nil, height: nil, radius: nil,
                       diameter: 24.26, sides: nil, note: "US"),
        DesignTemplate(id: "paper-a4", name: "A4", category: "Paper",
                       shape: "rect", width: 210.0, height: 297.0, radius: nil,
                       diameter: nil, sides: nil, note: "ISO 216"),
    ]
}
