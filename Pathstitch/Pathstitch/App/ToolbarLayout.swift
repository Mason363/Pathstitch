import SwiftUI
import AppKit

/// Where a toolbar item currently lives (MAS-99). The user can Command-drag items
/// between these three containers (or use the right-click "Move to…" menu), and
/// the placement persists across launches.
enum ToolbarContainer: String, Codable {
    case main    // the always-visible left sidebar
    case extra   // the "More tools" (•••) flyout
    case shapes  // the Shapes (△) flyout
}

/// What a toolbar item does when clicked. Tools switch `currentTool`; the rest are
/// one-shot actions on the current selection.
enum ToolbarItemKind: Equatable {
    case tool(TwoDTool)
    case flipH
    case flipV
    case duplicate
}

/// Functional zone of a main-toolbar item (MAS-117). Items are grouped into these
/// zones and a thin divider is drawn between zones in the sidebar.
enum ToolbarZone: Int, Comparable {
    case selection = 0   // Select, Move, Pan
    case modify = 1      // Offset, Holes, Cleanup, Trim
    case precision = 2   // Measure, Fillet, Chamfer
    case creation = 3    // Shapes, Patterning, Paper

    static func < (l: ToolbarZone, r: ToolbarZone) -> Bool { l.rawValue < r.rawValue }
}

/// Static metadata for one draggable toolbar item.
struct ToolbarItemDef: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    /// Items that originate in the Shapes flyout — only these may be placed back
    /// into Shapes. Everything else is barred from the Shapes container (MAS-99).
    let shapesOrigin: Bool
    let kind: ToolbarItemKind
    /// Functional zone for divider grouping in the main sidebar (MAS-117).
    var zone: ToolbarZone = .modify
}

