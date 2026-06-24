import Foundation
import Observation

/// One pricking / stitching iron. The `shape` is the slit cross-section that each
/// stitch is punched as; `pitch` is the iron's stitch spacing; `slitLength` /
/// `slitWidth` size the slit and `angle` rotates it relative to the stitch line.
struct PrickingIron: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var shape: String          // diamond | french | round | flat | oval
    var pitch: Double
    var bladeCount: Int
    var slitLength: Double
    var slitWidth: Double
    var angle: Double
    var inverted: Bool
    var builtin: Bool

    init(id: String, name: String, shape: String, pitch: Double, bladeCount: Int,
         slitLength: Double, slitWidth: Double, angle: Double = 0,
         inverted: Bool = false, builtin: Bool = false) {
        self.id = id; self.name = name; self.shape = shape; self.pitch = pitch
        self.bladeCount = bladeCount; self.slitLength = slitLength
        self.slitWidth = slitWidth; self.angle = angle; self.inverted = inverted
        self.builtin = builtin
    }
}

private struct PrickingIronFile: Codable {
    var version: Int
    var irons: [PrickingIron]
}

/// Loads the built-in iron catalog (bundled `pricking_irons.json`, with a compiled
/// fallback so the app never ships without irons) and merges user irons saved to
/// Application Support. New / edited / deleted user irons round-trip to disk.
@Observable
final class PrickingIronStore {
    static let shared = PrickingIronStore()

    private(set) var builtins: [PrickingIron] = []
    private(set) var userIrons: [PrickingIron] = []

    var all: [PrickingIron] { builtins + userIrons }

    private init() {
        builtins = Self.loadBuiltins()
        userIrons = Self.loadUserIrons()
    }

    func iron(id: String) -> PrickingIron? { all.first { $0.id == id } }

    /// Add or replace a user iron and persist. Built-ins are never modified.
    func save(_ iron: PrickingIron) {
        var copy = iron
        copy.builtin = false
        if let idx = userIrons.firstIndex(where: { $0.id == copy.id }) {
            userIrons[idx] = copy
        } else {
            userIrons.append(copy)
        }
        persist()
    }

    func delete(id: String) {
        userIrons.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Persistence

    private static func appSupportURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Pathstitch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pricking_irons.json")
    }

    private static func loadBuiltins() -> [PrickingIron] {
        if let url = Bundle.main.url(forResource: "pricking_irons", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(PrickingIronFile.self, from: data),
           !file.irons.isEmpty {
            return file.irons.map { var i = $0; i.builtin = true; return i }
        }
        return embeddedDefaults
    }

    private static func loadUserIrons() -> [PrickingIron] {
        guard let url = appSupportURL(), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PrickingIronFile.self, from: data)
        else { return [] }
        return file.irons.map { var i = $0; i.builtin = false; return i }
    }

    private func persist() {
        guard let url = Self.appSupportURL() else { return }
        let file = PrickingIronFile(version: 1, irons: userIrons)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Compiled-in fallback so the toolbox is never empty even if the bundled JSON
    /// is missing. Mirrors the common irons in `pricking_irons.json`.
    static let embeddedDefaults: [PrickingIron] = [
        PrickingIron(id: "diamond-3.0",  name: "Diamond 3.0 mm",  shape: "diamond", pitch: 3.0,  bladeCount: 6, slitLength: 2.2, slitWidth: 0.8,  builtin: true),
        PrickingIron(id: "diamond-3.85", name: "Diamond 3.85 mm", shape: "diamond", pitch: 3.85, bladeCount: 6, slitLength: 2.7, slitWidth: 0.9,  builtin: true),
        PrickingIron(id: "diamond-4.0",  name: "Diamond 4.0 mm",  shape: "diamond", pitch: 4.0,  bladeCount: 6, slitLength: 2.8, slitWidth: 0.95, builtin: true),
        PrickingIron(id: "french-3.0",   name: "French 3.0 mm",   shape: "french",  pitch: 3.0,  bladeCount: 6, slitLength: 2.2, slitWidth: 0.7,  builtin: true),
        PrickingIron(id: "round-1.0",    name: "Round punch 1.0 mm", shape: "round", pitch: 4.0, bladeCount: 1, slitLength: 1.0, slitWidth: 1.0, builtin: true),
        PrickingIron(id: "flat-4.0",     name: "Lacing flat 4.0 mm", shape: "flat",  pitch: 5.0, bladeCount: 4, slitLength: 3.2, slitWidth: 0.6, builtin: true),
    ]
}