/// The registry of every organizable toolbar item, keyed by a stable id.
enum ToolbarRegistry {
    static let all: [ToolbarItemDef] = [
        // — Main tools — (zones drive the MAS-117 divider grouping)
        .init(id: "select",       title: "Select",        icon: "cursorarrow",                                    shapesOrigin: false, kind: .tool(.select),       zone: .selection),
        .init(id: "move",         title: "Move",          icon: "arrow.up.and.down.and.arrow.left.and.right",     shapesOrigin: false, kind: .tool(.move),         zone: .selection),
        .init(id: "pan",          title: "Pan",           icon: "hand.raised",                                    shapesOrigin: false, kind: .tool(.pan),          zone: .selection),
        .init(id: "scale",        title: "Scale",         icon: "arrow.up.left.and.arrow.down.right",             shapesOrigin: false, kind: .tool(.scale),        zone: .selection),
        .init(id: "offset",       title: "Offset",        icon: "arrow.up.and.down",                              shapesOrigin: false, kind: .tool(.offset),       zone: .modify),
        .init(id: "addThickness", title: "Add Thickness", icon: "rectangle.expand.vertical",                      shapesOrigin: false, kind: .tool(.addThickness), zone: .modify),
        .init(id: "addHoles",     title: "Add Holes",     icon: "circle.dashed",                                  shapesOrigin: false, kind: .tool(.addHoles),     zone: .modify),
        .init(id: "cleanup",      title: "Cleanup",       icon: "sparkles",                                       shapesOrigin: false, kind: .tool(.cleanup),      zone: .modify),
        .init(id: "trim",         title: "Trim",          icon: "scissors.badge.ellipsis",                        shapesOrigin: false, kind: .tool(.trim),         zone: .modify),
        .init(id: "measure",      title: "Measure",       icon: "ruler",                                          shapesOrigin: false, kind: .tool(.measure),      zone: .precision),
        .init(id: "dimension",    title: "Dimension",     icon: "ruler.fill",                                     shapesOrigin: false, kind: .tool(.dimension),    zone: .precision),
        .init(id: "fillet",       title: "Fillet",        icon: "square",                                         shapesOrigin: false, kind: .tool(.fillet),       zone: .precision),
        .init(id: "chamfer",      title: "Chamfer",       icon: "square",                                         shapesOrigin: false, kind: .tool(.chamfer),      zone: .precision),
        .init(id: "patterning",   title: "Patterning",    icon: "square.grid.3x3",                                shapesOrigin: false, kind: .tool(.patterning),   zone: .creation),
        .init(id: "paperFolding", title: "Paper Folding", icon: "scissors",                                       shapesOrigin: false, kind: .tool(.paperFolding), zone: .creation),
        // — Shapes flyout —
        .init(id: "sketchLine",      title: "Line",      icon: "line.diagonal",          shapesOrigin: true, kind: .tool(.sketchLine)),
        .init(id: "sketchCircle",    title: "Circle",    icon: "circle",                 shapesOrigin: true, kind: .tool(.sketchCircle)),
        .init(id: "sketchRectangle", title: "Rectangle", icon: "rectangle",              shapesOrigin: true, kind: .tool(.sketchRectangle)),
        .init(id: "sketchText",      title: "Text",      icon: "character.cursor.ibeam", shapesOrigin: true, kind: .tool(.sketchText)),
        .init(id: "sketchPolygon",   title: "Polygon",   icon: "hexagon",                shapesOrigin: true, kind: .tool(.sketchPolygon)),
        .init(id: "pen",             title: "Pen",       icon: "pencil.tip",             shapesOrigin: true, kind: .tool(.pen)),
        .init(id: "templateInsert",  title: "Templates", icon: "square.on.square.dashed", shapesOrigin: true, kind: .tool(.templateInsert)),
        // — Utilities flyout ("Other Tools" •••) —
        .init(id: "mirror",    title: "Mirror",    icon: "flip.horizontal",                                          shapesOrigin: false, kind: .tool(.mirror)),
        .init(id: "convert",   title: "Convert",   icon: "scribble",                                                 shapesOrigin: false, kind: .tool(.convertLines)),
        .init(id: "boxStitch", title: "Box Stitch", icon: "rectangle.connected.to.line.below",                       shapesOrigin: false, kind: .tool(.boxStitch)),
        .init(id: "mandala",   title: "Mandala",   icon: "circle.hexagongrid",                                       shapesOrigin: false, kind: .tool(.mandala)),
        .init(id: "boxJoint",  title: "Box Joint", icon: "puzzlepiece",                                              shapesOrigin: false, kind: .tool(.boxJoint)),
        .init(id: "goldenGuide", title: "Golden Ratio", icon: "spiral",                                              shapesOrigin: false, kind: .tool(.goldenGuide)),
        .init(id: "jigExport", title: "3D Jig",    icon: "cube.transparent",                                         shapesOrigin: false, kind: .tool(.jigExport)),
        .init(id: "flipH",     title: "Flip H",    icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", shapesOrigin: false, kind: .flipH),
        .init(id: "flipV",     title: "Flip V",    icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",      shapesOrigin: false, kind: .flipV),
        .init(id: "duplicate", title: "Duplicate", icon: "plus.square.on.square",                                     shapesOrigin: false, kind: .duplicate),
    ]

    static let byId: [String: ToolbarItemDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func def(_ id: String) -> ToolbarItemDef? { byId[id] }

    static let defaultMain   = ["select", "move", "pan", "scale", "offset", "addThickness", "addHoles", "cleanup", "trim", "measure", "dimension", "fillet", "chamfer", "patterning", "paperFolding"]
    static let defaultShapes = ["sketchLine", "sketchCircle", "sketchRectangle", "sketchPolygon", "sketchText", "pen", "templateInsert"]
    static let defaultExtra  = ["mirror", "convert", "boxStitch", "mandala", "boxJoint", "goldenGuide", "jigExport", "flipH", "flipV", "duplicate"]
}

/// Persisted, user-rearrangeable toolbar layout (MAS-99). Holds the ordered item
/// ids for each of the three containers; Command-drag / the "Move to…" menu mutate
/// it and it auto-saves to UserDefaults.
@MainActor
@Observable
final class ToolbarLayout {
    static let shared = ToolbarLayout()

    // v2 — re-baselined into functional zones with Trim in Modifications and the
    // Utilities flyout consolidated (MAS-117).
    private static let key = "toolbarLayout.v3"

    var main: [String]
    var extra: [String]
    var shapes: [String]

    private struct Persisted: Codable { var main: [String]; var extra: [String]; var shapes: [String] }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            self.main = p.main
            self.extra = p.extra
            self.shapes = p.shapes
            reconcile()
        } else {
            self.main = ToolbarRegistry.defaultMain
            self.extra = ToolbarRegistry.defaultExtra
            self.shapes = ToolbarRegistry.defaultShapes
        }
    }

    /// Drop any unknown ids and append any newly-registered items (e.g. a tool
    /// added in a later build) to a sensible default container, so the persisted
    /// layout never goes stale or hides a tool.
    private func reconcile() {
        let known = Set(ToolbarRegistry.byId.keys)
        main = main.filter { known.contains($0) }
        extra = extra.filter { known.contains($0) }
        shapes = shapes.filter { known.contains($0) }
        let placed = Set(main + extra + shapes)
        for def in ToolbarRegistry.all where !placed.contains(def.id) {
            if ToolbarRegistry.defaultShapes.contains(def.id) { shapes.append(def.id) }
            else if ToolbarRegistry.defaultExtra.contains(def.id) { extra.append(def.id) }
            else { main.append(def.id) }
        }
    }

    private func save() {
        let p = Persisted(main: main, extra: extra, shapes: shapes)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func items(in container: ToolbarContainer) -> [ToolbarItemDef] {
        let ids: [String]
        switch container {
        case .main: ids = main
        case .extra: ids = extra
        case .shapes: ids = shapes
        }
        return ids.compactMap { ToolbarRegistry.def($0) }
    }

    func container(of id: String) -> ToolbarContainer? {
        if main.contains(id) { return .main }
        if extra.contains(id) { return .extra }
        if shapes.contains(id) { return .shapes }
        return nil
    }

    /// True when `id` is allowed to land in `container` (Shapes only takes
    /// shapes-origin items; main/extra take anything).
    func canPlace(_ id: String, in container: ToolbarContainer) -> Bool {
        guard let def = ToolbarRegistry.def(id) else { return false }
        if container == .shapes { return def.shapesOrigin }
        return true
    }

    private func remove(_ id: String) {
        main.removeAll { $0 == id }
        extra.removeAll { $0 == id }
        shapes.removeAll { $0 == id }
    }

    /// Move `id` to the end of `container` (used by drop-onto-icon and the menu).
    func move(_ id: String, to container: ToolbarContainer) {
        guard ToolbarRegistry.def(id) != nil, canPlace(id, in: container) else { return }
        remove(id)
        switch container {
        case .main: main.append(id)
        case .extra: extra.append(id)
        case .shapes: shapes.append(id)
        }
        save()
    }

    /// Move `id` so it sits just before `targetId` within `targetId`'s container
    /// (reorder, or cross-container move with a precise drop position).
    func move(_ id: String, before targetId: String) {
        guard id != targetId, let target = container(of: targetId), canPlace(id, in: target) else { return }
        remove(id)
        func insert(_ arr: inout [String]) {
            let idx = arr.firstIndex(of: targetId) ?? arr.count
            arr.insert(id, at: idx)
        }
        switch target {
        case .main: insert(&main)
        case .extra: insert(&extra)
        case .shapes: insert(&shapes)
        }
        save()
    }

    func resetToDefaults() {
        main = ToolbarRegistry.defaultMain
        extra = ToolbarRegistry.defaultExtra
        shapes = ToolbarRegistry.defaultShapes
        save()
    }
}
