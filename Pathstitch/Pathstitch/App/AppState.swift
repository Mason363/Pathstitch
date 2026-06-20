import SwiftUI
import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

enum NamingOption {
    case original
    case customIndex
}

enum AppMode {
    case twoD
    case threeD
    case batch
}

struct BatchItem: Identifiable, Hashable, Equatable {
    let id: UUID
    let fileURL: URL
    let originalName: String
    var isSelected: Bool
    var entities: [DXFEntity]
    var svgContent: String
    
    init(id: UUID = UUID(), fileURL: URL, originalName: String, isSelected: Bool = true, entities: [DXFEntity] = [], svgContent: String = "") {
        self.id = id
        self.fileURL = fileURL
        self.originalName = originalName
        self.isSelected = isSelected
        self.entities = entities
        self.svgContent = svgContent
    }
}

enum TwoDTool: String, CaseIterable {
    // Raw values are clean display names; the live keybind is appended in
    // `tooltip` so hints never drift from the actual shortcut.
    case select = "Select"
    case move = "Move"
    case pan = "Pan"
    case offset = "Offset"
    case addThickness = "Add Thickness"
    case addHoles = "Add Holes"
    case cleanup = "Join/Cleanup"
    case measure = "Measure"
    case dimension = "Dimension"
    case scale = "Scale"
    case sketchLine = "Line"
    case sketchCircle = "Circle"
    case sketchRectangle = "Rectangle"
    case sketchText = "Text"
    case sketchPolygon = "Polygon"
    case pen = "Pen"
    case fillet = "Fillet"
    case chamfer = "Chamfer"
    case convertLines = "Convert Lines"
    case mirror = "Mirror"
    case trim = "Trim"
    case paperFolding = "Paper Folding"
    case patterning = "Patterning"

    /// SF Symbol fallback. The Fillet/Chamfer tools draw a custom corner glyph in
    /// the toolbar (see ToolButton), since SF Symbols has no true fillet/chamfer.
    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .pan: return "hand.raised"
        case .offset: return "arrow.up.and.down"
        case .addThickness: return "rectangle.expand.vertical"
        case .addHoles: return "circle.dashed"
        case .cleanup: return "sparkles"
        case .measure: return "ruler"
        case .dimension: return "ruler.fill"
        case .scale: return "arrow.up.left.and.arrow.down.right"
        case .sketchLine: return "line.diagonal"
        case .sketchCircle: return "circle"
        case .sketchRectangle: return "rectangle"
        case .sketchText: return "character.cursor.ibeam"
        case .sketchPolygon: return "hexagon"
        case .pen: return "pencil.tip"
        case .fillet: return "square"
        case .chamfer: return "square"
        case .convertLines: return "scribble"
        case .mirror: return "flip.horizontal"
        case .trim: return "scissors.badge.ellipsis"
        case .paperFolding: return "scissors"
        case .patterning: return "square.grid.3x3"
        }
    }

    var isCornerTool: Bool { self == .fillet || self == .chamfer }

    /// The keybind command id that activates this tool, so tooltips can show the
    /// live shortcut (it stays correct even after the user rebinds it).
    var commandId: String {
        switch self {
        case .select: return "tool.select"
        case .move: return "tool.move"
        case .pan: return "tool.pan"
        case .offset: return "tool.offset"
        case .addThickness: return "tool.addThickness"
        case .addHoles: return "tool.addHoles"
        case .cleanup: return "tool.cleanup"
        case .measure: return "tool.measure"
        case .dimension: return "tool.dimension"
        case .scale: return "tool.scale"
        case .sketchLine: return "tool.line"
        case .sketchCircle: return "tool.circle"
        case .sketchRectangle: return "tool.rectangle"
        case .sketchText: return "tool.text"
        case .sketchPolygon: return "tool.polygon"
        case .pen: return "tool.pen"
        case .fillet: return "tool.fillet"
        case .chamfer: return "tool.chamfer"
        case .convertLines: return "tool.convertLines"
        case .mirror: return "tool.mirror"
        case .trim: return "tool.trim"
        case .paperFolding: return "tool.paperFolding"
        case .patterning: return "tool.patterning"
        }
    }

    /// Display name plus the live keybind glyph (e.g. "Trim  (T)"). Used for
    /// toolbar tooltips so the hint always matches the current binding.
    @MainActor var tooltip: String {
        let combo = KeybindStore.shared.combo(for: commandId)
        return combo.key.isEmpty ? rawValue : "\(rawValue)  (\(combo.displayString))"
    }
}

struct MeasurementLine: Identifiable, Codable, Hashable {
    var id: UUID
    var start: CGPoint // Model space
    var end: CGPoint   // Model space
    var distanceMm: Double
    var isAutoDimension: Bool
    var entityHandle: String?
    var dimensionType: String? // "length", "radius", "width", "height"
    var rectP1: CGPoint?
    var rectP2: CGPoint?
    var filletRadius: Double = 0.0
    /// Parametric dimension fields (MAS-110). `varName` is this dimension's sketch
    /// variable (`d1`…); `expression` is the raw text the user typed (a number or
    /// formula); `driven` marks a reference dimension (rendered in parentheses).
    /// `isParametric` distinguishes a placed Dimension-tool constraint from a plain
    /// auto-dimension. All default so older `.stch` files still decode.
    var varName: String? = nil
    var expression: String? = nil
    var driven: Bool = false
    var isParametric: Bool = false
    /// Perpendicular offset (mm) of the dimension line from the geometry, so a
    /// placed dimension sits clear of the part with extension lines (MAS-110 §2).
    var offsetDistance: Double = 0.0

    init(
        id: UUID = UUID(),
        start: CGPoint,
        end: CGPoint,
        distanceMm: Double,
        isAutoDimension: Bool = false,
        entityHandle: String? = nil,
        dimensionType: String? = nil,
        rectP1: CGPoint? = nil,
        rectP2: CGPoint? = nil,
        filletRadius: Double = 0.0,
        varName: String? = nil,
        expression: String? = nil,
        driven: Bool = false,
        isParametric: Bool = false,
        offsetDistance: Double = 0.0
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.distanceMm = distanceMm
        self.isAutoDimension = isAutoDimension
        self.entityHandle = entityHandle
        self.dimensionType = dimensionType
        self.rectP1 = rectP1
        self.rectP2 = rectP2
        self.filletRadius = filletRadius
        self.varName = varName
        self.expression = expression
        self.driven = driven
        self.isParametric = isParametric
        self.offsetDistance = offsetDistance
    }
}

struct HistoryState {
    let dxfDataTask: Task<Data?, Never>
    let measurements: [MeasurementLine]
    let selectedHandles: Set<String>
    // Parametric corner models + their snap points travel with the geometry so
    // fillets/chamfers stay parametric and in-sync across undo/redo (MAS-62).
    let parametricShapes: [String: ParametricCornerShape]
    let cornerSnapPoints: [String: [CornerSnapPoint]]
    // Pen paths travel with the geometry too, so they stay editable across
    // undo/redo (parametric pen lines).
    let penPaths: [String: PenPathModel]
    // 3D body move offsets, so the 3D translate gizmo / nudge / reset are
    // undoable (MAS-143).
    let bodyOffsets: [Int: [Double]]
}

/// One parametric corner modifier on a shape (MAS-62).
struct CornerMod: Codable, Equatable, Hashable {
    var index: Int          // index into the shape's sharp base polygon
    var kind: String        // "fillet" | "chamfer"
    var value: Double       // fillet radius / chamfer setback (mm)
    var continuity: String  // "G1" | "G2"
}

/// A shape kept editable as a sharp base polygon + corner modifiers; the visible
/// curve (true arcs / biarc / chamfer) is regenerated from it (MAS-62).
struct ParametricCornerShape: Codable, Equatable {
    var base: [[Double]]
    var closed: Bool
    var corners: [CornerMod]
}

/// A snap target produced for a parametric shape: the two tangent ends and the
/// center of each blend, plus the untouched sharp corners (MAS-62).
struct CornerSnapPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var role: String  // "tangent" | "center" | "corner"
}

/// One pen-tool anchor kept parametrically: the on-curve point plus its optional
/// incoming/outgoing bezier handles (a straight corner has neither). Stored so a
/// pen path stays a real curve and can be re-opened for editing (double-click).
struct PenPathAnchor: Codable, Equatable {
    var point: [Double]            // [x, y]
    var handleIn: [Double]? = nil  // [x, y] or nil
    var handleOut: [Double]? = nil // [x, y] or nil
}

/// A pen-tool path kept editable as its anchors + handles, keyed by the DXF
/// entity handle. The visible polyline is flattened from this; the model lets a
/// double-click restore the exact anchors for further editing.
struct PenPathModel: Codable, Equatable {
    var anchors: [PenPathAnchor]
    var closed: Bool
}

struct DXFEntity: Identifiable, Codable, Equatable, Hashable {
    var id: String { handle }
    let handle: String
    let type: String
    var layer: String
    let color: Int
    
    // Geometry bounds or representation helper
    let start: [Double]?
    let end: [Double]?
    let center: [Double]?
    let radius: Double?
    let start_angle: Double?
    let end_angle: Double?
    let vertices: [[Double]]?
    let closed: Bool?
    let text: String?
    let height: Double?
    var rotation: Double? = nil   // TEXT rotation, degrees CCW (DXF convention)
    var layerId: String? = nil
    // TEXT rich styling (MAS-134/135). All optional so older .stch / plain DXF
    // text decodes fine; persisted via XDATA on the Python side.
    var fontName: String? = nil   // installed font family name; nil = system default
    var bold: Bool? = nil
    var italic: Bool? = nil
    var underline: Bool? = nil
    var charSpacing: Double? = nil  // extra per-character tracking, in mm

    var geometryDetails: String {
        switch type.uppercased() {
        case "LINE":
            if let s = start, let e = end, s.count >= 2, e.count >= 2 {
                let len = hypot(e[0] - s[0], e[1] - s[1])
                return String(format: "LINE | Length: %.2f mm | Start: (%.1f, %.1f), End: (%.1f, %.1f)", len, s[0], s[1], e[0], e[1])
            }
            return "LINE"
        case "CIRCLE":
            if let r = radius, let c = center, c.count >= 2 {
                return String(format: "CIRCLE | Radius: %.2f mm | Center: (%.1f, %.1f) | Circumference: %.2f mm", r, c[0], c[1], 2 * .pi * r)
            }
            return "CIRCLE"
        case "ARC":
            if let r = radius, let c = center, c.count >= 2, let sa = start_angle, let ea = end_angle {
                let sweep = ea >= sa ? (ea - sa) : (360.0 - sa + ea)
                let arcLen = 2 * .pi * r * (sweep / 360.0)
                return String(format: "ARC | Radius: %.2f mm | Center: (%.1f, %.1f) | Angles: %.1f° - %.1f° | Length: %.2f mm", r, c[0], c[1], sa, ea, arcLen)
            }
            return "ARC"
        case "LWPOLYLINE", "POLYLINE":
            if let verts = vertices, !verts.isEmpty {
                var totalLen = 0.0
                for i in 0..<verts.count - 1 {
                    totalLen += hypot(verts[i+1][0] - verts[i][0], verts[i+1][1] - verts[i][1])
                }
                let isClosed = closed ?? false
                if isClosed && verts.count > 2 {
                    totalLen += hypot(verts.last![0] - verts.first![0], verts.last![1] - verts.first![1])
                }
                return String(format: "POLYLINE | Vertices: %d | Closed: %@ | Length: %.2f mm", verts.count, isClosed ? "Yes" : "No", totalLen)
            }
            return "POLYLINE"
        case "TEXT":
            let txt = text ?? ""
            let h = height ?? 0.0
            if let s = start, s.count >= 2 {
                return String(format: "TEXT | Text: \"%@\" | Height: %.2f mm | Pos: (%.1f, %.1f)", txt, h, s[0], s[1])
            }
            return String(format: "TEXT | Text: \"%@\" | Height: %.2f mm", txt, h)
        default:
            return type.uppercased()
        }
    }

    func getLayer(in layers: [DXFLayer]) -> DXFLayer? {
        if let lid = layerId, let matched = layers.first(where: { $0.id == lid }) {
            return matched
        }
        return layers.first(where: { $0.name == layer })
    }

    func translated(dx: Double, dy: Double) -> DXFEntity {
        var ent = DXFEntity(
            handle: handle,
            type: type,
            layer: layer,
            color: color,
            start: start.map { [$0[0] + dx, $0[1] + dy] },
            end: end.map { [$0[0] + dx, $0[1] + dy] },
            center: center.map { [$0[0] + dx, $0[1] + dy] },
            radius: radius,
            start_angle: start_angle,
            end_angle: end_angle,
            vertices: vertices.map { pts in pts.map { [$0[0] + dx, $0[1] + dy] } },
            closed: closed,
            text: text,
            height: height,
            rotation: rotation
        )
        ent.layerId = layerId
        ent.copyTextStyle(from: self)
        return ent
    }

    /// Returns a copy with new vertex geometry (MAS-62 free vertex editing).
    /// LINE uses the first/last point; LWPOLYLINE/POLYLINE use the whole list.
    func withVertices(_ newVerts: [[Double]]) -> DXFEntity {
        let isLine = type.uppercased() == "LINE"
        let isPoly = type.uppercased() == "LWPOLYLINE" || type.uppercased() == "POLYLINE"
        var ent = DXFEntity(
            handle: handle,
            type: type,
            layer: layer,
            color: color,
            start: (isLine && newVerts.count >= 1) ? newVerts.first : start,
            end: (isLine && newVerts.count >= 2) ? newVerts.last : end,
            center: center,
            radius: radius,
            start_angle: start_angle,
            end_angle: end_angle,
            vertices: isPoly ? newVerts : vertices,
            closed: closed,
            text: text,
            height: height,
            rotation: rotation
        )
        ent.layerId = layerId
        ent.copyTextStyle(from: self)
        return ent
    }

    /// Copies the TEXT rich-styling fields from another entity (MAS-134/135), so
    /// transforms that rebuild the struct don't silently drop a font/B/I/U.
    mutating func copyTextStyle(from other: DXFEntity) {
        fontName = other.fontName
        bold = other.bold
        italic = other.italic
        underline = other.underline
        charSpacing = other.charSpacing
    }

    /// Non-mutating variant of `copyTextStyle` for use in `map` expressions.
    func withTextStyleCopied(from other: DXFEntity) -> DXFEntity {
        var e = self
        e.copyTextStyle(from: other)
        return e
    }

    /// Editable vertices in model space ([] if the type has none). Closed
    /// polylines report a redundant closing vertex (== the first); it is dropped
    /// so indices line up with the Python ops' `get_points` (MAS-62).
    var editableVertices: [[Double]] {
        switch type.uppercased() {
        case "LINE":
            if let s = start, let e = end { return [s, e] }
            return []
        case "LWPOLYLINE", "POLYLINE":
            guard var v = vertices, v.count >= 2 else { return vertices ?? [] }
            if (closed ?? false), let f = v.first, let l = v.last,
               abs(f[0] - l[0]) < 1e-6, abs(f[1] - l[1]) < 1e-6 {
                v.removeLast()
            }
            return v
        default:
            return []
        }
    }

    /// Indices of corners eligible for fillet/chamfer: all corners of a closed
    /// polyline, interior corners of an open one, none for a line (MAS-62).
    var filletableCornerIndices: [Int] {
        let v = editableVertices
        guard type.uppercased() == "LWPOLYLINE" || type.uppercased() == "POLYLINE", v.count >= 3 else { return [] }
        if closed ?? false { return Array(0..<v.count) }
        return v.count >= 3 ? Array(1..<(v.count - 1)) : []
    }

    func rotated(angleDegrees: Double, centerPt: [Double]) -> DXFEntity {
        let angleRad = angleDegrees * .pi / 180.0
        let cosA = cos(angleRad)
        let sinA = sin(angleRad)
        let cx = centerPt[0]
        let cy = centerPt[1]
        
        func rotPt(_ pt: [Double]) -> [Double] {
            guard pt.count >= 2 else { return pt }
            let x = pt[0]
            let y = pt[1]
            let rx = cx + (x - cx) * cosA - (y - cy) * sinA
            let ry = cy + (x - cx) * sinA + (y - cy) * cosA
            if pt.count > 2 {
                return [rx, ry, pt[2]]
            } else {
                return [rx, ry]
            }
        }
        
        var ent = DXFEntity(
            handle: handle,
            type: type,
            layer: layer,
            color: color,
            start: start.map { rotPt($0) },
            end: end.map { rotPt($0) },
            center: center.map { rotPt($0) },
            radius: radius,
            start_angle: start_angle.map { $0 + angleDegrees },
            end_angle: end_angle.map { $0 + angleDegrees },
            vertices: vertices.map { pts in pts.map { rotPt($0) } },
            closed: closed,
            text: text,
            height: height,
            rotation: (type == "TEXT") ? ((rotation ?? 0.0) + angleDegrees) : rotation
        )
        ent.layerId = layerId
        ent.copyTextStyle(from: self)
        return ent
    }
}

struct DXFLayer: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var colorHex: String
    var visible: Bool = true
    var parentFolderId: String? = nil
    
    // Reference Image Layer Properties
    var isReferenceImageLayer: Bool = false
    var refImageBase64: String? = nil
    var refImageOffsetX: Double = 0.0
    var refImageOffsetY: Double = 0.0
    var refImageScaleX: Double = 1.0
    var refImageScaleY: Double = 1.0
    var refImageWidth: Double = 0.0
    var refImageHeight: Double = 0.0
    var refImagePixelWidth: Double = 0.0
    var refImagePixelHeight: Double = 0.0
    var refImageRotation: Double = 0.0
    var refImageDepth: String = "back" // "front" or "back"
    var refImageOpacity: Double = 0.5
    var refImageCalibrationDistance: Double = 100.0
    var locked: Bool = false
    
    var color: Color {
        get { Color(hex: colorHex) }
        set { colorHex = newValue.toHex() }
    }
    
    init(id: String = UUID().uuidString, name: String, colorHex: String, visible: Bool = true, parentFolderId: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.visible = visible
        self.parentFolderId = parentFolderId
    }
    
    init(id: String = UUID().uuidString, name: String, color: Color, visible: Bool = true, parentFolderId: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = color.toHex()
        self.visible = visible
        self.parentFolderId = parentFolderId
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, colorHex, visible, parentFolderId
        case isReferenceImageLayer, refImageBase64, refImageOffsetX, refImageOffsetY
        case refImageScaleX, refImageScaleY, refImageWidth, refImageHeight, refImageRotation
        case refImageDepth, refImageOpacity, refImageCalibrationDistance, locked
        case refImagePixelWidth, refImagePixelHeight
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        parentFolderId = try container.decodeIfPresent(String.self, forKey: .parentFolderId)
        
        isReferenceImageLayer = try container.decodeIfPresent(Bool.self, forKey: .isReferenceImageLayer) ?? false
        refImageBase64 = try container.decodeIfPresent(String.self, forKey: .refImageBase64)
        refImageOffsetX = try container.decodeIfPresent(Double.self, forKey: .refImageOffsetX) ?? 0.0
        refImageOffsetY = try container.decodeIfPresent(Double.self, forKey: .refImageOffsetY) ?? 0.0
        refImageScaleX = try container.decodeIfPresent(Double.self, forKey: .refImageScaleX) ?? 1.0
        refImageScaleY = try container.decodeIfPresent(Double.self, forKey: .refImageScaleY) ?? 1.0
        refImageWidth = try container.decodeIfPresent(Double.self, forKey: .refImageWidth) ?? 0.0
        refImageHeight = try container.decodeIfPresent(Double.self, forKey: .refImageHeight) ?? 0.0
        refImagePixelWidth = try container.decodeIfPresent(Double.self, forKey: .refImagePixelWidth) ?? 0.0
        refImagePixelHeight = try container.decodeIfPresent(Double.self, forKey: .refImagePixelHeight) ?? 0.0
        refImageRotation = try container.decodeIfPresent(Double.self, forKey: .refImageRotation) ?? 0.0
        refImageDepth = try container.decodeIfPresent(String.self, forKey: .refImageDepth) ?? "back"
        refImageOpacity = try container.decodeIfPresent(Double.self, forKey: .refImageOpacity) ?? 0.5
        refImageCalibrationDistance = try container.decodeIfPresent(Double.self, forKey: .refImageCalibrationDistance) ?? 100.0
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        
        if refImagePixelWidth == 0.0 { refImagePixelWidth = refImageWidth }
        if refImagePixelHeight == 0.0 { refImagePixelHeight = refImageHeight }
    }
}

struct DXFLayerFolder: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var parentFolderId: String? = nil
}

// MARK: - PSD import model (MAS-141)
// Decoded result of the Python `parse_psd` op. All placement coordinates are in
// PSD pixels with the origin at the canvas centre and +Y up; the importer scales
// them by a single "fit canvas to viewport" factor so every layer stays in
// register exactly as composed in Photoshop.

struct PSDRasterLayer {
    let name: String
    let pngPath: String
    let centerX: Double
    let centerY: Double
    let widthPx: Double
    let heightPx: Double
    let visible: Bool
}

struct PSDVectorLayer {
    let name: String
    /// Each entity is a polyline: its vertices (PSD pixel, centred, +Y up) and
    /// whether it is closed.
    let entities: [(vertices: [[Double]], closed: Bool)]
    let visible: Bool
}

struct PSDImportData {
    let sourceURL: URL
    let canvasWidth: Double
    let canvasHeight: Double
    let compositePngPath: String
    let compositeWidth: Double
    let compositeHeight: Double
    /// Raster + vector layers in original stacking order is preserved within
    /// each list; raster layers carry rendered PNGs, vector layers carry true
    /// polylines.
    let rasterLayers: [PSDRasterLayer]
    let vectorLayers: [PSDVectorLayer]
    let totalLayerCount: Int
}

enum PSDImportMode {
    case loadAsIs        // raster layers as reference images, vectors as vectors
    case loadAsOne       // flatten everything into a single reference image
    case autoVectorize   // load layers, then vectorize all raster layers
    case mergeAndConvert // flatten to one image, then vectorize it
}

struct LogEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var action: String
    var details: String
    var layerAffected: String?
}

/// Snapshot of a single batch item, so .stch projects can round-trip a batch
/// session (MAS-24: ".stch files handle everything AND every new feature").
struct BatchItemSave: Codable {
    let originalName: String
    let dxfDataBase64: String
    let isSelected: Bool
    let svgContent: String
    let entities: [DXFEntity]
}

struct ProjectSaveContainer: Codable {
    let dxfDataBase64: String?
    let measurements: [MeasurementLine]
    let logEntries: [LogEntry]
    let canvasScale: Double
    let canvasOffsetX: Double
    let canvasOffsetY: Double
    
    let refImageBase64: String?
    let refImageOffsetX: Double
    let refImageOffsetY: Double
    let refImageScale: Double
    let refImageOpacity: Double
    let refImageCalibrationDistance: Double
    let refImageCalibrationStartX: Double?
    let refImageCalibrationStartY: Double?
    let refImageCalibrationEndX: Double?
    let refImageCalibrationEndY: Double?
    
    // Optional settings
    var isLearnModeEnabled: Bool? = nil
    // Parametric fillet/chamfer corner specs, keyed by entity handle (MAS-62).
    var parametricShapes: [String: ParametricCornerShape]? = nil
    // Parametric pen paths, keyed by entity handle (parametric pen lines).
    var penPaths: [String: PenPathModel]? = nil
    var offsetDistance: Double? = nil
    var offsetSide: String? = nil
    var holeOffsetDistance: Double? = nil
    var holeDiameter: Double? = nil
    var holeSpacing: Double? = nil
    var holeDistribution: String? = nil
    var holeCount: Int? = nil
    var holePattern: String? = nil
    var holeCornerBehavior: String? = nil
    var holeSide: String? = nil
    var holeRowSpacing: Double? = nil
    
    // Glue tab settings
    var glueTabHeight: Double? = nil
    var glueTabType: String? = nil
    var glueTabSide: String? = nil
    var glueTabStartOffset: Double? = nil
    var glueTabEndOffset: Double? = nil

    // Persisted batch session (optional / backward-compatible).
    var batchItems: [BatchItemSave]? = nil

    // §6: persist the "export measurement lines as construction lines" setting.
    var exportMeasurementLines: Bool? = nil

    // Phase 9 layering fields
    var savedLayers: [DXFLayer]? = nil
    var savedLayerFolders: [DXFLayerFolder]? = nil
    var savedActiveLayerId: String? = nil

    // 3D workspace persistence (MAS-75): the 3D model + body visibility travel
    // inside the same .stch as the 2D drawing, so 3D shares saving/unsaved state.
    var savedStepJson: String? = nil
    var savedBodies3D: [Body3D]? = nil
    /// Per-body manual move offsets in the 3D viewport (MAS-125), keyed by body
    /// index. Optional so older .stch files still decode.
    var savedBodyOffsets: [BodyOffsetSave]? = nil
}

/// One body's manual move offset (MAS-125), persisted in `.stch`.
struct BodyOffsetSave: Codable, Hashable {
    let bodyIndex: Int
    let x: Double
    let y: Double
    let z: Double
}

@MainActor @Observable
class AppState {
    var activeMode: AppMode = .twoD
    var currentFilePath: URL?
    var currentStepFilePath: URL?
    var currentProjectPath: URL? = nil
    var svgContent: String?
    
    var batchItems: [BatchItem] = []
    var activeEditingBatchItem: BatchItem? = nil
    
    var sessionTempDirectory: URL
    
    // Text shape tool properties
    var pendingTextInsert: CGPoint? = nil
    var pendingTextHeight: Double = 5.0
    var showTextInputDialog: Bool = false
    var textInputString: String = "Label"
    
    // Canvas Text editing properties
    var isEditingText: Bool = false
    var editingTextHandle: String? = nil
    var editingTextString: String = ""
    var editingTextInsert: CGPoint = .zero
    var editingTextHeight: Double = 5.0
    var editingTextWidth: Double = 0.0  // model-space width of the drawn text box
    // Live styling for the text currently being typed (MAS-134/135). Seeded from
    // the tool defaults below on a new text, or from the entity when re-editing.
    var editingTextFont: String = ""        // "" = system default
    var editingTextBold: Bool = false
    var editingTextItalic: Bool = false
    var editingTextUnderline: Bool = false
    var editingTextCharSpacing: Double = 0.0
    // Defaults applied to the *next* text created with the Text tool, settable
    // from the Text tool's active-options panel before drawing the box.
    var textToolFont: String = ""
    var textToolBold: Bool = false
    var textToolItalic: Bool = false
    var textToolUnderline: Bool = false
    var textToolCharSpacing: Double = 0.0
    /// Family currently hovered in a font picker — previews live on the text being
    /// styled (the one being typed, or the single selected text) without
    /// committing. nil when nothing is hovered → revert to the real font.
    var fontHoverPreview: String? = nil
    var escapePressedToken: Int = 0

    // Search palette (MAS-53): set true to present the command search overlay.
    var showSearchPalette: Bool = false

    // Log entries
    var logEntries: [LogEntry] = []
    
    // Custom status states
    var hasUnsavedChanges: Bool = false
    var isLearnModeEnabled: Bool = true
    var isLogTrayExpanded: Bool = false
    var hoveredHandle: String? = nil
    
    // Reference Image properties
    var refImage: NSImage? = nil
    var refImageBase64: String? = nil
    var refImageOffset: CGSize = .zero
    var refImageScale: CGFloat = 1.0
    var refImageOpacity: Double = 0.5
    var isCalibrationActive: Bool = false
    var calibrationPoints: [CGPoint] = []
    var calibrationDistance: Double = 50.0
    var isCalibratingDistanceInput: Bool = false
    var calibrationTempDistanceText: String = ""
    var calibrationInputScreenPos: CGPoint = .zero

    // Group 9 Layer-based Reference Image Properties
    var currentViewportSize: CGSize = CGSize(width: 800, height: 600)
    var isEditingRefImageTransform: Bool = false
    var isTracingRefImage: Bool = false
    var autocropBackgroundlessImage: Bool = false
    var backgroundlessMode: Bool = false
    var removeBackgroundMode: Bool = false
    var traceThreshold: Double = 127.0
    var traceTolerance: Double = 50.0
    var traceCornerSmoothness: Double = 50.0
    var tracePathOptimization: Double = 50.0
    var tracePreviewEntities: [DXFEntity] = []

    // PSD import (MAS-141). When a .psd is parsed, the result is held here and a
    // centered choice dialog is shown asking how to bring the layers in.
    var pendingPSDImport: PSDImportData? = nil
    var showPSDImportDialog: Bool = false
    /// Canvas drop location for a queued PSD import (so the layers land where the
    /// file was dropped, matching image import).
    var psdImportDropAt: CGPoint? = nil
    // Reference-image layer ids queued for a single shared vectorize pass. While
    // non-empty (and `isTracingRefImage`), the vectorize panel commits to all of
    // them at once with the same trace settings ("applies to all raster layers
    // equally"), per MAS-141.
    var psdVectorizeBatchLayerIds: [String] = []

    // Transform Backup
    var backupOffsetX: Double = 0.0
    var backupOffsetY: Double = 0.0
    var backupScaleX: Double = 1.0
    var backupScaleY: Double = 1.0
    var backupRotation: Double = 0.0
    
    // Decoded image cache
    private var decodedImageCache: [String: NSImage] = [:]

    
    // 2D Canvas State
    var currentTool: TwoDTool = .select {
        didSet {
            guard currentTool != oldValue else { return }
            if currentTool == .offset {
                // Entering Offset: always start at a predictable 12 mm rather than
                // inheriting the last session's distance, so the tool behaves the
                // same every time you pick it up.
                offsetDistance = 12.0
                // Chain-select defaults ON when nothing is loaded, so a click grabs
                // the whole connected profile; an existing selection is kept and
                // previewed immediately (MAS-109).
                if selectedHandles.isEmpty {
                    chainSelectionEnabled = true
                } else {
                    updateLivePreview()
                }
            } else if oldValue == .offset {
                previewEntities = []
            }
            if currentTool == .scale {
                // Fresh scale session: default to the selection's own center.
                scaleFactor = 1.0
                scalePivotModel = nil
                scaleFromCenter = true
                pickingScalePivot = false
            }
            if currentTool == .patterning {
                // Fresh pattern session: circular center defaults to selection center.
                patternPivotModel = nil
                pickingPatternPivot = false
                patternPathHandle = nil
                pickingPatternPath = false
            }
        }
    }
    var chainSelectionEnabled: Bool = false
    /// Offset tool: emit construction (dashed reference) lines instead of normal
    /// solid sketch lines (MAS-109).
    var offsetConstruction: Bool = false
    var selectedHandles: Set<String> = [] {
        didSet {
            updateActiveLayersFromSelection()
            // A new selection starts a fresh rotation accumulation (MAS-57).
            if selectedHandles != oldValue { gizmoAccumulatedRotation = 0 }
            // Picking geometry with the Offset tool shows the ghost preview at the
            // current distance the moment a selection exists (MAS-109).
            if currentTool == .offset && selectedHandles != oldValue {
                updateLivePreview()
            }
        }
    }

    /// Cumulative rotation (degrees, [0,360)) applied to the current selection via
    /// the rotation gizmo — never resets to zero between rotations of the same
    /// selection, only when the selection changes (MAS-57).
    var gizmoAccumulatedRotation: Double = 0
    var entities: [DXFEntity] = []
    var previewEntities: [DXFEntity] = []
    var layers: [DXFLayer] = []
    var layerFolders: [DXFLayerFolder] = []
    var activeLayerId: String? = nil {
        didSet {
            if let lid = activeLayerId {
                if !activeLayerIds.contains(lid) {
                    activeLayerIds = [lid]
                }
                // When selecting a reference image layer, automatically activate transform editing
                if let matched = layers.first(where: { $0.id == lid }), matched.isReferenceImageLayer {
                    if !isEditingRefImageTransform {
                        isEditingRefImageTransform = true
                        backupActiveLayerTransform()
                    }
                } else {
                    isEditingRefImageTransform = false
                }
            } else {
                activeLayerIds.removeAll()
                isEditingRefImageTransform = false
            }
        }
    }
    var activeLayerIds: Set<String> = []
    var expandedFolderIds: Set<String> = []
    
    var activeLayer: DXFLayer? {
        if let lid = activeLayerId, let matched = layers.first(where: { $0.id == lid }) {
            return matched
        }
        return layers.first
    }
    
    func sanitizeLayerName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "\\/:*?\"<>|;,=`")
        let components = name.components(separatedBy: invalidChars)
        let sanitized = components.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Layer" : String(sanitized.prefix(255))
    }
    var canvasScale: CGFloat = 1.0
    var canvasOffset: CGSize = .zero
    var gridVisible: Bool = true
    var threeDOrthographic: Bool = false
    /// Incremented to ask the 2D canvas to zoom/pan so all geometry is visible
    /// (e.g. after a multi-file distribute import). The canvas owns the view
    /// size, so it computes the actual fit — see `DxfCanvasView.fitToContent`.
    var fitRequestToken: Int = 0
    /// Bumped to request opening the Documentation window from a non-View
    /// context (e.g. the search palette). ContentView observes it.
    var openDocsToken: Int = 0
    /// Bumped when Return/Enter is pressed with a commit-capable tool active
    /// (Line, Pen). The 2D canvas observes it to finish the in-progress shape.
    var commitToolToken: Int = 0

    // Operations Configs
    // Offset always starts at 12 mm — reset on entering the tool (see currentTool
    // didSet) so it never inherits the previous session's distance.
    var offsetDistance: Double = 12.0
    var offsetSide: String = "left"
    
    var holeOffsetDistance: Double = 2.0
    var holeDiameter: Double = 1.0
    var holeSpacing: Double = 4.0
    // Distribution: "spacing" fills the contour at a fixed pitch (variable spacing
    // allowed); "count" places exactly holeCount evenly-spaced holes (MAS-59).
    var holeDistribution: String = "spacing"
    var holeCount: Int = 12
    var holePattern: String = "single" // "single" or "saddle"
    var holeCornerBehavior: String = "skip" // "skip" or "wrap"
    var holeSide: String = "left"
    var holeRowSpacing: Double = 3.0
    var holeEnableVariableSpacing: Bool = true
    var holeEnableProximityFilter: Bool = true
    var holeEnableCornerInterpolation: Bool = true
    var holeEnableLineProximityFilter: Bool = true
    var holeLineProximityThreshold: Double = 1.0
    var holeProximityDistance: Double = 3.0
    var holeVariableSpacingMin: Double = 4.0
    var holeVariableSpacingMax: Double = 5.0

    // Sewing v2 — Proximity Avoidance / Keep-Out (MAS-120 Phase 1). Entities tagged
    // as keep-out create a clearance gap in the stitch line around hardware.
    var sewingKeepoutHandles: Set<String> = []
    var holeEnableAvoidance: Bool = false
    var holeAvoidanceRadius: Double = 3.0

    var consolidateSvgStrokes: Bool = true
    // SVGs import as cuttable outlines of this width (mm). 0 = raw centerlines.
    var svgImportThickness: Double = 3.0
    // "Add Thickness" tool — width (mm) applied to selected zero-width lines.
    var addThicknessWidth: Double = 3.0
    var cleanupTolerance: Double = 0.1
    var exportFormat: String = "dxf"
    var exportSelectedOnly: Bool = false
    
    // Glue Tab Configs
    var glueTabHeight: Double = 5.0
    var glueTabType: String = "trapezoid" // "trapezoid" or "triangle"
    var glueTabSide: String = "left"      // "left" or "right"
    var glueTabStartOffset: Double = 0.0
    var glueTabEndOffset: Double = 0.0
    
    // Sketch Tool configs
    var sketchFilletRadius: Double = 0.0
    var bboxOffsetDistance: Double = 5.0
    var bboxOffsetFillet: Double = 0.0

    // Dedicated Fillet/Chamfer tools (MAS-62). The active tool decides
    // fillet vs chamfer; corners are stored parametrically so they stay
    // editable and convertible.
    var filletContinuity: String = "G1"      // "G1" (arc) | "G2" (biarc blend)
    var filletToolRadius: Double = 3.0       // radius (fillet) / setback (chamfer)
    var filletSelectedHandle: String? = nil  // the shape the corner tools act on
    /// Undo-stack depth captured when a Fillet/Chamfer session began, so Enter can
    /// confirm (keep) and Esc can cancel (revert the whole session).
    private var cornerSessionUndoDepth: Int? = nil
    /// The last corner the user toggled — the one the radius box / arrow edits.
    /// Fillets are individual (MAS-91): there is no single radius for all corners.
    var activeCornerIndex: Int? = nil
    /// Corners selected *together* in the current fillet/chamfer session. Setting a
    /// radius (box, drag arrow, or Enter) applies to every corner in this set, so
    /// corners picked together share one value — without being permanently linked
    /// (MAS-103). Reset whenever a new session begins or the shape changes.
    var activeCornerIndices: Set<Int> = []
    /// Sharp base polygon + per-corner fillet/chamfer specs, keyed by entity
    /// handle. The visible curve is regenerated from this, so a fillet can be
    /// re-edited, resized, or converted to a chamfer at any time.
    var parametricShapes: [String: ParametricCornerShape] = [:]
    /// Snap points for parametric shapes (two tangent ends + one center per
    /// blend, plus sharp corners), returned by op_apply_corners.
    var cornerSnapPoints: [String: [CornerSnapPoint]] = [:]
    /// Pen-tool paths kept editable as anchors + bezier handles, keyed by entity
    /// handle. Lets a pen line be re-opened for editing on double-click.
    var penPaths: [String: PenPathModel] = [:]
    // The creation fillet handle shows only right after a rectangle is drawn,
    // never again on mere re-selection (MAS-62).
    var justCreatedRectangleHandle: String? = nil

    // MARK: - Cross-feature links (MAS-55 mirror / MAS-76 imports / MAS-58 convert)

    /// A live mirror relationship between two entity handles (MAS-55). Edits to
    /// either side are reflected to the other across the stored axis until the
    /// user breaks the link.
    struct MirrorLink: Equatable {
        var partner: String
        var axisStart: CGPoint
        var axisEnd: CGPoint
        var mirror: Bool
    }
    var mirrorLinks: [String: MirrorLink] = [:]
    func mirrorLink(for handle: String) -> MirrorLink? { mirrorLinks[handle] }

    // Move tool state (MAS-80). Create-copy resets to off each activation.
    var moveCreateCopy: Bool = false
    var moveScaleFactor: Double = 1.0
    var moveScaleFromCenter: Bool = true   // false = scale from bbox corner "dot"
    var moveP2PActive: Bool = false        // point-to-point picking armed
    var moveP2PFrom: CGPoint? = nil        // first picked point

    // Polygon tool (MAS-118): number of sides for the next polygon (3–64).
    var polygonSides: Int = 6

    // Patterning v2 (MAS-113). Rectangular grid or circular array, with a live
    // ghost preview + draggable handles driven from the canvas.
    var patternMode: String = "rectangular"   // "rectangular" | "circular"
    var patternCountX: Int = 3
    var patternCountY: Int = 1
    var patternSpacingX: Double = 20
    var patternSpacingY: Double = 20
    var patternCircCount: Int = 6
    var patternCircAngle: Double = 360
    var patternPivotModel: CGPoint? = nil      // nil = selection bbox center
    var pickingPatternPivot: Bool = false
    
    var patternPathSpacing: Double = 10.0
    var patternPathHandle: String? = nil
    var pickingPatternPath: Bool = false

    // Scale tool state (MAS-128). Scales the selection from its own center, or
    // from a user-picked scale point when one is set.
    var scaleFactor: Double = 1.0
    var scaleFromCenter: Bool = true       // false = use scalePivotModel (picked)
    var scalePivotModel: CGPoint? = nil    // custom scale point in model coords
    var pickingScalePivot: Bool = false    // next canvas click sets the scale point

    /// Bounding box (model coords) of the current selection, or nil if empty.
    var selectionBBox: CGRect? {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        var found = false
        for e in entities where selectedHandles.contains(e.handle) {
            let pts: [[Double]]
            switch e.type.uppercased() {
            case "LINE": pts = [e.start, e.end].compactMap { $0 }
            case "CIRCLE", "ARC":
                if let c = e.center, c.count >= 2, let r = e.radius {
                    pts = [[c[0]-r, c[1]-r], [c[0]+r, c[1]+r]]
                } else { pts = [] }
            case "LWPOLYLINE", "POLYLINE": pts = e.vertices ?? []
            case "TEXT": pts = [e.start].compactMap { $0 }
            default: pts = [e.center, e.start].compactMap { $0 }
            }
            for p in pts where p.count >= 2 {
                found = true
                minX = min(minX, p[0]); minY = min(minY, p[1])
                maxX = max(maxX, p[0]); maxY = max(maxY, p[1])
            }
        }
        guard found, minX <= maxX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Scales the selection by `factor` about its center (or bbox corner), with
    /// optional create-copy (MAS-80).
    func scaleSelected(factor: Double, pivotOverride: CGPoint? = nil) {
        guard let url = currentFilePath, !selectedHandles.isEmpty, factor > 0,
              let bbox = selectionBBox else { return }
        let pivot: CGPoint = pivotOverride
            ?? scalePivotModel
            ?? (moveScaleFromCenter
                ? CGPoint(x: bbox.midX, y: bbox.midY)
                : CGPoint(x: bbox.minX, y: bbox.minY))
        let handles = Array(selectedHandles)
        let copy = moveCreateCopy
        saveToHistory()
        isProcessing = true
        let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        Task {
            do {
                var workingHandles = handles
                var inputPath = url.path
                if copy {
                    let dup = try await PythonBridge.shared.run(
                        module: "dxf_ops", op: "duplicate_entities",
                        args: ["input": inputPath, "output": activeDxfURL.path,
                               "handles": handles, "dx": 0.0, "dy": 0.0])
                    if let nh = (dup["data"] as? [String: Any])?["new_handles"] as? [String], !nh.isEmpty {
                        workingHandles = nh
                    }
                    inputPath = activeDxfURL.path
                }
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops", op: "scale_entities",
                    args: ["input": inputPath, "output": activeDxfURL.path,
                           "handles": workingHandles, "factor": factor,
                           "cx": Double(pivot.x), "cy": Double(pivot.y)])
                await MainActor.run {
                    if let status = res["status"] as? String, status != "ok" {
                        self.errorMessage = (res["message"] as? String) ?? "Scale failed."
                        self.isProcessing = false
                        return
                    }
                    self.currentFilePath = activeDxfURL
                    self.reloadDXF()
                    self.selectedHandles = Set(workingHandles)
                    self.scaleFactor = 1.0
                    self.logEntries.append(LogEntry(action: "Scale", details: String(format: "Scaled selection ×%.3f", factor)))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    /// Point-to-point move (MAS-80): translate the selection by (to − from),
    /// duplicating first when create-copy is on.
    func moveSelection(by dx: CGFloat, dy: CGFloat, copy: Bool) {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        if !copy {
            translateSelected(dx: dx, dy: dy)
            return
        }
        let handles = Array(selectedHandles)
        saveToHistory()
        isProcessing = true
        let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        Task {
            do {
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops", op: "duplicate_entities",
                    args: ["input": url.path, "output": activeDxfURL.path,
                           "handles": handles, "dx": Double(dx), "dy": Double(dy)])
                await MainActor.run {
                    if let status = res["status"] as? String, status != "ok" {
                        self.errorMessage = (res["message"] as? String) ?? "Move-copy failed."
                        self.isProcessing = false
                        return
                    }
                    let nh = (res["data"] as? [String: Any])?["new_handles"] as? [String] ?? []
                    self.currentFilePath = activeDxfURL
                    self.reloadDXF()
                    if !nh.isEmpty { self.selectedHandles = Set(nh) }
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription; self.isProcessing = false }
            }
        }
    }

    /// Records a point-to-point click; on the second point performs the move.
    func moveP2PClick(_ pt: CGPoint) {
        if let from = moveP2PFrom {
            moveSelection(by: pt.x - from.x, dy: pt.y - from.y, copy: moveCreateCopy)
            moveP2PFrom = nil
            moveP2PActive = false
        } else {
            moveP2PFrom = pt
        }
    }

    // Mirror tool interaction state (MAS-55).
    var mirrorFlip: Bool = true          // mirror (flip) the copy, vs. plain copy
    var mirrorKeepLink: Bool = true      // keep a live two-way link after mirroring
    var mirrorSelection: Set<String> = [] // entities chosen to mirror
    var mirrorAxisStart: CGPoint? = nil   // first click of the mirror axis
    var mirrorAxisEnd: CGPoint? = nil     // second click (live until confirm)
    /// Mirror selection mode (MAS-119): false = Objects (pick geometry to mirror),
    /// true = Mirror Line (pick the symmetry axis — an existing line or two points).
    var mirrorLineMode: Bool = false

    /// One-line guidance for the current mirror-tool stage, shown in options.
    var mirrorStageHint: String {
        if selectedHandles.isEmpty { return "Objects mode: click shapes to mirror." }
        if !mirrorLineMode && mirrorAxisStart == nil { return "Switch to Mirror Line, then pick the axis." }
        if mirrorLineMode && mirrorAxisStart == nil { return "Click a line (or two points) for the mirror axis." }
        if mirrorAxisEnd == nil { return "Click the second axis point." }
        return "Adjust options, then Confirm Mirror."
    }

    func resetMirrorTool() {
        mirrorSelection.removeAll()
        mirrorAxisStart = nil
        mirrorAxisEnd = nil
        mirrorLineMode = false
    }

    /// Use an existing straight line as the mirror axis (MAS-119 Mirror Line mode).
    func setMirrorAxisFromLine(start: CGPoint, end: CGPoint) {
        mirrorAxisStart = start
        mirrorAxisEnd = end
    }

    /// Records a mirror-axis click (canvas), filling start then end (MAS-55).
    func mirrorAxisClick(_ pt: CGPoint) {
        if mirrorAxisStart == nil { mirrorAxisStart = pt }
        else if mirrorAxisEnd == nil { mirrorAxisEnd = pt }
        else { mirrorAxisStart = pt; mirrorAxisEnd = nil }
    }

    /// Creates the mirrored copy of the selection across the chosen axis as real
    /// geometry on the same layer, optionally keeping a live link (MAS-55).
    func confirmMirror() {
        guard let url = currentFilePath,
              !selectedHandles.isEmpty,
              let a = mirrorAxisStart, let b = mirrorAxisEnd else { return }
        let handlesSnapshot = Array(selectedHandles)
        let layer = entities.first { selectedHandles.contains($0.handle) }?.layer ?? "0"
        let flip = mirrorFlip
        let keepLink = mirrorKeepLink
        saveToHistory()
        isProcessing = true
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "mirror_entities",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": handlesSnapshot,
                        "axis_start": [Double(a.x), Double(a.y)],
                        "axis_end": [Double(b.x), Double(b.y)],
                        "layer": layer,
                        "flip": flip
                    ]
                )
                await MainActor.run {
                    if let status = res["status"] as? String, status != "ok" {
                        self.errorMessage = (res["message"] as? String) ?? "Mirror failed."
                        self.isProcessing = false
                        return
                    }
                    let pairs = (res["data"] as? [String: Any])?["pairs"] as? [[String]] ?? []
                    if keepLink {
                        for pair in pairs where pair.count == 2 {
                            let link = MirrorLink(partner: pair[1], axisStart: a, axisEnd: b, mirror: flip)
                            self.mirrorLinks[pair[0]] = link
                            self.mirrorLinks[pair[1]] = MirrorLink(partner: pair[0], axisStart: a, axisEnd: b, mirror: flip)
                        }
                    }
                    self.currentFilePath = activeDxfURL
                    self.reloadDXF()
                    self.selectedHandles = Set(pairs.compactMap { $0.count == 2 ? $0[1] : nil })
                    self.resetMirrorTool()
                    self.logEntries.append(LogEntry(action: "Mirror", details: "Mirrored \(handlesSnapshot.count) entit\(handlesSnapshot.count == 1 ? "y" : "ies")"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    /// Removes the mirror relationship for every selected handle and its partner
    /// (right-click → Break Mirror Link, MAS-55). The geometry stays; only the
    /// live link is severed.
    func breakMirrorLinkForSelection() {
        var toRemove = Set<String>()
        for h in selectedHandles {
            if let link = mirrorLinks[h] {
                toRemove.insert(h)
                toRemove.insert(link.partner)
            }
        }
        guard !toRemove.isEmpty else { return }
        for h in toRemove { mirrorLinks.removeValue(forKey: h) }
        logEntries.append(LogEntry(action: "Break Mirror Link", details: "Unlinked \(toRemove.count) entit\(toRemove.count == 1 ? "y" : "ies")"))
    }

    /// An imported file "fork": the on-disk origin plus the handles it produced.
    /// Imports are copied into the project and never auto-update from disk; the
    /// user reloads explicitly (MAS-76).
    struct ImportSource: Equatable {
        var url: URL
        var handles: [String]
    }
    var importSources: [String: ImportSource] = [:]   // groupId -> source

    func importGroupId(for handle: String) -> String? {
        importSources.first { $0.value.handles.contains(handle) }?.key
    }
    func importedSource(for handle: String) -> ImportSource? {
        importGroupId(for: handle).flatMap { importSources[$0] }
    }

    /// True when the selection contains at least one straight-segment entity that
    /// the Convert Lines tool can restyle (MAS-58).
    var selectionHasConvertibleLines: Bool {
        entities.contains {
            selectedHandles.contains($0.handle) &&
            ["LINE", "LWPOLYLINE", "POLYLINE"].contains($0.type.uppercased())
        }
    }

    // MARK: - Convert Lines (MAS-58)

    /// The seven supported line styles, in menu order.
    static let convertLineStyles: [String] = ["dashed", "dotted", "zigzag", "wave", "striped", "square", "triangle"]

    /// Currently selected style in the Convert Lines tool.
    var convertLineStyle: String = "dashed"

    /// Per-style parameters (mm / degrees). Edited in the tool options and the
    /// selection panel; defaults chosen to look good out of the box.
    var convertLineSettings: [String: [String: Double]] = [
        "dashed":   ["dash_length": 4.0, "gap": 3.0],
        "dotted":   ["spacing": 3.0, "dot_radius": 0.5],
        "zigzag":   ["wavelength": 6.0, "amplitude": 2.0],
        "wave":     ["wavelength": 6.0, "amplitude": 2.0, "samples_per_wave": 12.0],
        "striped":  ["dash_length": 3.0, "gap": 3.0, "tilt": 45.0],
        "square":   ["spacing": 4.0, "size": 1.5],
        "triangle": ["spacing": 5.0, "size": 2.0],
    ]

    /// Ordered parameter keys per style, for building the settings UI.
    static let convertLineParamKeys: [String: [String]] = [
        "dashed":   ["dash_length", "gap"],
        "dotted":   ["spacing", "dot_radius"],
        "zigzag":   ["wavelength", "amplitude"],
        "wave":     ["wavelength", "amplitude", "samples_per_wave"],
        "striped":  ["dash_length", "gap", "tilt"],
        "square":   ["spacing", "size"],
        "triangle": ["spacing", "size"],
    ]

    /// A converted-line group: the original segments plus the live style/settings,
    /// so it can be re-styled in place from the selection panel (MAS-58).
    struct ConvertedLineGroup: Equatable {
        var segments: [[[Double]]]
        var style: String
        var settings: [String: Double]
        var layer: String
        var handles: [String]
    }
    var convertedLineGroups: [String: ConvertedLineGroup] = [:]

    func convertedGroupId(for handle: String) -> String? {
        convertedLineGroups.first { $0.value.handles.contains(handle) }?.key
    }
    /// The group selected for editing, if exactly one converted group is selected.
    var selectedConvertedGroupId: String? {
        let gids = Set(selectedHandles.compactMap { convertedGroupId(for: $0) })
        return gids.count == 1 ? gids.first : nil
    }

    /// Straight-segment polylines for an entity (model coords), or nil if it has
    /// no usable straight geometry.
    private func segmentsForEntity(_ e: DXFEntity) -> [[[Double]]]? {
        switch e.type.uppercased() {
        case "LINE":
            if let s = e.start, let en = e.end, s.count >= 2, en.count >= 2 {
                return [[[s[0], s[1]], [en[0], en[1]]]]
            }
        case "LWPOLYLINE", "POLYLINE":
            if let v = e.vertices, v.count >= 2 {
                var pts = v.map { [$0[0], $0[1]] }
                if (e.closed ?? false), let first = pts.first { pts.append(first) }
                return [pts]
            }
        default:
            break
        }
        return nil
    }

    /// Converts the selected straight lines to `style` using the current settings.
    func quickConvertSelectedLines(to style: String) {
        convertLineStyle = style
        convertSelectedLines(style: style, settings: convertLineSettings[style] ?? [:])
    }

    /// Replaces the selected straight lines with real styled geometry, tracking a
    /// re-editable group (MAS-58).
    func convertSelectedLines(style: String, settings: [String: Double]) {
        guard let url = currentFilePath else { return }
        let targets = entities.filter { selectedHandles.contains($0.handle) }
        var segments: [[[Double]]] = []
        var deleteHandles: [String] = []
        var layer = "0"
        for e in targets {
            if let segs = segmentsForEntity(e) {
                segments.append(contentsOf: segs)
                deleteHandles.append(e.handle)
                layer = e.layer
            }
        }
        guard !segments.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        let groupId = UUID().uuidString
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "convert_lines",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "delete_handles": deleteHandles,
                        "segments": segments,
                        "style": style,
                        "settings": settings,
                        "layer": layer
                    ]
                )
                await MainActor.run {
                    if let status = res["status"] as? String, status != "ok" {
                        self.errorMessage = (res["message"] as? String) ?? "Convert failed."
                        self.isProcessing = false
                        return
                    }
                    let newHandles = (res["data"] as? [String: Any])?["new_handles"] as? [String] ?? []
                    self.convertedLineGroups[groupId] = ConvertedLineGroup(
                        segments: segments, style: style, settings: settings, layer: layer, handles: newHandles)
                    self.currentFilePath = activeDxfURL
                    self.reloadDXF()
                    self.selectedHandles = Set(newHandles)
                    self.logEntries.append(LogEntry(action: "Convert Lines", details: "Converted to \(style)"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    /// Re-styles an existing converted group from its stored original segments.
    func reconvertGroup(_ groupId: String, style: String? = nil, settings: [String: Double]? = nil) {
        guard let url = currentFilePath, var group = convertedLineGroups[groupId] else { return }
        if let style = style { group.style = style }
        if let settings = settings { group.settings = settings }
        saveToHistory()
        isProcessing = true
        let snapshot = group
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "convert_lines",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "delete_handles": snapshot.handles,
                        "segments": snapshot.segments,
                        "style": snapshot.style,
                        "settings": snapshot.settings,
                        "layer": snapshot.layer
                    ]
                )
                await MainActor.run {
                    if let status = res["status"] as? String, status != "ok" {
                        self.errorMessage = (res["message"] as? String) ?? "Convert failed."
                        self.isProcessing = false
                        return
                    }
                    let newHandles = (res["data"] as? [String: Any])?["new_handles"] as? [String] ?? []
                    var updated = snapshot
                    updated.handles = newHandles
                    self.convertedLineGroups[groupId] = updated
                    self.currentFilePath = activeDxfURL
                    self.reloadDXF()
                    self.selectedHandles = Set(newHandles)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    // Measure Tool State
    var activeMeasureStart: CGPoint? // in model coordinates
    var measurements: [MeasurementLine] = []

    /// When on, placement uses the snap point under the cursor and lines/rulers
    /// faintly snap to 90° increments. Indicators only show when this is on.
    var snapEnabled: Bool = true

    /// §6: when on, measurement/ruler lines are baked into exports as dashed
    /// construction lines (CONSTRUCTION layer, no dimension text). Persisted
    /// per-project in `.stch`; off by default for new projects.
    var exportMeasurementLines: Bool = false
    
    // 3D Canvas State
    var stepJsonContent: String?
    var selectedFaces3D: Set<SelectedFace> = [] {
        didSet {
            triggerDistortionUpdate()
            triggerLiveRecompute()
        }
    }
    var bodies3D: [Body3D] = []

    // Phase 2 & 3: Seam Control & Distortion Heatmap
    var distortionMode: String = "conformal" {
        didSet {
            triggerDistortionUpdate()
            triggerLiveRecompute()
        }
    }
    var seamControlMode: String = "auto" {
        didSet {
            triggerLiveRecompute()
        }
    }
    var forcedSeams3D: Set<SelectedEdge> = [] {
        didSet {
            triggerLiveRecompute()
        }
    }
    var forbiddenSeams3D: Set<SelectedEdge> = [] {
        didSet {
            triggerLiveRecompute()
        }
    }
    var distortionDataJSON: String = ""
    private var distortionTask: Task<Void, Never>?

    // Phase 4: Globe UX / Interactivity & Overrides
    var anchorFace3D: SelectedFace? {
        didSet {
            triggerLiveRecompute()
        }
    }
    var selectedEdge3D: SelectedEdge?
    var seamDecorations3D: [SelectedEdge: String] = [:] {
        didSet {
            triggerLiveRecompute()
        }
    }
    var liveRecomputeEnabled: Bool = false {
        didSet {
            triggerLiveRecompute()
        }
    }
    var netLayout: String = "connected" {
        didSet {
            triggerLiveRecompute()
        }
    }
    var netMode: String = "radial" {
        didSet {
            triggerLiveRecompute()
        }
    }
    var netDecoration: String = "none" {
        didSet {
            triggerLiveRecompute()
        }
    }
    var wholeBodyRecompute: Bool = false {
        didSet {
            triggerLiveRecompute()
        }
    }
    private var liveRecomputeTask: Task<Void, Never>?

    func triggerLiveRecompute() {
        guard liveRecomputeEnabled else { return }
        
        liveRecomputeTask?.cancel()
        
        guard let stepUrl = currentStepFilePath else { return }
        if !wholeBodyRecompute && selectedFaces3D.isEmpty { return }
        
        let mode = netMode
        let decoration = netDecoration
        let layout = netLayout
        let isWholeBody = wholeBodyRecompute
        let faces = Array(selectedFaces3D)
        let distMode = distortionMode
        let seamCtrl = seamControlMode
        let forced = Array(forcedSeams3D)
        let forbidden = Array(forbiddenSeams3D)
        let decorations = seamDecorations3D
        let anchor = anchorFace3D
        let tabsHeight = glueTabHeight
        let holesDiam = holeDiameter
        let holesSpacing = holeSpacing
        let holesMargin = holeOffsetDistance
        let existingDxf = currentFilePath?.path
        
        liveRecomputeTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            
            do {
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let outputDxf = tempDir.appendingPathComponent("unfolded_net_live.dxf")
                
                var args: [String: Any] = [
                    "input": stepUrl.path,
                    "output": outputDxf.path,
                    "mode": mode,
                    "decoration": decoration,
                    "tab_height": tabsHeight,
                    "hole_diameter": holesDiam,
                    "hole_spacing": holesSpacing,
                    "hole_margin": holesMargin,
                    "distortion_mode": distMode,
                    "seam_control_mode": seamCtrl,
                    "forced_seams": forced.map { ["body_index": $0.bodyIndex, "edge_index": $0.edgeIndex] },
                    "forbidden_seams": forbidden.map { ["body_index": $0.bodyIndex, "edge_index": $0.edgeIndex] },
                    "seam_decorations": decorations.map { edge, deco in
                        [
                            "body_index": edge.bodyIndex,
                            "edge_index": edge.edgeIndex,
                            "decoration": deco
                        ]
                    }
                ]
                
                if let anchorVal = anchor {
                    args["anchor"] = ["body_index": anchorVal.bodyIndex, "face_index": anchorVal.faceIndex]
                }
                
                if layout == "connected" {
                    if isWholeBody {
                        args["whole_body"] = true
                    } else {
                        args["faces"] = faces.map { [
                            "body_index": $0.bodyIndex,
                            "face_index": $0.faceIndex
                        ] }
                    }
                    if let existing = existingDxf {
                        args["existing_dxf"] = existing
                    }
                    
                    let result = try await PythonBridge.shared.run(
                        module: "step_ops",
                        op: "unfold_connected",
                        args: args
                    )
                    
                    if Task.isCancelled { return }
                    
                    await MainActor.run {
                        self.currentFilePath = outputDxf
                        self.selectedHandles.removeAll()
                        self.reloadDXF(fitToContentAfter: false)
                    }
                } else {
                    let facesArray = faces.map { [
                        "body_index": $0.bodyIndex,
                        "face_index": $0.faceIndex
                    ] }
                    var separateArgs: [String: Any] = [
                        "input": stepUrl.path,
                        "output": outputDxf.path,
                        "faces": facesArray,
                        "distortion_mode": distMode
                    ]
                    if let existing = existingDxf {
                        separateArgs["existing_dxf"] = existing
                    }
                    
                    _ = try await PythonBridge.shared.run(
                        module: "step_ops",
                        op: "unfold_faces",
                        args: separateArgs
                    )
                    
                    if Task.isCancelled { return }
                    
                    await MainActor.run {
                        self.currentFilePath = outputDxf
                        self.selectedHandles.removeAll()
                        self.reloadDXF(fitToContentAfter: false)
                    }
                }
            } catch {
                print("Live recompute failed: \(error)")
            }
        }
    }

    func triggerDistortionUpdate() {
        distortionTask?.cancel()
        
        guard let face = selectedFaces3D.first, selectedFaces3D.count == 1,
              let stepUrl = currentStepFilePath else {
            distortionDataJSON = ""
            return
        }
        
        let bodyIdx = face.bodyIndex
        let faceIdx = face.faceIndex
        let mode = distortionMode
        let inputPath = stepUrl.path
        
        distortionTask = Task {
            do {
                let result = try await PythonBridge.shared.run(
                    module: "step_ops",
                    op: "face_distortion",
                    args: [
                        "input": inputPath,
                        "body_index": bodyIdx,
                        "face_index": faceIdx,
                        "distortion_mode": mode
                    ]
                )
                
                if Task.isCancelled { return }
                
                guard let status = result["status"] as? String, status == "ok",
                      let distortion = result["distortion"] as? [Double] else {
                    await MainActor.run {
                        self.distortionDataJSON = ""
                    }
                    return
                }
                
                let dict: [String: Any] = [
                    "body_index": bodyIdx,
                    "face_index": faceIdx,
                    "distortion": distortion
                ]
                
                guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                      let jsonStr = String(data: jsonData, encoding: .utf8) else {
                    await MainActor.run {
                        self.distortionDataJSON = ""
                    }
                    return
                }
                
                await MainActor.run {
                    self.distortionDataJSON = jsonStr
                }
            } catch {
                print("Failed to compute face distortion: \(error)")
                await MainActor.run {
                    self.distortionDataJSON = ""
                }
            }
        }
    }

    // Body move tool (MAS-125): select a body in the viewport and translate it
    // with a 3D gizmo / precise numeric fields. Moves are visual layout offsets
    // (like the import-time distribution) persisted per body in `.stch`.
    var bodyMoveToolActive: Bool = false
    var selectedBodyIndex: Int? = nil
    var bodyOffsets: [Int: [Double]] = [:]
    /// Bumped to push offsets / selection to the viewport via updateNSView.
    var bodyMoveStateToken: Int = 0
    /// Precise per-step distance for the body-move panel's nudge buttons.
    var bodyMoveStep: Double = 1.0

    /// JSON string of `bodyOffsets` for the Three.js viewport bridge.
    var bodyOffsetsJSON: String {
        let dict = Dictionary(uniqueKeysWithValues: bodyOffsets.map { (String($0.key), $0.value) })
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    func toggleBodyMoveTool() {
        bodyMoveToolActive.toggle()
        if !bodyMoveToolActive { selectedBodyIndex = nil }
        // The move tool and plane selection both claim viewport clicks — keep them
        // mutually exclusive.
        if bodyMoveToolActive && isPlaneSelectionActive {
            cancelPlaneSelection()
        }
        bodyMoveStateToken += 1
    }

    /// A body was clicked in the viewport while the move tool is active.
    func selectBody(_ index: Int) {
        selectedBodyIndex = index
        bodyMoveStateToken += 1
    }

    /// The offset of the currently selected body (zero if none/unset).
    var selectedBodyOffset: [Double] {
        guard let i = selectedBodyIndex else { return [0, 0, 0] }
        return bodyOffsets[i] ?? [0, 0, 0]
    }

    /// Sets an absolute move offset for a body (from the gizmo drag or the panel),
    /// dirties the doc, and re-syncs the viewport.
    func setBodyOffset(index: Int, x: Double, y: Double, z: Double, pushToViewport: Bool = true) {
        bodyOffsets[index] = [x, y, z]
        hasUnsavedChanges = true
        if pushToViewport { bodyMoveStateToken += 1 }
    }

    /// Snapshot the offsets before a body-move interaction so the whole move is a
    /// single undo step (MAS-143). Called once at gizmo drag-start and before each
    /// discrete panel action (nudge / field commit / reset).
    func beginBodyMove() {
        saveToHistory()
    }

    /// Restore body offsets from a history snapshot and push them to the 3D
    /// viewport so the gizmo and geometry reflect the undo/redo (MAS-143).
    func applyRestoredBodyOffsets(_ offsets: [Int: [Double]]) {
        bodyOffsets = offsets
        bodyMoveStateToken += 1
    }

    // Plane Projection State Machine
    var isPlaneSelectionActive: Bool = false
    var planeSelectionModeType: String = "origin" // "origin" or "face"
    var selectedProjectionPlane: String? = nil // "XY", "XZ", "YZ", or "face"
    var selectedProjectionFaceIndex: Int? = nil
    var selectedProjectionBodyIndex: Int? = nil
    var planeOffset: Double = 0.0
    var selectedProjectionFaceNormal: [Double]? = nil
    var selectedProjectionFaceOrigin: [Double]? = nil
    var triggerCameraAnimationToken: Int = 0
    /// Bumped by the 3D "Home" button to recenter/frame the camera optimally.
    var triggerHomeFrameToken: Int = 0

    /// Frames the 3D model optimally (Home button in 3D mode).
    func frameHome3D() {
        triggerHomeFrameToken += 1
    }

    func startPlaneSelection() {
        // Plane selection and the body-move tool both claim viewport clicks.
        if bodyMoveToolActive {
            bodyMoveToolActive = false
            selectedBodyIndex = nil
            bodyMoveStateToken += 1
        }
        if selectedFaces3D.count == 1 {
            let face = selectedFaces3D.first!
            isPlaneSelectionActive = true
            planeSelectionModeType = "face"
            selectedProjectionPlane = "face"
            selectedProjectionFaceIndex = face.faceIndex
            selectedProjectionBodyIndex = face.bodyIndex
            planeOffset = 0.0
            
            selectedHandles.removeAll()
            selectedMeasurement = nil
        } else {
            selectedFaces3D.removeAll()
            selectedHandles.removeAll()
            selectedMeasurement = nil
            
            isPlaneSelectionActive = true
            planeSelectionModeType = "origin"
            selectedProjectionPlane = nil
            selectedProjectionFaceIndex = nil
            selectedProjectionBodyIndex = nil
            planeOffset = 0.0
            selectedProjectionFaceNormal = nil
            selectedProjectionFaceOrigin = nil
        }
    }
    
    func cancelPlaneSelection() {
        isPlaneSelectionActive = false
        selectedProjectionPlane = nil
        selectedProjectionFaceIndex = nil
        selectedProjectionBodyIndex = nil
        planeOffset = 0.0
        selectedProjectionFaceNormal = nil
        selectedProjectionFaceOrigin = nil
    }
    
    func confirmPlaneProjection() {
        triggerCameraAnimationToken += 1
    }
    
    func executeProjection() {
        saveToHistory()
        guard let stepUrl = currentStepFilePath else { return }
        isProcessing = true
        
        let planeType = selectedProjectionPlane ?? "XY"
        let offsetVal = planeOffset
        let faceIdx = selectedProjectionFaceIndex
        let faceBodyIdx = selectedProjectionBodyIndex ?? 0
        
        // Get visible body indices
        let visibleIndices = bodies3D.filter { $0.visible }.map { $0.body_index }
        
        Task {
            do {
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let uuidStr = UUID().uuidString
                let outputDxf = tempDir.appendingPathComponent("projected_\(uuidStr).dxf")
                
                // Per-body manual move offsets (MAS-140) so the projection lands
                // where each body sits in the 3D view, not at its authored origin.
                let bodyOffsetsArg = Dictionary(uniqueKeysWithValues:
                    bodyOffsets.map { (String($0.key), $0.value) })

                var args: [String: Any] = [
                    "input": stepUrl.path,
                    "output": outputDxf.path,
                    "plane_type": planeType,
                    "offset": offsetVal,
                    "visible_bodies": visibleIndices,
                    "body_offsets": bodyOffsetsArg
                ]
                if planeType == "face", let faceIdx = faceIdx {
                    args["face_index"] = faceIdx
                    args["face_body_index"] = faceBodyIdx
                }
                if let existing = currentFilePath {
                    args["existing_dxf"] = existing.path
                }
                
                _ = try await PythonBridge.shared.run(
                    module: "step_ops",
                    op: "project_edges",
                    args: args
                )
                
                await MainActor.run {
                    self.currentFilePath = outputDxf
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    self.selectedFaces3D.removeAll()
                    
                    // Reset selection plane state
                    self.isPlaneSelectionActive = false
                    self.selectedProjectionPlane = nil
                    self.selectedProjectionFaceIndex = nil
                    self.selectedProjectionBodyIndex = nil
                    self.planeOffset = 0.0
                    self.selectedProjectionFaceNormal = nil
                    self.selectedProjectionFaceOrigin = nil

                    // Optimal framing on a 3D→2D projection (MAS-67).
                    self.reloadDXF(fitToContentAfter: true)
                    self.hasUnsavedChanges = true   // 3D edits dirty the doc (MAS-75)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    // Status/Progress
    var isProcessing: Bool = false
    var progress: Double = 0.0
    var errorMessage: String?
    
    // History & Parametric Selection
    var undoStack: [HistoryState] = []
    var redoStack: [HistoryState] = []
    var selectedMeasurement: MeasurementLine? = nil
    
    func saveToHistory() {
        // Every undoable mutation funnels through here, so this is the single
        // reliable place to mark the document dirty — it guarantees the
        // "save changes?" prompt fires for any 2D/3D edit (MAS-21). Loads and
        // blank-document setup clear the flag again on completion.
        hasUnsavedChanges = true
        let url = currentFilePath
        let dxfDataTask = Task.detached(priority: .userInitiated) { () -> Data? in
            if let url = url {
                return try? Data(contentsOf: url)
            }
            return nil
        }
        let state = HistoryState(
            dxfDataTask: dxfDataTask,
            measurements: measurements,
            selectedHandles: selectedHandles,
            parametricShapes: parametricShapes,
            cornerSnapPoints: cornerSnapPoints,
            penPaths: penPaths,
            bodyOffsets: bodyOffsets
        )
        undoStack.append(state)
        redoStack.removeAll()
    }
    
    func undo() {
        guard !undoStack.isEmpty else { return }

        // A history restore replaces the whole working buffer, so drop any
        // deferred optimistic deletions; a late reconcile must not clobber the
        // restored snapshot (MAS-21).
        pendingDeletedHandles.removeAll()
        reconcileTask?.cancel()

        let url = currentFilePath
        let currentDxfDataTask = Task.detached(priority: .userInitiated) { () -> Data? in
            if let url = url {
                return try? Data(contentsOf: url)
            }
            return nil
        }
        let currentState = HistoryState(
            dxfDataTask: currentDxfDataTask,
            measurements: measurements,
            selectedHandles: selectedHandles,
            parametricShapes: parametricShapes,
            cornerSnapPoints: cornerSnapPoints,
            penPaths: penPaths,
            bodyOffsets: bodyOffsets
        )
        redoStack.append(currentState)

        let previousState = undoStack.removeLast()

        self.measurements = previousState.measurements
        self.selectedHandles = previousState.selectedHandles
        self.parametricShapes = previousState.parametricShapes
        self.cornerSnapPoints = previousState.cornerSnapPoints
        self.penPaths = previousState.penPaths
        self.selectedMeasurement = nil
        self.applyRestoredBodyOffsets(previousState.bodyOffsets)
        self.hasUnsavedChanges = true
        
        Task {
            if let dxfData = await previousState.dxfDataTask.value {
                let activeDxfURL = ensureActiveDXFFileExists()
                do {
                    try dxfData.write(to: activeDxfURL)
                    reloadDXF()
                } catch {
                    errorMessage = "Undo failed to restore DXF file: \(error.localizedDescription)"
                }
            } else {
                currentFilePath = nil
                svgContent = nil
                entities = []
                previewEntities = []
                layers = []
            }
        }
    }
    
    func redo() {
        guard !redoStack.isEmpty else { return }

        // See undo(): drop deferred optimistic deletions before a full restore.
        pendingDeletedHandles.removeAll()
        reconcileTask?.cancel()

        let url = currentFilePath
        let currentDxfDataTask = Task.detached(priority: .userInitiated) { () -> Data? in
            if let url = url {
                return try? Data(contentsOf: url)
            }
            return nil
        }
        let currentState = HistoryState(
            dxfDataTask: currentDxfDataTask,
            measurements: measurements,
            selectedHandles: selectedHandles,
            parametricShapes: parametricShapes,
            cornerSnapPoints: cornerSnapPoints,
            penPaths: penPaths,
            bodyOffsets: bodyOffsets
        )
        undoStack.append(currentState)

        let nextState = redoStack.removeLast()

        self.measurements = nextState.measurements
        self.selectedHandles = nextState.selectedHandles
        self.parametricShapes = nextState.parametricShapes
        self.cornerSnapPoints = nextState.cornerSnapPoints
        self.penPaths = nextState.penPaths
        self.selectedMeasurement = nil
        self.applyRestoredBodyOffsets(nextState.bodyOffsets)
        self.hasUnsavedChanges = true
        
        Task {
            if let dxfData = await nextState.dxfDataTask.value {
                let activeDxfURL = ensureActiveDXFFileExists()
                do {
                    try dxfData.write(to: activeDxfURL)
                    reloadDXF()
                } catch {
                    errorMessage = "Redo failed to restore DXF file: \(error.localizedDescription)"
                }
            } else {
                currentFilePath = nil
                svgContent = nil
                entities = []
                previewEntities = []
                layers = []
            }
        }
    }
    
    func updateSelectedDimensionValue(newValue: Double) {
        guard let selected = selectedMeasurement,
              let handle = selected.entityHandle,
              let dimType = selected.dimensionType,
              let url = currentFilePath else { return }

        // Parametric rectangle resize → drive the model so geometry, snaps and the
        // editable corners stay one source of truth (MAS-62).
        if (dimType == "width" || dimType == "height"),
           var model = parametricShapes[handle],
           let p1 = selected.rectP1, let p2 = selected.rectP2 {
            saveToHistory()
            var newP2 = p2
            if dimType == "width" {
                newP2.x = p1.x + (p2.x >= p1.x ? 1 : -1) * CGFloat(newValue)
            } else {
                newP2.y = p1.y + (p2.y >= p1.y ? 1 : -1) * CGFloat(newValue)
            }
            let bl = p1, tr = newP2
            model.base = [[Double(bl.x), Double(bl.y)], [Double(tr.x), Double(bl.y)],
                          [Double(tr.x), Double(tr.y)], [Double(bl.x), Double(tr.y)]]
            parametricShapes[handle] = model
            for idx in measurements.indices where measurements[idx].entityHandle == handle {
                measurements[idx].rectP2 = newP2
                if measurements[idx].dimensionType == "width" {
                    measurements[idx].start = bl; measurements[idx].end = CGPoint(x: tr.x, y: bl.y)
                    measurements[idx].distanceMm = Double(abs(tr.x - bl.x))
                } else if measurements[idx].dimensionType == "height" {
                    measurements[idx].start = bl; measurements[idx].end = CGPoint(x: bl.x, y: tr.y)
                    measurements[idx].distanceMm = Double(abs(tr.y - bl.y))
                }
            }
            selectedMeasurement?.rectP2 = newP2
            selectedMeasurement?.distanceMm = newValue
            applyParametricShape(handle: handle)
            return
        }

        saveToHistory()
        isProcessing = true
        
        Task {
            do {
                var params: [String: Any] = [:]
                
                if dimType == "length" {
                    let currentLength = Double(hypot(selected.start.x - selected.end.x, selected.start.y - selected.end.y))
                    if currentLength > 1e-5 {
                        let scale = newValue / currentLength
                        let newEndX = selected.start.x + (selected.end.x - selected.start.x) * CGFloat(scale)
                        let newEndY = selected.start.y + (selected.end.y - selected.start.y) * CGFloat(scale)
                        params["start"] = [Double(selected.start.x), Double(selected.start.y)]
                        params["end"] = [Double(newEndX), Double(newEndY)]
                    }
                } else if dimType == "radius" {
                    params["radius"] = newValue
                    params["center"] = [Double(selected.start.x), Double(selected.start.y)]
                } else if dimType == "width" || dimType == "height" {
                    guard let p1 = selected.rectP1, let p2 = selected.rectP2 else { return }
                    
                    var newP2 = p2
                    if dimType == "width" {
                        let currentW = abs(p2.x - p1.x)
                        if currentW > 1e-5 {
                            let sign: CGFloat = p2.x >= p1.x ? 1.0 : -1.0
                            newP2.x = p1.x + sign * CGFloat(newValue)
                        }
                    } else if dimType == "height" {
                        let currentH = abs(p2.y - p1.y)
                        if currentH > 1e-5 {
                            let sign: CGFloat = p2.y >= p1.y ? 1.0 : -1.0
                            newP2.y = p1.y + sign * CGFloat(newValue)
                        }
                    }
                    
                    params["p1"] = [Double(p1.x), Double(p1.y)]
                    params["p2"] = [Double(newP2.x), Double(newP2.y)]
                    params["fillet_radius"] = sketchFilletRadius
                }
                
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "update_entity",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handle": handle,
                        "type": (dimType == "length") ? "line" : ((dimType == "radius") ? "circle" : "rectangle"),
                        "params": params
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    
                    if let idx = self.measurements.firstIndex(where: { $0.id == selected.id }) {
                        self.measurements[idx].distanceMm = newValue
                        if dimType == "length" {
                            let currentLength = Double(hypot(selected.start.x - selected.end.x, selected.start.y - selected.end.y))
                            if currentLength > 1e-5 {
                                let scale = newValue / currentLength
                                let newEndX = selected.start.x + (selected.end.x - selected.start.x) * CGFloat(scale)
                                let newEndY = selected.start.y + (selected.end.y - selected.start.y) * CGFloat(scale)
                                self.measurements[idx].end = CGPoint(x: newEndX, y: newEndY)
                                self.selectedMeasurement?.end = CGPoint(x: newEndX, y: newEndY)
                            }
                        } else if dimType == "radius" {
                            let endRad = CGPoint(x: selected.start.x + CGFloat(newValue), y: selected.start.y)
                            self.measurements[idx].end = endRad
                            self.selectedMeasurement?.end = endRad
                        } else if dimType == "width" || dimType == "height" {
                            guard let p1 = selected.rectP1, let p2 = selected.rectP2 else { return }
                            var newP2 = p2
                            if dimType == "width" {
                                let currentW = abs(p2.x - p1.x)
                                if currentW > 1e-5 {
                                    let sign: CGFloat = p2.x >= p1.x ? 1.0 : -1.0
                                    newP2.x = p1.x + sign * CGFloat(newValue)
                                }
                            } else if dimType == "height" {
                                let currentH = abs(p2.y - p1.y)
                                if currentH > 1e-5 {
                                    let sign: CGFloat = p2.y >= p1.y ? 1.0 : -1.0
                                    newP2.y = p1.y + sign * CGFloat(newValue)
                                }
                            }
                            
                            for mIdx in 0..<self.measurements.count {
                                if self.measurements[mIdx].entityHandle == handle {
                                    self.measurements[mIdx].rectP1 = p1
                                    self.measurements[mIdx].rectP2 = newP2
                                    if self.measurements[mIdx].dimensionType == "width" {
                                        let w = abs(newP2.x - p1.x)
                                        self.measurements[mIdx].start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                        self.measurements[mIdx].end = CGPoint(x: max(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                        self.measurements[mIdx].distanceMm = Double(w)
                                    } else if self.measurements[mIdx].dimensionType == "height" {
                                        let h = abs(newP2.y - p1.y)
                                        self.measurements[mIdx].start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                        self.measurements[mIdx].end = CGPoint(x: min(p1.x, newP2.x), y: max(p1.y, newP2.y))
                                        self.measurements[mIdx].distanceMm = Double(h)
                                    }
                                }
                            }
                            
                            self.selectedMeasurement?.rectP1 = p1
                            self.selectedMeasurement?.rectP2 = newP2
                            if dimType == "width" {
                                self.selectedMeasurement?.start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                self.selectedMeasurement?.end = CGPoint(x: max(p1.x, newP2.x), y: min(p1.y, newP2.y))
                            } else if dimType == "height" {
                                self.selectedMeasurement?.start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                self.selectedMeasurement?.end = CGPoint(x: min(p1.x, newP2.x), y: max(p1.y, newP2.y))
                            }
                        }
                    }
                    self.selectedMeasurement?.distanceMm = newValue
                    self.reloadDXF()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    // MARK: - Parametric dimension engine (MAS-110)

    /// Sketch parameter table (`d1`, `d2`, …) shared by all placed dimensions.
    var dimensionEngine = DimensionEngine()

    /// Commit a typed value or formula to a dimension. Returns `nil` on success or
    /// a `DimensionError` for the field to flash red and keep focus (MAS-110 §3/§4,
    /// MAS-111 error handling). Supports plain numbers, formulas (`d1*2+10`,
    /// `sqrt(...)`), unit suffixes (`1 inch`), and rejects circular references.
    @discardableResult
    func commitDimensionExpression(measureId: UUID, rawExpression: String) -> DimensionError? {
        guard let idx = measurements.firstIndex(where: { $0.id == measureId }) else { return nil }
        let raw = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .syntax("empty") }

        // Evaluate against the current table first (cheap, catches syntax / unknown
        // var before we mutate anything).
        let value: Double
        do { value = try dimensionEngine.preview(raw) }
        catch let e as DimensionError { return e }
        catch { return .syntax("\(error)") }
        if !value.isFinite || value <= 0 { return .syntax("must be a positive length") }

        // Register / update this dimension's variable, detecting cycles.
        let varName = measurements[idx].varName ?? dimensionEngine.nextVarName()
        do { try dimensionEngine.setExpression(varName, raw, driven: measurements[idx].driven) }
        catch let e as DimensionError { return e }
        catch { return .syntax("\(error)") }

        measurements[idx].varName = varName
        measurements[idx].expression = raw
        measurements[idx].isParametric = true

        // Drive the geometry to the evaluated value through the existing resize path.
        selectedMeasurement = measurements[idx]
        updateSelectedDimensionValue(newValue: value)

        // Re-evaluate dependents and refresh their labels (associativity, MAS-110 §3).
        repropagateDimensions()
        return nil
    }

    /// After any parameter change, refresh every parametric dimension's cached
    /// value from the engine so formula labels (`fx:`) stay correct.
    func repropagateDimensions() {
        for i in measurements.indices {
            guard let v = measurements[i].varName,
                  let p = dimensionEngine.parameter(v) else { continue }
            measurements[i].distanceMm = p.value
            measurements[i].driven = p.driven
        }
    }

    /// Rebuild the parameter table from saved measurements after opening a project,
    /// so formula references resolve and dimensions stay editable (MAS-110).
    func rebuildDimensionEngine() {
        dimensionEngine = DimensionEngine()
        for m in measurements {
            guard let v = m.varName else { continue }
            dimensionEngine.addNumeric(value: m.distanceMm, id: v, driven: m.driven)
        }
        for m in measurements {
            guard let v = m.varName, let expr = m.expression else { continue }
            try? dimensionEngine.setExpression(v, expr, driven: m.driven)
        }
    }

    /// Toggle a placed dimension between driving and driven/reference (MAS-110 §4).
    func setDimensionDriven(measureId: UUID, driven: Bool) {
        guard let idx = measurements.firstIndex(where: { $0.id == measureId }),
              let v = measurements[idx].varName else { return }
        measurements[idx].driven = driven
        try? dimensionEngine.setExpression(v, measurements[idx].expression ?? String(format: "%g", measurements[idx].distanceMm), driven: driven)
    }

    init() {
        let uuid = UUID().uuidString
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("pathstitch_\(uuid)")
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.sessionTempDirectory = dir
    }
    
    func logAction(_ action: String, details: String, layerAffected: String? = nil) {
        logEntries.append(LogEntry(action: action, details: details, layerAffected: layerAffected))
    }

    func checkUnsavedChangesBeforeProceeding() -> Bool {
        guard hasUnsavedChanges else { return true }
        
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to your project?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")        // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")      // .alertSecondButtonReturn
        alert.addButton(withTitle: "Discard")     // .alertThirdButtonReturn

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Save → reuse existing path, otherwise prompt. Cancelling the save
            // panel cancels the whole action (returns false → nothing happens).
            if let current = currentProjectPath {
                saveProject(to: current)
                return !hasUnsavedChanges
            } else {
                let savePanel = NSSavePanel()
                savePanel.title = "Save Project"
                savePanel.nameFieldStringValue = "project.stch"
                savePanel.allowedContentTypes = [UTType(filenameExtension: "stch")].compactMap { $0 }
                if savePanel.runModal() == .OK, let url = savePanel.url {
                    saveProject(to: url)
                    return !hasUnsavedChanges
                }
                return false
            }
        } else if response == .alertThirdButtonReturn {
            // Discard → proceed, abandoning changes.
            return true
        } else {
            // Cancel → as if nothing happened.
            return false
        }
    }

    func resetToNewProject() {
        errorMessage = nil
        currentFilePath = nil
        currentStepFilePath = nil
        currentProjectPath = nil
        svgContent = nil
        entities = []
        previewEntities = []
        layers = []
        selectedHandles.removeAll()
        selectedFaces3D.removeAll()
        forcedSeams3D.removeAll()
        forbiddenSeams3D.removeAll()
        seamControlMode = "auto"
        distortionMode = "conformal"
        distortionDataJSON = ""
        anchorFace3D = nil
        selectedEdge3D = nil
        seamDecorations3D.removeAll()
        liveRecomputeEnabled = false
        netLayout = "connected"
        netMode = "radial"
        netDecoration = "none"
        wholeBodyRecompute = false
        bodies3D = []
        batchItems = []
        activeEditingBatchItem = nil
        measurements.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        pendingDeletedHandles.removeAll()
        reconcileTask?.cancel()
        hasUnsavedChanges = false
        activeMode = .twoD
    }

    func traceRasterImage(url: URL) {
        if !checkUnsavedChangesBeforeProceeding() { return }
        errorMessage = nil
        selectedHandles.removeAll()
        selectedFaces3D.removeAll()
        
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let tempImgURL = tempDir.appendingPathComponent("temp_raster_\(UUID().uuidString).\(url.pathExtension)")
        try? FileManager.default.removeItem(at: tempImgURL)
        
        do {
            try FileManager.default.copyItem(at: url, to: tempImgURL)
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
            
            let targetURL = tempDir.appendingPathComponent("active.dxf")
            isProcessing = true
            
            Task {
                do {
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "trace_raster",
                        args: [
                            "input": tempImgURL.path,
                            "output": targetURL.path,
                            "threshold": 127,
                            "turdsize": 2
                        ]
                    )
                    await MainActor.run {
                        self.currentFilePath = targetURL
                        self.activeMode = .twoD
                        self.selectedHandles.removeAll()
                        self.reloadDXF()
                        self.hasUnsavedChanges = true
                        self.isProcessing = false
                        self.logAction("Trace Raster Image", details: "Traced raster image: \(url.lastPathComponent)")
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = "Failed to vectorize image: \(error.localizedDescription)"
                        self.isProcessing = false
                        self.logAction("Trace Raster Error", details: "Failed to vectorize: \(error.localizedDescription)")
                    }
                }
                try? FileManager.default.removeItem(at: tempImgURL)
            }
        } catch {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
            errorMessage = "Failed to copy input image: \(error.localizedDescription)"
            logAction("Trace Raster Error", details: "Failed to copy image: \(error.localizedDescription)")
        }
    }

    func loadFile(url: URL) {
        // Route project & PDF files to their dedicated handlers so callers can
        // pass any supported type here without hitting "unsupported" (MAS-12).
        let routedExt = url.pathExtension.lowercased()
        if routedExt == "stch" { loadProject(from: url); return }
        if routedExt == "pdf"  { importPDF(from: url);  return }
        if routedExt == "psd"  { importPSD(from: url);  return }

        if !checkUnsavedChangesBeforeProceeding() { return }
        errorMessage = nil
        selectedHandles.removeAll()
        selectedFaces3D.removeAll()
        currentProjectPath = nil
        
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let ext = url.pathExtension.lowercased()
        let imageExtensions = ["png", "jpg", "jpeg", "bmp", "tiff", "gif"]
        
        if ext == "dxf" {
            let targetURL = tempDir.appendingPathComponent("active.dxf")
            try? FileManager.default.removeItem(at: targetURL)
            do {
                try FileManager.default.copyItem(at: url, to: targetURL)
                currentFilePath = targetURL
                activeMode = .twoD
                
                isProcessing = true
                Task {
                    do {
                        _ = try await PythonBridge.shared.run(
                            module: "dxf_ops",
                            op: "normalize_dxf",
                            args: ["input": targetURL.path, "output": targetURL.path]
                        )
                        await MainActor.run {
                            self.reloadDXF()
                            self.hasUnsavedChanges = false
                            self.isProcessing = false
                            self.logAction("Load File", details: "Successfully loaded and normalized \(url.lastPathComponent)")
                        }
                    } catch {
                        await MainActor.run {
                            self.errorMessage = "Failed to normalize DXF: \(error.localizedDescription)"
                            self.isProcessing = false
                            self.logAction("Load File Error", details: "Failed to normalize \(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                errorMessage = "Failed to copy input DXF file: \(error.localizedDescription)"
                logAction("Load File Error", details: "Failed to copy input DXF file: \(error.localizedDescription)")
            }
        } else if ext == "step" || ext == "stp" || ext == "obj" || ext == "stl" {
            // Clean up any old active step/obj/stl files
            for oldExt in ["step", "stp", "obj", "stl"] {
                let oldURL = tempDir.appendingPathComponent("active.\(oldExt)")
                try? FileManager.default.removeItem(at: oldURL)
            }
            let targetURL = tempDir.appendingPathComponent("active.\(ext)")
            do {
                try FileManager.default.copyItem(at: url, to: targetURL)
                currentStepFilePath = targetURL
                activeMode = .threeD
                reloadSTEP()
                hasUnsavedChanges = false
                logAction("Load 3D Model", details: "Loaded 3D model: \(url.lastPathComponent)")
            } catch {
                errorMessage = "Failed to copy input 3D model file: \(error.localizedDescription)"
                logAction("Load 3D Model Error", details: "Failed to copy: \(error.localizedDescription)")
            }
        } else if ext == "svg" {
            let tempSVGURL = tempDir.appendingPathComponent("temp_import.svg")
            try? FileManager.default.removeItem(at: tempSVGURL)
            do {
                try FileManager.default.copyItem(at: url, to: tempSVGURL)
                let targetURL = tempDir.appendingPathComponent("active.dxf")
                isProcessing = true
                Task {
                    do {
                        _ = try await PythonBridge.shared.run(
                            module: "dxf_ops",
                            op: "import_svg",
                            args: [
                                "input": tempSVGURL.path,
                                "output": targetURL.path,
                                "consolidate": consolidateSvgStrokes,
                                "thickness": svgImportThickness
                            ]
                        )
                        await MainActor.run {
                            self.currentFilePath = targetURL
                            self.activeMode = .twoD
                            self.selectedHandles.removeAll()
                            self.reloadDXF()
                            self.hasUnsavedChanges = true
                            self.isProcessing = false
                            self.logAction("Import SVG", details: "Imported SVG: \(url.lastPathComponent)")
                        }
                    } catch {
                        await MainActor.run {
                            self.errorMessage = "Failed to convert SVG to DXF: \(error.localizedDescription)"
                            self.isProcessing = false
                            self.logAction("Import SVG Error", details: "Failed to convert: \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                errorMessage = "Failed to copy input SVG file: \(error.localizedDescription)"
                logAction("Import SVG Error", details: "Failed to copy input SVG: \(error.localizedDescription)")
            }
        } else if imageExtensions.contains(ext) || ["webp", "avif", "heic", "tiff", "tif"].contains(ext) {
            loadReferenceImage(from: url)
        } else {
            errorMessage = "Unsupported file extension: .\(url.pathExtension)"
            logAction("Load File Error", details: "Unsupported extension: .\(ext)")
        }
    }

    /// Loads a 3D STEP/STP model into the CURRENT workspace (same window) and
    /// switches it to 3D mode, leaving any existing 2D geometry and the open
    /// project path intact. 3D and 2D share one workspace, one window, one
    /// `.stch` (MAS-107) — only Batch mode and full `.stch` projects get their
    /// own window. Unlike `loadFile`, this never detaches `currentProjectPath`
    /// or wipes the 2D drawing, so importing a model into an open project keeps
    /// everything in place.
    func importStepModel(url: URL) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let ext = url.pathExtension.lowercased()
        let appending = currentStepFilePath != nil
            && FileManager.default.fileExists(atPath: currentStepFilePath!.path)
            && !bodies3D.isEmpty

        do {
            let incomingURL = tempDir.appendingPathComponent("incoming_\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: incomingURL)
            try FileManager.default.copyItem(at: url, to: incomingURL)

            if appending, let existingURL = currentStepFilePath {
                activeMode = .threeD
                isProcessing = true
                
                // Combining step/stl/obj files will output a normalized .step file
                let combinedURL = tempDir.appendingPathComponent("active.step")
                
                Task {
                    do {
                        _ = try await PythonBridge.shared.run(
                            module: "step_ops",
                            op: "combine_steps",
                            args: ["input": existingURL.path,
                                   "incoming": incomingURL.path,
                                   "output": combinedURL.path]
                        )
                        await MainActor.run {
                            if existingURL != combinedURL {
                                try? FileManager.default.removeItem(at: existingURL)
                            }
                            self.currentStepFilePath = combinedURL
                            self.selectedFaces3D.removeAll()
                            self.reloadSTEP()   // re-lists all bodies; viewport redistributes
                            self.logAction("Append 3D Model", details: "Appended 3D model into workspace: \(url.lastPathComponent)")
                        }
                    } catch {
                        await MainActor.run {
                            self.errorMessage = "Failed to append 3D model file: \(error.localizedDescription)"
                            self.isProcessing = false
                        }
                    }
                    try? FileManager.default.removeItem(at: incomingURL)
                }
            } else {
                // Wipe any old active step/obj/stl files
                for oldExt in ["step", "stp", "obj", "stl"] {
                    let oldURL = tempDir.appendingPathComponent("active.\(oldExt)")
                    try? FileManager.default.removeItem(at: oldURL)
                }
                
                let activeURL = tempDir.appendingPathComponent("active.\(ext)")
                try FileManager.default.copyItem(at: incomingURL, to: activeURL)
                try? FileManager.default.removeItem(at: incomingURL)
                
                currentStepFilePath = activeURL
                selectedFaces3D.removeAll()
                activeMode = .threeD
                reloadSTEP()   // sets hasUnsavedChanges = true on success
                logAction("Import 3D Model", details: "Loaded 3D model into workspace: \(url.lastPathComponent)")
            }
        } catch {
            errorMessage = "Failed to import 3D model: \(error.localizedDescription)"
            logAction("Import 3D Model Error", details: "Failed to copy 3D model into workspace: \(error.localizedDescription)")
        }
    }

    func importFiles(_ urls: [URL], dropAt: CGPoint? = nil) {
        guard !urls.isEmpty else { return }
        if activeMode == .batch {
            importFilesToBatch(urls)
            return
        }

        // A window = a workspace. Full projects (.stch) are a whole workspace, so
        // they open in their OWN window. 3D models (.step/.stp) load into THIS
        // workspace and switch it to 3D — 2D and 3D share one window (MAS-107).
        // Everything else (DXF/SVG/PDF/images) merges onto the current 2D canvas.
        let projectExts: Set<String> = ["stch"]
        let stepExts: Set<String> = ["step", "stp", "obj", "stl"]
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "bmp", "tiff", "gif", "webp", "avif", "heic"]

        let openInNewWindow = urls.filter { projectExts.contains($0.pathExtension.lowercased()) }
        let stepModels = urls.filter { stepExts.contains($0.pathExtension.lowercased()) }
        let images = urls.filter { imageExts.contains($0.pathExtension.lowercased()) }
        // PSD files get their own import flow (per-layer + choice dialog, MAS-141).
        let psdFiles = urls.filter { $0.pathExtension.lowercased() == "psd" }
        let toMerge = urls.filter {
            let e = $0.pathExtension.lowercased()
            return !projectExts.contains(e) && !stepExts.contains(e) && !imageExts.contains(e) && e != "psd"
        }

        for fileURL in openInNewWindow {
            WindowManager.shared.openAnyFile(url: fileURL)
        }

        // Load 3D models into this same window/workspace (MAS-107). Dropping a
        // model onto a workspace that already holds one appends it and the
        // viewport distributes them side by side (MAS-125 — handled inside
        // importStepModel).
        for modelURL in stepModels {
            importStepModel(url: modelURL)
        }

        // Load reference images as layers
        for imgURL in images {
            loadReferenceImage(from: imgURL, dropAt: dropAt)
        }

        // PSD: parse layers then prompt for the import mode (MAS-141). Only the
        // first one is prompted at a time; dropping several PSDs queues them.
        for psdURL in psdFiles {
            importPSD(from: psdURL, dropAt: dropAt)
        }

        guard !toMerge.isEmpty else { return }

        // MAS-13 — the number of importable files dropped decides the workflow:
        //   • 5 or more   → route them all into Batch mode (one card per file).
        //   • fewer than 5 → auto-distribute them side by side on the canvas so
        //     they never overlap. (The old merge ran every file through the
        //     positive-quadrant normaliser, stacking them all at the same origin,
        //     which looked like only one file had imported.)
        errorMessage = nil
        if toMerge.count >= 5 {
            activeMode = .batch
            importFilesToBatch(toMerge)
        } else {
            distributeImportFiles(toMerge)
        }
    }

    /// Imports 1–4 files and lays them out side by side on the current canvas
    /// (MAS-13). Each file is converted to a standalone DXF, then a single
    /// `import_distribute` call merges them all with no overlap. Additive — it
    /// never prompts a save dialog and never errors on a supported format.
    private func distributeImportFiles(_ urls: [URL]) {
        let activeURL = ensureActiveDXFFileExists()
        isProcessing = true

        Task {
            do {
                // Flush optimistic edits so we distribute onto current geometry.
                await reconcileBufferIfNeeded()

                // Keep each source URL paired with its temp DXF so imports can be
                // tracked and later reloaded from disk (MAS-76).
                var pairs: [(url: URL, temp: String)] = []
                for url in urls {
                    if let temp = try await convertToTempDXF(url) {
                        pairs.append((url, temp.path))
                    }
                }

                guard !pairs.isEmpty else {
                    await MainActor.run {
                        self.isProcessing = false
                        self.errorMessage = "No importable geometry found in the dropped file(s)."
                    }
                    return
                }

                let layerNames = pairs.map { self.sanitizeLayerName($0.url.deletingPathExtension().lastPathComponent) }
                let result = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "import_distribute",
                    args: [
                        "primary": activeURL.path,
                        "secondaries": pairs.map { $0.temp },
                        "layer_names": layerNames,
                        "output": activeURL.path
                    ]
                )
                let handlesPerFile = (result["data"] as? [String: Any])?["handles_per_file"] as? [[String]] ?? []

                for p in pairs { try? FileManager.default.removeItem(at: URL(fileURLWithPath: p.temp)) }

                await MainActor.run {
                    self.currentFilePath = activeURL
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    // Register one import "fork" per file (MAS-76): the on-disk
                    // origin + the handles it produced, for later reload from disk.
                    for (i, pair) in pairs.enumerated() where i < handlesPerFile.count {
                        let gid = UUID().uuidString
                        self.importSources[gid] = ImportSource(url: pair.url, handles: handlesPerFile[i])
                    }
                    // Fit the view so every imported file is visible at once.
                    self.reloadDXF(fitToContentAfter: true)
                    self.hasUnsavedChanges = true
                    self.logAction("Import & Distribute", details: "Imported and distributed \(pairs.count) file(s) side by side.")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Import failed: \(error.localizedDescription)"
                    self.isProcessing = false
                    self.logAction("Import Files Error", details: error.localizedDescription)
                }
            }
        }
    }

    /// Converts any supported importable file (.dxf/.svg/.pdf/image) into a
    /// single standalone temporary DXF and returns its URL (nil if unsupported
    /// or empty). Heavy geometry conversion runs in Python; the caller owns the
    /// returned temp file. Shared by distribute-import and batch-import.
    private func convertToTempDXF(_ url: URL) async throws -> URL? {
        let ext = url.pathExtension.lowercased()
        let imageExtensions = ["png", "jpg", "jpeg", "bmp", "tiff", "gif", "webp", "avif", "heic"]
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let outURL = tempDir.appendingPathComponent("import_\(UUID().uuidString).dxf")

        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
        }

        if ext == "dxf" {
            try? FileManager.default.removeItem(at: outURL)
            try FileManager.default.copyItem(at: url, to: outURL)
            return outURL
        } else if ext == "svg" {
            let tmpSvg = tempDir.appendingPathComponent("src_\(UUID().uuidString).svg")
            try? FileManager.default.removeItem(at: tmpSvg)
            try FileManager.default.copyItem(at: url, to: tmpSvg)
            _ = try await PythonBridge.shared.run(
                module: "dxf_ops",
                op: "import_svg",
                args: ["input": tmpSvg.path, "output": outURL.path, "consolidate": consolidateSvgStrokes, "thickness": svgImportThickness]
            )
            try? FileManager.default.removeItem(at: tmpSvg)
            return outURL
        } else if ext == "pdf" {
            _ = try await PythonBridge.shared.run(
                module: "dxf_ops",
                op: "import_pdf",
                args: ["input": url.path, "output": outURL.path]
            )
            return outURL
        } else if imageExtensions.contains(ext) {
            let tmpImg = tempDir.appendingPathComponent("src_\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: tmpImg)
            try FileManager.default.copyItem(at: url, to: tmpImg)
            _ = try await PythonBridge.shared.run(
                module: "dxf_ops",
                op: "trace_raster",
                args: ["input": tmpImg.path, "output": outURL.path, "threshold": 127, "turdsize": 2]
            )
            try? FileManager.default.removeItem(at: tmpImg)
            return outURL
        }
        return nil
    }
    
    func importFilesToBatch(_ urls: [URL]) {
        isProcessing = true
        Task {
            do {
                let tempDir = sessionTempDirectory.appendingPathComponent("batch")
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                var newItems: [BatchItem] = []
                for url in urls {
                    // Convert any supported type (.dxf/.svg/.pdf/image) to a DXF
                    // so Batch mode accepts every importable format (MAS-13).
                    guard let convertedURL = try await convertToTempDXF(url) else { continue }
                    let tempFileURL = tempDir.appendingPathComponent("\(UUID().uuidString).dxf")
                    try? FileManager.default.removeItem(at: tempFileURL)
                    try FileManager.default.moveItem(at: convertedURL, to: tempFileURL)

                    // Normalize the file
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "normalize_dxf",
                        args: ["input": tempFileURL.path, "output": tempFileURL.path]
                    )
                    
                    // Generate SVG preview
                    let svgURL = tempDir.appendingPathComponent("\(UUID().uuidString).svg")
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_svg",
                        args: ["input": tempFileURL.path, "output": svgURL.path]
                    )
                    let svgStr = (try? String(contentsOf: svgURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: svgURL)
                    
                    // List entities
                    let listResult = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "list_entities",
                        args: ["input": tempFileURL.path]
                    )
                    var itemsEnts: [DXFEntity] = []
                    if let data = listResult["data"] as? [String: Any],
                       let jsonEntities = data["entities"] as? [[String: Any]] {
                        let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                        itemsEnts = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                    }
                    
                    let item = BatchItem(
                        fileURL: tempFileURL,
                        originalName: url.deletingPathExtension().lastPathComponent,
                        isSelected: true,
                        entities: itemsEnts,
                        svgContent: svgStr
                    )
                    newItems.append(item)
                }
                
                await MainActor.run {
                    self.batchItems.append(contentsOf: newItems)
                    self.isProcessing = false
                    self.logAction("Batch Import", details: "Imported \(newItems.count) files to batch.")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Batch import failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    func massApplySewingHoles() {
        let selectedItems = batchItems.filter { $0.isSelected }
        guard !selectedItems.isEmpty else {
            errorMessage = "No files selected in the batch."
            return
        }
        isProcessing = true
        
        Task {
            do {
                let tempDir = sessionTempDirectory.appendingPathComponent("batch")
                var updatedItems = batchItems
                
                for i in 0..<updatedItems.count {
                    let item = updatedItems[i]
                    guard item.isSelected else { continue }
                    
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "add_holes",
                        args: [
                            "input": item.fileURL.path,
                            "output": item.fileURL.path,
                            "handles": [] as [String],
                            "offset_distance": holeOffsetDistance,
                            "hole_diameter": holeDiameter,
                            "hole_spacing": holeSpacing,
                            "distribution": holeDistribution,
                            "hole_count": holeCount,
                            "pattern": holePattern,
                            "corner_behavior": holeCornerBehavior,
                            "side": holeSide,
                            "row_spacing": holeRowSpacing,
                            "enable_variable_spacing": holeEnableVariableSpacing,
                            "enable_proximity_filter": holeEnableProximityFilter,
                            "enable_corner_interpolation": holeEnableCornerInterpolation,
                            "enable_line_proximity_filter": holeEnableLineProximityFilter,
                            "line_proximity_threshold": holeLineProximityThreshold,
                            "proximity_filter_distance": holeProximityDistance,
                            "variable_spacing_min": holeVariableSpacingMin,
                            "variable_spacing_max": holeVariableSpacingMax,
                            "enable_avoidance": holeEnableAvoidance,
                            "avoidance_radius": holeAvoidanceRadius,
                            "keepout_handles": Array(sewingKeepoutHandles)
                        ]
                    )
                    
                    let svgURL = tempDir.appendingPathComponent("\(UUID().uuidString).svg")
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_svg",
                        args: ["input": item.fileURL.path, "output": svgURL.path]
                    )
                    let svgStr = (try? String(contentsOf: svgURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: svgURL)
                    
                    let listResult = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "list_entities",
                        args: ["input": item.fileURL.path]
                    )
                    var itemsEnts: [DXFEntity] = []
                    if let data = listResult["data"] as? [String: Any],
                       let jsonEntities = data["entities"] as? [[String: Any]] {
                        let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                        itemsEnts = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                    }
                    
                    updatedItems[i].svgContent = svgStr
                    updatedItems[i].entities = itemsEnts
                }
                
                await MainActor.run {
                    self.batchItems = updatedItems
                    self.isProcessing = false
                    self.logAction("Batch Apply Holes", details: "Mass-applied sewing holes to \(selectedItems.count) files.")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Mass apply holes failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    func massApplyOffset() {
        let selectedItems = batchItems.filter { $0.isSelected }
        guard !selectedItems.isEmpty else {
            errorMessage = "No files selected in the batch."
            return
        }
        isProcessing = true
        
        Task {
            do {
                let tempDir = sessionTempDirectory.appendingPathComponent("batch")
                var updatedItems = batchItems
                
                for i in 0..<updatedItems.count {
                    let item = updatedItems[i]
                    guard item.isSelected else { continue }
                    
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "offset_lines",
                        args: [
                            "input": item.fileURL.path,
                            "output": item.fileURL.path,
                            "handles": [] as [String],
                            "distance": offsetDistance,
                            "side": offsetSide,
                            "layer": "OFFSET"
                        ]
                    )
                    
                    let svgURL = tempDir.appendingPathComponent("\(UUID().uuidString).svg")
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_svg",
                        args: ["input": item.fileURL.path, "output": svgURL.path]
                    )
                    let svgStr = (try? String(contentsOf: svgURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: svgURL)
                    
                    let listResult = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "list_entities",
                        args: ["input": item.fileURL.path]
                    )
                    var itemsEnts: [DXFEntity] = []
                    if let data = listResult["data"] as? [String: Any],
                       let jsonEntities = data["entities"] as? [[String: Any]] {
                        let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                        itemsEnts = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                    }
                    
                    updatedItems[i].svgContent = svgStr
                    updatedItems[i].entities = itemsEnts
                }
                
                await MainActor.run {
                    self.batchItems = updatedItems
                    self.isProcessing = false
                    self.logAction("Batch Apply Offset", details: "Mass-applied offset lines to \(selectedItems.count) files.")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Mass apply offset failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    func exportBatch(
        toFolder folderURL: URL,
        namingOption: NamingOption,
        customName: String,
        exportSelectedOnly: Bool,
        format: String
    ) {
        let itemsToExport = batchItems.filter { !exportSelectedOnly || $0.isSelected }
        guard !itemsToExport.isEmpty else {
            errorMessage = "No files to export."
            return
        }
        
        isProcessing = true
        
        Task {
            do {
                let accessing = folderURL.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        folderURL.stopAccessingSecurityScopedResource()
                    }
                }
                
                let folderName = customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Pathstitch_Batch_Export" : customName
                let exportSubfolderURL = folderURL.appendingPathComponent(folderName, isDirectory: true)
                try FileManager.default.createDirectory(at: exportSubfolderURL, withIntermediateDirectories: true)
                
                for (index, item) in itemsToExport.enumerated() {
                    let filename: String
                    if namingOption == .original {
                        filename = "\(item.originalName).\(format)"
                    } else {
                        let baseName = customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Export" : customName
                        filename = "\(baseName)_\(index + 1).\(format)"
                    }
                    
                    let destURL = exportSubfolderURL.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: destURL)
                    
                    if format == "dxf" {
                        try FileManager.default.copyItem(at: item.fileURL, to: destURL)
                    } else {
                        let tempDir = sessionTempDirectory
                        let tempExportURL = tempDir.appendingPathComponent("temp_batch_exp_\(UUID().uuidString).\(format)")
                        try? FileManager.default.removeItem(at: tempExportURL)
                        
                        if format == "svg" {
                            _ = try await PythonBridge.shared.run(
                                module: "dxf_ops",
                                op: "export_svg",
                                args: ["input": item.fileURL.path, "output": tempExportURL.path]
                            )
                        } else if format == "pdf" {
                            _ = try await PythonBridge.shared.run(
                                module: "dxf_ops",
                                op: "export_pdf",
                                args: ["input": item.fileURL.path, "output": tempExportURL.path]
                            )
                        } else if format == "png" {
                            let tempSVG = tempDir.appendingPathComponent("temp_batch_png_\(UUID().uuidString).svg")
                            try? FileManager.default.removeItem(at: tempSVG)
                            _ = try await PythonBridge.shared.run(
                                module: "dxf_ops",
                                op: "export_svg",
                                args: ["input": item.fileURL.path, "output": tempSVG.path]
                            )
                            if let image = NSImage(contentsOf: tempSVG) {
                                guard let tiffData = image.tiffRepresentation,
                                      let bitmapRep = NSBitmapImageRep(data: tiffData),
                                      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                                    throw NSError(domain: "Pathstitch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate PNG bytes"])
                                }
                                try pngData.write(to: tempExportURL)
                            } else {
                                throw NSError(domain: "Pathstitch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load SVG"])
                            }
                            try? FileManager.default.removeItem(at: tempSVG)
                        }
                        
                        try FileManager.default.copyItem(at: tempExportURL, to: destURL)
                        try? FileManager.default.removeItem(at: tempExportURL)
                    }
                }
                
                await MainActor.run {
                    self.isProcessing = false
                    self.logAction("Batch Export", details: "Exported \(itemsToExport.count) files to folder: \(folderName)")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Batch export failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    func reloadSTEP() {
        guard let url = currentStepFilePath else { return }
        
        isProcessing = true
        progress = 0.0
        selectedFaces3D.removeAll()
        forcedSeams3D.removeAll()
        forbiddenSeams3D.removeAll()
        seamControlMode = "auto"
        distortionMode = "conformal"
        distortionDataJSON = ""
        anchorFace3D = nil
        selectedEdge3D = nil
        seamDecorations3D.removeAll()
        liveRecomputeEnabled = false
        netLayout = "connected"
        netMode = "radial"
        netDecoration = "none"
        wholeBodyRecompute = false
        
        Task {
            do {
                let listResult = try await PythonBridge.shared.run(
                    module: "step_ops",
                    op: "list_bodies",
                    args: ["input": url.path]
                )
                
                guard let data = listResult["data"] as? [String: Any],
                      let jsonBodies = data["bodies"] as? [[String: Any]] else {
                    throw PythonBridgeError.invalidResponse("Missing bodies array in output data.")
                }
                
                // Serialize the data portion to JSON string for Three.js
                let modelData = try JSONSerialization.data(withJSONObject: data)
                let modelJsonStr = String(data: modelData, encoding: .utf8) ?? ""
                
                // Decode the bodies for the SwiftUI Solid Bodies list sidebar
                let jsonData = try JSONSerialization.data(withJSONObject: jsonBodies)
                let decodedBodies = try JSONDecoder().decode([Body3D].self, from: jsonData)
                
                await MainActor.run {
                    self.stepJsonContent = modelJsonStr
                    self.bodies3D = decodedBodies
                    self.isProcessing = false
                    self.hasUnsavedChanges = true   // loading a 3D model dirties the doc (MAS-75)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func unfoldFace(bodyIndex: Int, faceIndex: Int) {
        saveToHistory()
        guard let stepUrl = currentStepFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let uuidStr = UUID().uuidString
                let outputDxf = tempDir.appendingPathComponent("unfolded_\(uuidStr).dxf")
                
                var args: [String: Any] = [
                    "input": stepUrl.path,
                    "output": outputDxf.path,
                    "body_index": bodyIndex,
                    "face_index": faceIndex,
                    "distortion_mode": distortionMode
                ]
                if let existing = currentFilePath {
                    args["existing_dxf"] = existing.path
                }
                
                _ = try await PythonBridge.shared.run(
                    module: "step_ops",
                    op: "unfold_face",
                    args: args
                )
                
                await MainActor.run {
                    self.currentFilePath = outputDxf
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    // Optimal framing on a 3D→2D unfold (MAS-67).
                    self.reloadDXF(fitToContentAfter: true)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func unfoldAllSelected() {
        saveToHistory()
        guard let stepUrl = currentStepFilePath else { return }
        if selectedFaces3D.isEmpty { return }
        isProcessing = true
        
        Task {
            do {
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let uuidStr = UUID().uuidString
                let outputDxf = tempDir.appendingPathComponent("unfolded_\(uuidStr).dxf")
                
                let facesArray = Array(selectedFaces3D).map { [
                    "body_index": $0.bodyIndex,
                    "face_index": $0.faceIndex
                ] }
                
                var args: [String: Any] = [
                    "input": stepUrl.path,
                    "output": outputDxf.path,
                    "faces": facesArray,
                    "distortion_mode": distortionMode
                ]
                if let existing = currentFilePath {
                    args["existing_dxf"] = existing.path
                }
                
                _ = try await PythonBridge.shared.run(
                    module: "step_ops",
                    op: "unfold_faces",
                    args: args
                )

                await MainActor.run {
                    self.currentFilePath = outputDxf
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    self.selectedFaces3D.removeAll()
                    // Optimal framing on a 3D→2D unfold (MAS-67).
                    self.reloadDXF(fitToContentAfter: true)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    /// Unfolds the selection (or every face of every body) as connected nets:
    /// faces stay joined at shared straight edges (dashed CREASE lines), cuts
    /// land on SEAM_CUT, and seam pairs optionally get glue tabs or sew holes.
    func unfoldConnected(wholeBody: Bool, mode: String, decoration: String) {
        saveToHistory()
        guard let stepUrl = currentStepFilePath else { return }
        if !wholeBody && selectedFaces3D.isEmpty { return }
        isProcessing = true

        Task {
            do {
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let outputDxf = tempDir.appendingPathComponent("unfolded_net_\(UUID().uuidString).dxf")

                var args: [String: Any] = [
                    "input": stepUrl.path,
                    "output": outputDxf.path,
                    "mode": mode,
                    "decoration": decoration,
                    "tab_height": glueTabHeight,
                    "hole_diameter": holeDiameter,
                    "hole_spacing": holeSpacing,
                    "hole_margin": holeOffsetDistance,
                    "distortion_mode": distortionMode,
                    "seam_control_mode": seamControlMode,
                    "forced_seams": Array(forcedSeams3D).map { [
                        "body_index": $0.bodyIndex,
                        "edge_index": $0.edgeIndex
                    ] },
                    "forbidden_seams": Array(forbiddenSeams3D).map { [
                        "body_index": $0.bodyIndex,
                        "edge_index": $0.edgeIndex
                    ] },
                    "seam_decorations": seamDecorations3D.map { edge, deco in
                        [
                            "body_index": edge.bodyIndex,
                            "edge_index": edge.edgeIndex,
                            "decoration": deco
                        ]
                    }
                ]
                if let anchor = anchorFace3D {
                    args["anchor"] = ["body_index": anchor.bodyIndex, "face_index": anchor.faceIndex]
                }
                if wholeBody {
                    args["whole_body"] = true
                } else {
                    args["faces"] = Array(selectedFaces3D).map { [
                        "body_index": $0.bodyIndex,
                        "face_index": $0.faceIndex
                    ] }
                }
                if let existing = currentFilePath {
                    args["existing_dxf"] = existing.path
                }

                let result = try await PythonBridge.shared.run(
                    module: "step_ops",
                    op: "unfold_connected",
                    args: args
                )

                await MainActor.run {
                    self.currentFilePath = outputDxf
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    self.selectedFaces3D.removeAll()
                    if let data = result["data"] as? [String: Any] {
                        let patches = data["patches"] as? Int ?? 0
                        let faces = data["faces_unfolded"] as? Int ?? 0
                        let folds = data["fold_edges"] as? Int ?? 0
                        var details = "\(faces) face(s) → \(patches) piece(s), \(folds) fold(s)"
                        if let skipped = data["skipped_faces"] as? [[String: Any]], !skipped.isEmpty {
                            details += " — skipped \(skipped.count) non-developable face(s)"
                        }
                        self.logAction("Connected Unfold", details: details)
                    }
                    // Optimal framing on a 3D→2D unfold (MAS-67).
                    self.reloadDXF(fitToContentAfter: true)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func reloadDXF(fitToContentAfter: Bool = false) {
        guard let url = currentFilePath, FileManager.default.fileExists(atPath: url.path) else {
            // No working buffer yet → present an empty canvas, never an error.
            self.svgContent = nil
            self.entities = []
            self.previewEntities = []
            self.layers = []
            self.isProcessing = false
            return
        }

        isProcessing = true
        progress = 0.0
        
        Task {
            do {
                // Ensure temporary output directory exists
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let svgOutputURL = tempDir.appendingPathComponent("preview.svg")
                
                // 1. Export SVG for rendering
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "export_svg",
                    args: ["input": url.path, "output": svgOutputURL.path]
                )
                
                let svgStr = try String(contentsOf: svgOutputURL, encoding: .utf8)
                
                // 2. List entities
                let listResult = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "list_entities",
                    args: ["input": url.path]
                )
                
                guard let data = listResult["data"] as? [String: Any],
                      let jsonEntities = data["entities"] as? [[String: Any]] else {
                    throw PythonBridgeError.invalidResponse("Missing entities array in output data.")
                }
                
                // Decode entities
                let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                let decodedEntities = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                
                // Extract unique layers
                let uniqueLayers = Array(Set(decodedEntities.map { $0.layer })).sorted()
                
                await MainActor.run {
                    self.svgContent = svgStr
                    self.entities = decodedEntities
                    // Append new layers found in DXF if they do not exist, preserving user modifications & ordering
                    for layerName in uniqueLayers {
                        if !self.layers.contains(where: { $0.name == layerName }) {
                            let newLayer = DXFLayer(
                                id: UUID().uuidString,
                                name: layerName,
                                color: self.colorForLayerName(layerName),
                                visible: true,
                                parentFolderId: nil
                            )
                            self.layers.append(newLayer)
                        }
                    }
                    
                    // Back-populate layerId on entities
                    for i in 0..<self.entities.count {
                        if self.entities[i].layerId == nil {
                            if let matched = self.layers.first(where: { $0.name == self.entities[i].layer }) {
                                self.entities[i].layerId = matched.id
                            }
                        }
                    }
                    
                    if self.activeLayerId == nil || !self.layers.contains(where: { $0.id == self.activeLayerId }) {
                        self.activeLayerId = self.layers.first?.id
                    }
                    if fitToContentAfter { self.fitRequestToken += 1 }
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func triggerChainSelect(seedHandle: String) {
        isProcessing = true
        
        Task {
            do {
                // Ensure any pending deletions or optimistic edits are flushed to disk first
                await reconcileBufferIfNeeded()
                
                guard let url = currentFilePath else {
                    await MainActor.run { self.isProcessing = false }
                    return
                }
                
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "chain_select",
                    args: ["input": url.path, "seed_handle": seedHandle, "tolerance": 0.1]
                )
                
                guard let data = res["data"] as? [String: Any],
                      let handlesList = data["handles"] as? [String] else {
                    await MainActor.run { self.isProcessing = false }
                    return
                }
                
                await MainActor.run {
                    if NSEvent.modifierFlags.contains(.shift) {
                        self.selectedHandles.formUnion(handlesList)
                    } else {
                        self.selectedHandles = Set(handlesList)
                    }
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func updateSelectedRectangleFillet(newFillet: Double) {
        guard let selected = selectedMeasurement,
              let handle = selected.entityHandle,
              (selected.dimensionType == "width" || selected.dimensionType == "height") else { return }

        sketchFilletRadius = max(0.0, newFillet)
        for idx in 0..<measurements.count where measurements[idx].entityHandle == handle {
            measurements[idx].filletRadius = sketchFilletRadius
        }
        if selectedMeasurement?.entityHandle == handle {
            selectedMeasurement?.filletRadius = sketchFilletRadius
        }

        // Drive the parametric model so the on-creation fillet is a true arc and
        // remains editable/convertible by the corner tools (MAS-62).
        guard ensureParametricModel(for: handle) != nil, var model = parametricShapes[handle] else { return }
        let targets = filletableIndices(base: model.base, closed: model.closed)
        model.corners = sketchFilletRadius > 1e-9
            ? targets.map { CornerMod(index: $0, kind: "fillet", value: sketchFilletRadius, continuity: "G1") }
            : []
        parametricShapes[handle] = model
        applyParametricShape(handle: handle)
    }

    // MARK: - Free vertex editing (MAS-62)

    /// A handle is a "rectangle" while it still carries its parametric metadata
    /// (rectP1/rectP2). Those vertices show but don't drag — until Expand drops
    /// the constraint and turns it into a freely editable polyline.
    func isRectangleHandle(_ handle: String) -> Bool {
        measurements.contains { $0.entityHandle == handle && $0.rectP1 != nil && $0.rectP2 != nil }
    }

    /// Optimistic, in-memory move of one vertex (called continuously while
    /// dragging). Persisted once on release via `commitEntityVertices`.
    func setEntityVertexLocal(handle: String, index: Int, to point: CGPoint) {
        guard let idx = entities.firstIndex(where: { $0.handle == handle }) else { return }
        var verts = entities[idx].editableVertices
        guard index >= 0 && index < verts.count else { return }
        verts[index] = [Double(point.x), Double(point.y)]
        entities[idx] = entities[idx].withVertices(verts)
        hasUnsavedChanges = true
    }

    /// Writes the current in-memory vertices of `handle` back to the DXF buffer.
    func commitEntityVertices(handle: String) {
        guard let ent = entities.first(where: { $0.handle == handle }) else { return }
        let verts = ent.editableVertices
        guard verts.count >= 2 else { return }
        saveToHistory()
        let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        enqueueBufferWrite {
            let inputPath = (await MainActor.run { self.currentFilePath?.path }) ?? activeDxfURL.path
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "edit_vertices",
                    args: [
                        "input": inputPath,
                        "output": activeDxfURL.path,
                        "handle": handle,
                        "vertices": verts
                    ]
                )
                await MainActor.run { self.currentFilePath = activeDxfURL }
            } catch {
                print("Vertex edit persist failed: \(error)")
            }
        }
    }

    /// Updates a re-edited pen path's entity to a new flattened point list and
    /// persists it (parametric pen lines). Mirrors commitEntityVertices but takes
    /// the points explicitly, since the live anchors — not the stored vertices —
    /// are the source of truth while editing.
    func applyPenEdit(handle: String, points: [[Double]]) {
        guard points.count >= 2, let idx = entities.firstIndex(where: { $0.handle == handle }) else { return }
        saveToHistory()
        entities[idx] = entities[idx].withVertices(points)
        hasUnsavedChanges = true
        let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        enqueueBufferWrite {
            let inputPath = (await MainActor.run { self.currentFilePath?.path }) ?? activeDxfURL.path
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "edit_vertices",
                    args: [
                        "input": inputPath,
                        "output": activeDxfURL.path,
                        "handle": handle,
                        "vertices": points
                    ]
                )
                await MainActor.run { self.currentFilePath = activeDxfURL }
            } catch {
                print("Pen edit persist failed: \(error)")
            }
        }
    }

    /// Right-click → Expand: drops the rectangle constraint (and its parametric
    /// dimensions) on the selected rectangle(s), leaving a free polyline whose
    /// vertices can be dragged.
    func expandSelectedRectangle() {
        let rectHandles = selectedHandles.filter { isRectangleHandle($0) }
        guard !rectHandles.isEmpty else { return }
        saveToHistory()
        measurements.removeAll { m in
            if let h = m.entityHandle { return rectHandles.contains(h) }
            return false
        }
        if let sm = selectedMeasurement, let h = sm.entityHandle, rectHandles.contains(h) {
            selectedMeasurement = nil
        }
        hasUnsavedChanges = true
        logEntries.append(LogEntry(action: "Expand", details: "Converted rectangle to editable polyline"))
    }

    // MARK: - Parametric fillet / chamfer (MAS-62)

    /// The kind ("fillet"/"chamfer") implied by the active tool.
    var cornerToolKind: String { currentTool == .chamfer ? "chamfer" : "fillet" }

    /// Indices of a base polygon's corners that can take a fillet/chamfer.
    private func filletableIndices(base: [[Double]], closed: Bool) -> [Int] {
        guard base.count >= 3 else { return [] }
        return closed ? Array(0..<base.count) : Array(1..<(base.count - 1))
    }

    /// Ensures a parametric model exists for `handle`, seeding the sharp base
    /// from the entity's current vertices. Returns the model (or nil if the
    /// entity isn't a polyline with ≥3 corners).
    @discardableResult
    private func ensureParametricModel(for handle: String) -> ParametricCornerShape? {
        if let existing = parametricShapes[handle] { return existing }
        guard let ent = entities.first(where: { $0.handle == handle }) else { return nil }
        let verts = ent.editableVertices
        guard verts.count >= 3, ent.type.uppercased() == "LWPOLYLINE" || ent.type.uppercased() == "POLYLINE" else { return nil }
        let model = ParametricCornerShape(base: verts, closed: ent.closed ?? false, corners: [])
        parametricShapes[handle] = model
        return model
    }

    /// Activating Fillet/Chamfer with geometry selected: apply (or convert) the
    /// active kind to *every* corner of the selected polyline at the current
    /// value, immediately and live-adjustable (MAS-62).
    func activateCornerToolForSelection() {
        let kind = cornerToolKind
        guard let handle = selectedHandles.first(where: { ensureParametricModel(for: $0) != nil }),
              var model = parametricShapes[handle] else {
            filletSelectedHandle = selectedHandles.first
            return
        }
        filletSelectedHandle = handle
        let targets = filletableIndices(base: model.base, closed: model.closed)
        var existing = Dictionary(uniqueKeysWithValues: model.corners.map { ($0.index, $0) })
        for idx in targets {
            // Each corner keeps its own value; new corners start at a fitting
            // default (10 → 5 → 2 → 0), never one shared number (MAS-91).
            let value = existing[idx]?.value ?? defaultFilletRadius(base: model.base, closed: model.closed, index: idx)
            let cont = existing[idx]?.continuity ?? filletContinuity
            existing[idx] = CornerMod(index: idx, kind: kind, value: value, continuity: cont)
        }
        model.corners = targets.compactMap { existing[$0] }
        parametricShapes[handle] = model
        activeCornerIndex = targets.last
        // Activating the tool on a selected shape selects all its corners together,
        // so adjusting the radius drives them uniformly (MAS-103).
        activeCornerIndices = Set(targets)
        applyParametricShape(handle: handle)
    }

    /// Toggle one corner's modifier (click on a corner with the tool active).
    /// Clicking corner-after-corner (without leaving the tool) accumulates them
    /// into one active group that shares a radius (MAS-103); the new corner adopts
    /// the group's current value so they immediately match.
    func toggleCorner(handle: String, index: Int) {
        guard ensureParametricModel(for: handle) != nil, var model = parametricShapes[handle] else { return }
        // Switching to a different shape starts a fresh group.
        if filletSelectedHandle != handle { activeCornerIndices.removeAll() }
        filletSelectedHandle = handle
        if let i = model.corners.firstIndex(where: { $0.index == index }) {
            model.corners.remove(at: i)
            activeCornerIndices.remove(index)
            if activeCornerIndex == index { activeCornerIndex = activeCornerIndices.max() ?? model.corners.last?.index }
        } else {
            // Join the active group at its shared radius if one exists, otherwise
            // fall back to the per-corner fitting default (MAS-91).
            let value = activeCornerIndices.isEmpty
                ? defaultFilletRadius(base: model.base, closed: model.closed, index: index)
                : filletToolRadius
            model.corners.append(CornerMod(index: index, kind: cornerToolKind, value: value, continuity: filletContinuity))
            activeCornerIndex = index    // last selected — the radius box / arrow anchors here
            activeCornerIndices.insert(index)
            filletToolRadius = value
        }
        parametricShapes[handle] = model
        applyParametricShape(handle: handle)
    }

    /// Re-apply only continuity / kind to the active shape's modified corners,
    /// preserving each corner's individual value (MAS-91 — no universal radius).
    func refreshActiveCornerShape() {
        guard let handle = filletSelectedHandle, var model = parametricShapes[handle], !model.corners.isEmpty else { return }
        let kind = cornerToolKind
        model.corners = model.corners.map {
            CornerMod(index: $0.index, kind: kind, value: $0.value, continuity: filletContinuity)
        }
        parametricShapes[handle] = model
        applyParametricShape(handle: handle)
    }

    /// Sets only the active corner's value (radius box / drag arrow), leaving all
    /// other corners untouched (MAS-91).
    func setActiveCornerValue(_ value: Double) {
        guard let handle = filletSelectedHandle, var model = parametricShapes[handle] else { return }
        let v = max(0, value)
        // Apply to every corner selected together (MAS-103); falls back to just the
        // active corner when only one is selected.
        let group = activeCornerIndices.isEmpty ? Set(activeCornerIndex.map { [$0] } ?? []) : activeCornerIndices
        var changed = false
        for i in model.corners.indices where group.contains(model.corners[i].index) {
            model.corners[i].value = v
            changed = true
        }
        guard changed else { return }
        filletToolRadius = v
        parametricShapes[handle] = model
        applyParametricShape(handle: handle)
    }

    /// Live, in-memory update of the active corner's value while dragging the
    /// radius arrow — no Python, no history, no reload. The canvas draws a local
    /// blended preview; `commitActiveCornerValue()` persists once on release. This
    /// is what makes the fillet drag fluid instead of one round-trip per frame.
    func setActiveCornerValueLocal(_ value: Double) {
        guard let handle = filletSelectedHandle, var model = parametricShapes[handle] else { return }
        let v = max(0, value)
        // Drag the radius arrow → all corners selected together follow (MAS-103).
        let group = activeCornerIndices.isEmpty ? Set(activeCornerIndex.map { [$0] } ?? []) : activeCornerIndices
        for i in model.corners.indices where group.contains(model.corners[i].index) {
            model.corners[i].value = v
        }
        parametricShapes[handle] = model
    }

    /// Persists the active parametric shape after a live arrow drag (one apply).
    func commitActiveCornerValue() {
        guard let handle = filletSelectedHandle else { return }
        applyParametricShape(handle: handle)
    }

    // MARK: - Fillet/Chamfer confirm (Enter) / cancel (Esc) session

    /// Records a revert point when a corner tool is entered, before any corner is
    /// applied. Enter confirms (keep), Esc cancels (revert to here).
    func beginCornerToolSession() {
        cornerSessionUndoDepth = undoStack.count
        activeCornerIndices.removeAll()   // fresh group each session (MAS-103)
    }

    /// Enter — confirm the in-progress fillet/chamfer: keep the changes.
    func confirmCornerToolSession() {
        cornerSessionUndoDepth = nil
    }

    /// Esc — cancel the in-progress fillet/chamfer: revert every change made since
    /// the corner tool was entered (the live-applied blends), then end the session.
    func cancelCornerToolSession() {
        defer {
            cornerSessionUndoDepth = nil
            filletSelectedHandle = nil
            activeCornerIndex = nil
            activeCornerIndices.removeAll()
        }
        guard let depth = cornerSessionUndoDepth, undoStack.count > depth else { return }
        // The first session edit pushed the pre-fillet state at `depth`; restore it
        // and drop the whole session's history.
        let snapshot = undoStack[depth]
        undoStack.removeSubrange(depth...)
        restoreHistoryState(snapshot)
    }

    /// Restores a captured history snapshot in place (no redo push). Shared by the
    /// corner-tool cancel.
    private func restoreHistoryState(_ state: HistoryState) {
        pendingDeletedHandles.removeAll()
        reconcileTask?.cancel()
        self.measurements = state.measurements
        self.selectedHandles = state.selectedHandles
        self.parametricShapes = state.parametricShapes
        self.cornerSnapPoints = state.cornerSnapPoints
        self.penPaths = state.penPaths
        self.selectedMeasurement = nil
        self.hasUnsavedChanges = true
        Task {
            if let dxfData = await state.dxfDataTask.value {
                let activeDxfURL = ensureActiveDXFFileExists()
                do {
                    try dxfData.write(to: activeDxfURL)
                    reloadDXF()
                } catch {
                    errorMessage = "Cancel failed to restore DXF file: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Fillet/Chamfer on a corner built from two separate LINE entities (imported
    /// geometry, two sketched lines). Joins the lines nearest `point` into one open
    /// editable polyline, then blends its middle corner so it stays parametric and
    /// further-editable — the same machinery used for polyline corners.
    func joinLinesAndFillet(at point: CGPoint) {
        guard let url = currentFilePath else { return }
        let kind = cornerToolKind
        saveToHistory()
        isProcessing = true
        Task {
            do {
                await reconcileBufferIfNeeded()
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                let result = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "join_lines",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "point": [Double(point.x), Double(point.y)],
                        "tol": 12.0 / Double(canvasScale)
                    ]
                )
                await MainActor.run {
                    guard let data = result["data"] as? [String: Any],
                          let handle = data["handle"] as? String,
                          let base = data["base"] as? [[Double]] else {
                        self.isProcessing = false
                        return
                    }
                    self.currentFilePath = activeDxfURL
                    // Seed the parametric model for the freshly-joined polyline and
                    // blend its corner (index 1) at a fitting default radius.
                    var model = ParametricCornerShape(base: base, closed: false, corners: [])
                    let value = self.defaultFilletRadius(base: base, closed: false, index: 1)
                    model.corners = [CornerMod(index: 1, kind: kind, value: value, continuity: self.filletContinuity)]
                    self.parametricShapes[handle] = model
                    self.filletSelectedHandle = handle
                    self.activeCornerIndex = 1
                    self.activeCornerIndices = [1]
                    self.filletToolRadius = value
                    self.selectedHandles = [handle]
                    // Reload to pick up the joined polyline, then blend the corner.
                    self.reloadDXF()
                    self.applyParametricShape(handle: handle)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    /// Trim tool (MAS-98): cut the entity's clicked edge at its intersections with
    /// other geometry and remove only the sub-segment under the cursor. `segIndex`
    /// selects which edge of a polyline (0 for a line).
    func trimSegment(handle: String, segIndex: Int = 0, at point: CGPoint) {
        guard let url = currentFilePath else { return }
        // Pen curves trim as one whole curve: a cut removes the entire portion
        // separated by a line, not just one flattened edge (curves-as-curves).
        let whole = penPaths[handle] != nil
        saveToHistory()
        isProcessing = true
        Task {
            do {
                await reconcileBufferIfNeeded()
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "trim_segment",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handle": handle,
                        "seg_index": segIndex,
                        "point": [Double(point.x), Double(point.y)],
                        "whole": whole
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    // A trimmed pen curve is no longer its original parametric
                    // path — drop the model so the fragments are plain polylines.
                    if whole { self.penPaths[handle] = nil }
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    /// Largest radius that fits a corner, snapped to the first of 10 / 5 / 2 that
    /// fits, else 0 (MAS-91 default-on-fillet behavior).
    func defaultFilletRadius(base: [[Double]], closed: Bool, index: Int) -> Double {
        guard base.count >= 3, index >= 0, index < base.count else { return 0 }
        let n = base.count
        let prev = base[(index - 1 + n) % n]
        let cur = base[index]
        let next = base[(index + 1) % n]
        func len(_ a: [Double], _ b: [Double]) -> Double { hypot(a[0]-b[0], a[1]-b[1]) }
        let maxFit = min(len(prev, cur), len(cur, next)) * 0.5
        for preset in [10.0, 5.0, 2.0] where preset <= maxFit { return preset }
        return 0
    }

    /// Regenerate the polyline geometry for one parametric shape and refresh its
    /// snap points. Used on create / edit / convert / resize.
    func applyParametricShape(handle: String, fitAfter: Bool = false) {
        guard let model = parametricShapes[handle], let url = currentFilePath else { return }
        saveToHistory()
        isProcessing = true
        let cornersArg: [[String: Any]] = model.corners.map {
            ["index": $0.index, "kind": $0.kind, "value": $0.value, "continuity": $0.continuity]
        }
        Task {
            do {
                await reconcileBufferIfNeeded()
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                let result = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "apply_corners",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handle": handle,
                        "base": model.base,
                        "closed": model.closed,
                        "corners": cornersArg
                    ]
                )
                await MainActor.run {
                    if let data = result["data"] as? [String: Any],
                       let snaps = data["snaps"] as? [[String: Any]] {
                        self.cornerSnapPoints[handle] = snaps.compactMap { s in
                            guard let x = s["x"] as? Double, let y = s["y"] as? Double,
                                  let role = s["role"] as? String else { return nil }
                            return CornerSnapPoint(x: x, y: y, role: role)
                        }
                    }
                    self.currentFilePath = activeDxfURL
                    self.reloadDXF(fitToContentAfter: fitAfter)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    /// Flip the offset to the other side of the source geometry (MAS-109).
    func flipOffsetDirection() {
        offsetSide = (offsetSide == "left") ? "right" : "left"
        updateLivePreview()
    }

    /// Offset tool with no committed geometry: just leave the tool (Cancel / Esc).
    func cancelOffsetTool() {
        previewEntities = []
        currentTool = .select
    }

    /// `exitAfterApply` true → single-action behavior: commit and return to the
    /// Select arrow (MAS-109 / MAS-111). False keeps the tool active so the user
    /// can offset again (e.g. offsetting an offset line).
    func applyOffset(exitAfterApply: Bool = false) {
        saveToHistory()
        guard let url = currentFilePath else { return }
        isProcessing = true
        let construction = offsetConstruction

        Task {
            do {
                await reconcileBufferIfNeeded()
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                let inputPath = url.path

                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "offset_lines",
                    args: [
                        "input": inputPath,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "distance": offsetDistance,
                        "side": offsetSide,
                        "layer": construction ? "CONSTRUCTION" : "OFFSET",
                        "construction": construction
                    ]
                )

                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.previewEntities = []
                    self.reloadDXF()
                    if exitAfterApply { self.currentTool = .select }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    /// Adds thickness to the selected zero-width lines (or all lines when nothing
    /// is selected), replacing each centerline with a closed outline of
    /// `addThicknessWidth`. Geometry that already has thickness is skipped by the
    /// Python op, so re-running is safe.
    func addThickness(exitAfterApply: Bool = false) {
        saveToHistory()
        guard let url = currentFilePath else { return }
        isProcessing = true
        let width = addThicknessWidth

        Task {
            do {
                await reconcileBufferIfNeeded()
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")

                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "add_thickness",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "thickness": width
                    ]
                )

                await MainActor.run {
                    if let status = res["status"] as? String, status != "ok" {
                        self.errorMessage = (res["message"] as? String) ?? "Add Thickness failed."
                        self.isProcessing = false
                        return
                    }
                    let newHandles = (res["data"] as? [String: Any])?["new_entities"] as? [String] ?? []
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.previewEntities = []
                    self.reloadDXF()
                    self.selectedHandles = Set(newHandles)
                    self.logEntries.append(LogEntry(action: "Add Thickness", details: "Width \(width) mm"))
                    if exitAfterApply { self.currentTool = .select }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    func applySewingHoles() {
        saveToHistory()
        guard let url = currentFilePath else { return }
        isProcessing = true

        Task {
            do {
                await reconcileBufferIfNeeded()
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")

                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "add_holes",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "offset_distance": holeOffsetDistance,
                        "hole_diameter": holeDiameter,
                        "hole_spacing": holeSpacing,
                        "distribution": holeDistribution,
                        "hole_count": holeCount,
                        "pattern": holePattern,
                        "corner_behavior": holeCornerBehavior,
                        "side": holeSide,
                        "row_spacing": holeRowSpacing,
                        "enable_variable_spacing": holeEnableVariableSpacing,
                        "enable_proximity_filter": holeEnableProximityFilter,
                        "enable_corner_interpolation": holeEnableCornerInterpolation,
                        "enable_line_proximity_filter": holeEnableLineProximityFilter,
                        "line_proximity_threshold": holeLineProximityThreshold,
                        "proximity_filter_distance": holeProximityDistance,
                        "variable_spacing_min": holeVariableSpacingMin,
                        "variable_spacing_max": holeVariableSpacingMax,
                        "enable_avoidance": holeEnableAvoidance,
                        "avoidance_radius": holeAvoidanceRadius,
                        "keepout_handles": Array(sewingKeepoutHandles)
                    ]
                )

                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applyCleanup() {
        saveToHistory()
        guard let url = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                await reconcileBufferIfNeeded()
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")

                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "cleanup",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "tolerance": cleanupTolerance
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func assignSelectedToLayer(_ layerName: String) {
        saveToHistory()
        guard let url = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "set_layer",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "layer": layerName
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.reloadDXF()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func exportFile(to url: URL, format: String, selectedOnly: Bool = false) {
        guard let currentUrl = currentFilePath else { return }
        isProcessing = true

        Task {
            do {
                // Flush any optimistic in-memory edits so the export reflects
                // the current model, not a stale buffer (MAS-21).
                await reconcileBufferIfNeeded()
                let tempDir = sessionTempDirectory

                // §6: optionally bake measurement/ruler lines into the export as
                // dashed construction lines (CONSTRUCTION layer, no dimension text).
                var exportInputPath = currentUrl.path
                let wantConstruction = await MainActor.run { self.exportMeasurementLines }
                if wantConstruction {
                    let segments: [[Double]] = await MainActor.run {
                        self.measurements.map { [Double($0.start.x), Double($0.start.y), Double($0.end.x), Double($0.end.y)] }
                    }
                    if !segments.isEmpty {
                        let augmented = tempDir.appendingPathComponent("temp_export_construct_\(UUID().uuidString).dxf")
                        try? FileManager.default.removeItem(at: augmented)
                        try? FileManager.default.copyItem(at: currentUrl, to: augmented)
                        _ = try await PythonBridge.shared.run(
                            module: "dxf_ops",
                            op: "add_construction_lines",
                            args: ["input": augmented.path, "output": augmented.path, "segments": segments]
                        )
                        exportInputPath = augmented.path
                    }
                }

                let tempExportURL = tempDir.appendingPathComponent("temp_export_\(UUID().uuidString).\(format)")
                try? FileManager.default.removeItem(at: tempExportURL)

                let handlesArg: [String]? = selectedOnly ? Array(selectedHandles) : nil
                
                if format == "dxf" {
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_dxf",
                        args: [
                            "input": exportInputPath,
                            "output": tempExportURL.path,
                            "handles": handlesArg as Any
                        ]
                    )
                } else if format == "svg" {
                    var args: [String: Any] = ["input": exportInputPath, "output": tempExportURL.path]
                    if let handles = handlesArg {
                        args["handles"] = handles
                    }
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_svg",
                        args: args
                    )
                } else if format == "pdf" {
                    var args: [String: Any] = ["input": exportInputPath, "output": tempExportURL.path]
                    if let handles = handlesArg {
                        args["handles"] = handles
                    }
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_pdf",
                        args: args
                    )
                } else if format == "png" {
                    let tempSVG = tempDir.appendingPathComponent("temp_export_png_\(UUID().uuidString).svg")
                    try? FileManager.default.removeItem(at: tempSVG)
                    
                    var args: [String: Any] = ["input": exportInputPath, "output": tempSVG.path]
                    if let handles = handlesArg {
                        args["handles"] = handles
                    }
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_svg",
                        args: args
                    )
                    
                    if let image = NSImage(contentsOf: tempSVG) {
                        guard let tiffData = image.tiffRepresentation,
                              let bitmapRep = NSBitmapImageRep(data: tiffData),
                              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                            throw NSError(domain: "Pathstitch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate PNG bytes"])
                        }
                        try pngData.write(to: tempExportURL)
                    } else {
                        throw NSError(domain: "Pathstitch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load SVG into NSImage"])
                    }
                    try? FileManager.default.removeItem(at: tempSVG)
                }
                
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: tempExportURL, to: url)
                try? FileManager.default.removeItem(at: tempExportURL)
                
                await MainActor.run {
                    self.isProcessing = false
                    self.logAction("Export File", details: "Exported successfully to \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                    self.isProcessing = false
                    self.logAction("Export File Error", details: "Failed to export: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// A minimal, valid R2010 DXF that `ezdxf` reads and can append entities to.
    /// Lets us materialise an empty working buffer instantly, with zero Python
    /// round-trips, so a new or cleared canvas never shows a loading screen.
    static let emptyDXFTemplate = """
    0
    SECTION
    2
    HEADER
    9
    $ACADVER
    1
    AC1024
    0
    ENDSEC
    0
    SECTION
    2
    ENTITIES
    0
    ENDSEC
    0
    EOF

    """

    /// Writes a fresh, empty DXF to the session working buffer and returns it.
    /// Synchronous and instant — the canonical way to get a blank document.
    @discardableResult
    func writeEmptyActiveDXF() -> URL {
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("active.dxf")
        do {
            try AppState.emptyDXFTemplate.data(using: .utf8)?.write(to: url)
        } catch {
            // Even if the write somehow fails, downstream edit ops (op_add_entity)
            // recreate a blank doc when the input is missing, so this is non-fatal.
        }
        return url
    }

    /// Resets to a clean, blank workspace backed by a valid empty buffer.
    /// Used for new windows, "New Project", and "Clear Canvas". A blank canvas
    /// is a fully valid first-class state — every tool works on it.
    func startBlankDocument() {
        resetToNewProject()
        let url = writeEmptyActiveDXF()
        currentFilePath = url
        entities = []
        previewEntities = []
        svgContent = nil
        layers = []
        selectedHandles.removeAll()
        isProcessing = false
        hasUnsavedChanges = false
    }

    /// Returns the working-buffer URL, guaranteeing a valid empty DXF exists on
    /// disk. Never returns a path to a missing file.
    func ensureActiveDXFFileExists() -> URL {
        if let path = currentFilePath, FileManager.default.fileExists(atPath: path.path) {
            return path
        }
        let url = writeEmptyActiveDXF()
        currentFilePath = url
        return url
    }
    
    func addSketchedEntity(type: String, params: [String: Any]) async -> String? {
        saveToHistory()
        let activeDxfURL = ensureActiveDXFFileExists()
        let activeLayerName = await MainActor.run {
            if self.activeLayer?.isReferenceImageLayer == true {
                return "0"
            }
            return self.activeLayer?.name ?? "DRAWN_SHAPES"
        }
        await MainActor.run {
            self.isProcessing = true
        }

        do {
            // Flush deferred deletes so the new entity appends to current
            // geometry, never resurrecting a just-deleted entity (MAS-21).
            await reconcileBufferIfNeeded()
            let res = try await PythonBridge.shared.run(
                module: "dxf_ops",
                op: "add_entity",
                args: [
                    "input": activeDxfURL.path,
                    "output": activeDxfURL.path,
                    "type": type,
                    "params": params,
                    "layer": activeLayerName
                ]
            )
            
            let handle = (res["data"] as? [String: Any])?["handle"] as? String
            
            await MainActor.run {
                self.reloadDXF()
            }
            return handle
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isProcessing = false
            }
            return nil
        }
    }
    
    func applyBBoxOffset() {
        saveToHistory()
        let activeDxfURL = ensureActiveDXFFileExists()
        isProcessing = true
        
        Task {
            do {
                let tempDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "offset_bbox",
                    args: [
                        "input": activeDxfURL.path,
                        "output": tempDxfURL.path,
                        "handles": Array(selectedHandles),
                        "distance": bboxOffsetDistance,
                        "fillet_radius": bboxOffsetFillet,
                        "layer": "OFFSET"
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = tempDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    @ObservationIgnored
    private var previewTask: Task<Void, Never>? = nil

    func updateLivePreview() {
        previewTask?.cancel()

        guard !selectedHandles.isEmpty else {
            self.previewEntities = []
            return
        }

        // Offset preview is computed natively in Swift — instant, no Python
        // round-trip — so the ghost tracks the drag handle in real time. The
        // accurate geometry is still produced by Python on commit (applyOffset).
        if currentTool == .offset {
            let selected = entities.filter { selectedHandles.contains($0.handle) }
            self.previewEntities = OffsetGeometry.preview(
                selected: selected,
                distance: offsetDistance,
                side: offsetSide
            )
            return
        }

        guard currentTool == .addHoles, let url = currentFilePath else {
            self.previewEntities = []
            return
        }

        previewTask = Task {
            do {
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let previewDxf = tempDir.appendingPathComponent("preview_temp.dxf")

                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "add_holes",
                    args: [
                        "input": url.path,
                        "output": previewDxf.path,
                        "handles": Array(selectedHandles),
                        "offset_distance": holeOffsetDistance,
                        "hole_diameter": holeDiameter,
                        "hole_spacing": holeSpacing,
                        "distribution": holeDistribution,
                        "hole_count": holeCount,
                        "pattern": holePattern,
                        "corner_behavior": holeCornerBehavior,
                        "side": holeSide,
                        "row_spacing": holeRowSpacing,
                        "enable_variable_spacing": holeEnableVariableSpacing,
                        "enable_proximity_filter": holeEnableProximityFilter,
                        "enable_corner_interpolation": holeEnableCornerInterpolation,
                        "enable_line_proximity_filter": holeEnableLineProximityFilter,
                        "line_proximity_threshold": holeLineProximityThreshold,
                        "proximity_filter_distance": holeProximityDistance,
                        "variable_spacing_min": holeVariableSpacingMin,
                        "variable_spacing_max": holeVariableSpacingMax,
                        "enable_avoidance": holeEnableAvoidance,
                        "avoidance_radius": holeAvoidanceRadius,
                        "keepout_handles": Array(sewingKeepoutHandles)
                    ]
                )

                try Task.checkCancellation()
                
                let listResult = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "list_entities",
                    args: ["input": previewDxf.path]
                )
                
                try Task.checkCancellation()
                
                guard let data = listResult["data"] as? [String: Any],
                      let jsonEntities = data["entities"] as? [[String: Any]] else {
                    return
                }
                
                let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                let decodedEntities = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                let previewOnly = decodedEntities.filter { $0.layer == "PREVIEW" || $0.layer == "SEWING_HOLES" }
                
                await MainActor.run {
                    self.previewEntities = previewOnly
                }
            } catch {
                // Cancelled
            }
        }
    }
    


    private func cropImageToContentBounds(image: NSImage) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let width = cgImage.width
        let height = cgImage.height
        
        guard let colorSpace = cgImage.colorSpace,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixelData = context.data else { return image }
        
        let buffer = pixelData.bindMemory(to: UInt8.self, capacity: width * height * 4)
        
        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let alpha = buffer[index + 3]
                if alpha > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        
        if maxX < minX || maxY < minY {
            return image
        }
        
        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let croppedCgImage = cgImage.cropping(to: cropRect) else { return image }
        
        return NSImage(cgImage: croppedCgImage, size: NSSize(width: cropRect.width, height: cropRect.height))
    }
    
    private func getPngData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }

    func getDecodedImage(for layer: DXFLayer) -> NSImage? {
        if let cached = decodedImageCache[layer.id] {
            return cached
        }
        guard let base64 = layer.refImageBase64,
              let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else {
            return nil
        }
        decodedImageCache[layer.id] = image
        return image
    }
    
    func clearDecodedImageCache() {
        decodedImageCache.removeAll()
    }

    func backupActiveLayerTransform() {
        guard let activeL = activeLayer, activeL.isReferenceImageLayer else { return }
        backupOffsetX = activeL.refImageOffsetX
        backupOffsetY = activeL.refImageOffsetY
        backupScaleX = activeL.refImageScaleX
        backupScaleY = activeL.refImageScaleY
        backupRotation = activeL.refImageRotation
    }
    
    func restoreActiveLayerTransform() {
        guard var activeL = activeLayer, activeL.isReferenceImageLayer else { return }
        activeL.refImageOffsetX = backupOffsetX
        activeL.refImageOffsetY = backupOffsetY
        activeL.refImageScaleX = backupScaleX
        activeL.refImageScaleY = backupScaleY
        activeL.refImageRotation = backupRotation
        
        if let idx = layers.firstIndex(where: { $0.id == activeL.id }) {
            layers[idx] = activeL
        }
    }
    
    func updateActiveLayerTransform(
        offsetX: Double? = nil,
        offsetY: Double? = nil,
        scaleX: Double? = nil,
        scaleY: Double? = nil,
        rotation: Double? = nil,
        opacity: Double? = nil,
        depth: String? = nil,
        locked: Bool? = nil
    ) {
        guard var activeL = activeLayer, activeL.isReferenceImageLayer else { return }
        if let ox = offsetX { activeL.refImageOffsetX = ox }
        if let oy = offsetY { activeL.refImageOffsetY = oy }
        if let sx = scaleX { activeL.refImageScaleX = sx }
        if let sy = scaleY { activeL.refImageScaleY = sy }
        if let rot = rotation { activeL.refImageRotation = rot }
        if let op = opacity { activeL.refImageOpacity = op }
        if let dp = depth { activeL.refImageDepth = dp }
        if let lk = locked { activeL.locked = lk }
        
        if let idx = layers.firstIndex(where: { $0.id == activeL.id }) {
            layers[idx] = activeL
        }
        hasUnsavedChanges = true
    }

    func loadReferenceImage(from url: URL, dropAt: CGPoint? = nil) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "Failed to load reference image."
            return
        }
        
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Failed to read reference image data."
            return
        }
        
        var loadedImage = image
        var loadedData = data
        
        if autocropBackgroundlessImage {
            let cropped = cropImageToContentBounds(image: loadedImage)
            if let croppedData = getPngData(from: cropped) {
                loadedImage = cropped
                loadedData = croppedData
            }
        }
        
        let base64 = loadedData.base64EncodedString()
        let w = Double(loadedImage.size.width)
        let h = Double(loadedImage.size.height)
        
        var pixelW = w
        var pixelH = h
        if let rep = loadedImage.representations.first, rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            pixelW = Double(rep.pixelsWide)
            pixelH = Double(rep.pixelsHigh)
        }
        
        // Compute fitting scale in model space
        let viewW = Double(currentViewportSize.width)
        let viewH = Double(currentViewportSize.height)
        let scale: Double
        if canvasScale > 0.001 {
            let modelViewW = viewW / Double(canvasScale)
            let modelViewH = viewH / Double(canvasScale)
            scale = min((modelViewW * 0.8) / w, (modelViewH * 0.8) / h)
        } else {
            scale = 1.0
        }
        
        // Determine placement (model space coordinates)
        let modelCenter: CGPoint
        if let dropPos = dropAt {
            let dx = (dropPos.x - currentViewportSize.width / 2 - canvasOffset.width) / canvasScale
            let dy = -(dropPos.y - currentViewportSize.height / 2 - canvasOffset.height) / canvasScale
            modelCenter = CGPoint(x: dx, y: dy)
        } else {
            let dx = -Double(canvasOffset.width) / Double(canvasScale)
            let dy = Double(canvasOffset.height) / Double(canvasScale)
            modelCenter = CGPoint(x: dx, y: dy)
        }
        
        // Create a new reference image layer
        let layerName = sanitizeLayerName("Ref_" + url.deletingPathExtension().lastPathComponent)
        var newLayer = DXFLayer(
            id: UUID().uuidString,
            name: layerName,
            color: .blue,
            visible: true,
            parentFolderId: nil
        )
        newLayer.isReferenceImageLayer = true
        newLayer.refImageBase64 = base64
        newLayer.refImageWidth = w
        newLayer.refImageHeight = h
        newLayer.refImagePixelWidth = pixelW
        newLayer.refImagePixelHeight = pixelH
        newLayer.refImageOffsetX = Double(modelCenter.x)
        newLayer.refImageOffsetY = Double(modelCenter.y)
        newLayer.refImageScaleX = scale
        newLayer.refImageScaleY = scale
        newLayer.refImageOpacity = 0.5
        newLayer.refImageDepth = "back"
        
        self.layers.append(newLayer)
        self.activeLayerId = newLayer.id
        
        // Enter transform editing mode immediately
        self.isEditingRefImageTransform = true
        self.backupActiveLayerTransform()
        
        self.hasUnsavedChanges = true
        logEntries.append(LogEntry(action: "Load Reference Image", details: "Loaded reference image layer: \(layerName)"))
    }

    // MARK: - PSD import (MAS-141)

    /// Parses a `.psd` into per-layer raster/vector data via the Python engine,
    /// then presents the centered choice dialog. Additive — never wipes the
    /// canvas; layers merge into the current workspace like any other import.
    func importPSD(from url: URL, dropAt: CGPoint? = nil) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Copy into the session temp dir so the security-scoped handle doesn't
        // have to stay alive across the async parse.
        let localPSD = tempDir.appendingPathComponent("import_\(UUID().uuidString).psd")
        do {
            try? FileManager.default.removeItem(at: localPSD)
            try FileManager.default.copyItem(at: url, to: localPSD)
        } catch {
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
            errorMessage = "Failed to read PSD file: \(error.localizedDescription)"
            return
        }
        if isSecurityScoped { url.stopAccessingSecurityScopedResource() }

        let outDir = tempDir.appendingPathComponent("psd_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let displayName = url.deletingPathExtension().lastPathComponent

        isProcessing = true
        Task {
            do {
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "parse_psd",
                    args: ["input": localPSD.path, "out_dir": outDir.path]
                )
                try? FileManager.default.removeItem(at: localPSD)

                guard res["status"] as? String == "ok",
                      let data = res["data"] as? [String: Any] else {
                    let msg = res["message"] as? String ?? "Failed to parse PSD."
                    await MainActor.run {
                        self.isProcessing = false
                        self.errorMessage = msg
                        self.logAction("Import PSD Error", details: msg)
                    }
                    return
                }

                let parsed = AppState.decodePSDData(data, sourceURL: url, dropAt: dropAt)
                await MainActor.run {
                    self.isProcessing = false
                    guard parsed.totalLayerCount > 0 else {
                        self.errorMessage = "No importable layers found in \(displayName).psd."
                        return
                    }
                    self.pendingPSDImport = parsed
                    self.psdImportDropAt = dropAt
                    self.showPSDImportDialog = true
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.errorMessage = "Failed to parse PSD: \(error.localizedDescription)"
                    self.logAction("Import PSD Error", details: error.localizedDescription)
                }
            }
        }
    }

    /// Decodes the raw `parse_psd` payload into a typed `PSDImportData`.
    static func decodePSDData(_ data: [String: Any], sourceURL: URL, dropAt: CGPoint?) -> PSDImportData {
        let cw = (data["canvas_width"] as? NSNumber)?.doubleValue ?? 0
        let ch = (data["canvas_height"] as? NSNumber)?.doubleValue ?? 0
        let comp = data["composite_png_path"] as? String ?? ""
        let compW = (data["composite_width"] as? NSNumber)?.doubleValue ?? cw
        let compH = (data["composite_height"] as? NSNumber)?.doubleValue ?? ch

        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

        var rasters: [PSDRasterLayer] = []
        var vectors: [PSDVectorLayer] = []
        for l in (data["layers"] as? [[String: Any]] ?? []) {
            let name = l["name"] as? String ?? "Layer"
            let kind = l["kind"] as? String ?? "raster"
            let visible = l["visible"] as? Bool ?? true
            if kind == "vector" {
                var ents: [(vertices: [[Double]], closed: Bool)] = []
                for e in (l["entities"] as? [[String: Any]] ?? []) {
                    let closed = e["closed"] as? Bool ?? true
                    var verts: [[Double]] = []
                    for pair in (e["vertices"] as? [[Any]] ?? []) where pair.count >= 2 {
                        if let x = (pair[0] as? NSNumber)?.doubleValue,
                           let y = (pair[1] as? NSNumber)?.doubleValue {
                            verts.append([x, y])
                        }
                    }
                    if verts.count >= 2 { ents.append((verts, closed)) }
                }
                if !ents.isEmpty {
                    vectors.append(PSDVectorLayer(name: name, entities: ents, visible: visible))
                }
            } else {
                guard let png = l["png_path"] as? String else { continue }
                rasters.append(PSDRasterLayer(
                    name: name, pngPath: png,
                    centerX: num(l["center_x"]), centerY: num(l["center_y"]),
                    widthPx: num(l["width_px"]), heightPx: num(l["height_px"]),
                    visible: visible))
            }
        }

        return PSDImportData(
            sourceURL: sourceURL, canvasWidth: cw, canvasHeight: ch,
            compositePngPath: comp, compositeWidth: compW, compositeHeight: compH,
            rasterLayers: rasters, vectorLayers: vectors,
            totalLayerCount: rasters.count + vectors.count)
    }

    func cancelPSDImport() {
        showPSDImportDialog = false
        pendingPSDImport = nil
        psdImportDropAt = nil
    }

    /// Applies the chosen PSD import mode. Creates one Pathstitch layer per PSD
    /// layer, scaling the whole composition by a single fit factor so the layers
    /// stay registered exactly as they were composed in Photoshop (MAS-141).
    func applyPSDImport(mode: PSDImportMode) {
        guard let psd = pendingPSDImport else { return }
        showPSDImportDialog = false
        pendingPSDImport = nil
        psdVectorizeBatchLayerIds = []
        let dropAt = psdImportDropAt
        psdImportDropAt = nil

        let cw = psd.canvasWidth, ch = psd.canvasHeight
        guard cw > 0, ch > 0 else { return }

        // One fit factor: scale the PSD canvas to ~80% of the current viewport.
        let viewW = Double(currentViewportSize.width)
        let viewH = Double(currentViewportSize.height)
        let fit: Double
        if canvasScale > 0.001 {
            let mvW = viewW / Double(canvasScale)
            let mvH = viewH / Double(canvasScale)
            fit = max(0.0001, min((mvW * 0.8) / cw, (mvH * 0.8) / ch))
        } else {
            fit = 1.0
        }

        // Model-space point the PSD canvas centre maps to (drop point or view centre).
        let board: CGPoint
        if let dropPos = dropAt {
            let dx = (dropPos.x - currentViewportSize.width / 2 - canvasOffset.width) / canvasScale
            let dy = -(dropPos.y - currentViewportSize.height / 2 - canvasOffset.height) / canvasScale
            board = CGPoint(x: dx, y: dy)
        } else {
            board = CGPoint(x: -Double(canvasOffset.width) / Double(canvasScale),
                            y: Double(canvasOffset.height) / Double(canvasScale))
        }

        saveToHistory()
        let activeURL = ensureActiveDXFFileExists()
        currentFilePath = activeURL
        activeMode = .twoD

        let baseName = sanitizeLayerName("PSD_\(psd.sourceURL.deletingPathExtension().lastPathComponent)")

        // Build the reference-image layers (synchronous; no Python) and collect
        // the vector layers to commit.
        var batchIds: [String] = []
        var vectorSpecs: [(layer: String, dicts: [[String: Any]])] = []

        func vectorDicts(_ vec: PSDVectorLayer) -> [[String: Any]] {
            var dicts: [[String: Any]] = []
            for ent in vec.entities {
                var verts: [[Double]] = []
                for p in ent.vertices where p.count >= 2 {
                    verts.append([Double(board.x) + p[0] * fit, Double(board.y) + p[1] * fit])
                }
                if verts.count >= 2 {
                    dicts.append(["type": "LWPOLYLINE", "vertices": verts, "closed": ent.closed])
                }
            }
            return dicts
        }

        switch mode {
        case .loadAsOne:
            _ = createPSDReferenceLayer(name: baseName, pngPath: psd.compositePngPath,
                                        centerX: 0, centerY: 0,
                                        widthPx: psd.compositeWidth, heightPx: psd.compositeHeight,
                                        fit: fit, board: board, visible: true)

        case .loadAsIs, .autoVectorize:
            for v in psd.vectorLayers {
                let dicts = vectorDicts(v)
                if !dicts.isEmpty {
                    let lname = sanitizeLayerName("PSD_\(v.name)")
                    vectorSpecs.append((lname, dicts))
                    if !layers.contains(where: { $0.name == lname }) {
                        layers.append(DXFLayer(id: UUID().uuidString, name: lname, color: .green, visible: v.visible))
                    }
                }
            }
            // Reference images all draw at "back" depth in layer-array order
            // (first = underneath). The parser yields PSD layers top-to-bottom,
            // so append bottom-to-top to reproduce Photoshop's compositing.
            for r in psd.rasterLayers.reversed() {
                if let id = createPSDReferenceLayer(name: sanitizeLayerName("PSD_\(r.name)"),
                                                    pngPath: r.pngPath, centerX: r.centerX, centerY: r.centerY,
                                                    widthPx: r.widthPx, heightPx: r.heightPx,
                                                    fit: fit, board: board, visible: r.visible) {
                    batchIds.append(id)
                }
            }

        case .mergeAndConvert:
            if let id = createPSDReferenceLayer(name: baseName, pngPath: psd.compositePngPath,
                                                centerX: 0, centerY: 0,
                                                widthPx: psd.compositeWidth, heightPx: psd.compositeHeight,
                                                fit: fit, board: board, visible: true) {
                batchIds.append(id)
            }
        }

        let vectorizeAfter = (mode == .autoVectorize || mode == .mergeAndConvert)
        hasUnsavedChanges = true

        // Commit vector layers sequentially (one shared buffer → no races), then
        // refresh and, for the convert modes, hand off to the vectorize panel.
        if vectorSpecs.isEmpty {
            if vectorizeAfter {
                beginPSDVectorize(batchIds)
            }
            logAction("Import PSD", details: "Imported \(psd.totalLayerCount) layer(s) from \(psd.sourceURL.lastPathComponent).")
            return
        }

        isProcessing = true
        let specs = vectorSpecs
        Task {
            await reconcileBufferIfNeeded()
            for spec in specs {
                _ = try? await PythonBridge.shared.run(
                    module: "dxf_ops", op: "commit_trace",
                    args: ["input": activeURL.path, "output": activeURL.path,
                           "layer": spec.layer, "entities": spec.dicts])
            }
            await MainActor.run {
                self.reloadDXF()
                if vectorizeAfter { self.beginPSDVectorize(batchIds) }
                self.logAction("Import PSD", details: "Imported \(psd.totalLayerCount) layer(s) from \(psd.sourceURL.lastPathComponent).")
            }
        }
    }

    /// Creates a reference-image layer from a rendered PSD-layer PNG, placed in
    /// the shared model frame. Returns the new layer id (nil if the PNG can't be
    /// read).
    @discardableResult
    private func createPSDReferenceLayer(name: String, pngPath: String,
                                         centerX: Double, centerY: Double,
                                         widthPx: Double, heightPx: Double,
                                         fit: Double, board: CGPoint, visible: Bool) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pngPath)) else { return nil }
        let base64 = data.base64EncodedString()

        // Use the Python-reported pixel size so display size (= width * fit) is
        // identical across layers and matches the vector placement.
        var w = widthPx, h = heightPx
        if (w <= 0 || h <= 0), let img = NSImage(data: data) {
            w = Double(img.size.width); h = Double(img.size.height)
        }
        guard w > 0, h > 0 else { return nil }

        var layer = DXFLayer(id: UUID().uuidString, name: name, color: .blue, visible: visible, parentFolderId: nil)
        layer.isReferenceImageLayer = true
        layer.refImageBase64 = base64
        layer.refImageWidth = w
        layer.refImageHeight = h
        layer.refImagePixelWidth = w
        layer.refImagePixelHeight = h
        layer.refImageScaleX = fit
        layer.refImageScaleY = fit
        layer.refImageOffsetX = Double(board.x) + centerX * fit
        layer.refImageOffsetY = Double(board.y) + centerY * fit
        layer.refImageOpacity = 1.0   // full opacity so the composition reads true
        layer.refImageDepth = "back"
        layers.append(layer)
        activeLayerId = layer.id
        return layer.id
    }

    /// Enters the shared "vectorize all" pass: the trace panel drives one set of
    /// settings applied to every queued raster layer at once (MAS-141).
    private func beginPSDVectorize(_ ids: [String]) {
        let valid = ids.filter { id in layers.contains(where: { $0.id == id && $0.isReferenceImageLayer }) }
        guard let first = valid.first else { return }
        psdVectorizeBatchLayerIds = valid
        activeLayerId = first
        isEditingRefImageTransform = false
        isTracingRefImage = true
        updateTracePreview()
    }

    /// Traces every queued PSD raster layer with the current trace settings and
    /// commits the vectors, then hides the source images (MAS-141). Falls back to
    /// the single-layer `commitTrace()` when there is no batch.
    func commitPSDVectorizeAll() {
        let ids = psdVectorizeBatchLayerIds
        guard !ids.isEmpty else { commitTrace(); return }

        let activeDxfURL = ensureActiveDXFFileExists()
        saveToHistory()
        isProcessing = true

        let threshold = Int(traceThreshold)
        let tol = traceTolerance, corner = traceCornerSmoothness, popt = tracePathOptimization
        let bgless = backgroundlessMode, useRembg = removeBackgroundMode

        Task {
            await reconcileBufferIfNeeded()
            var committedNames: [String] = []

            for id in ids {
                guard let layer = await MainActor.run(body: { self.layers.first(where: { $0.id == id }) }),
                      layer.isReferenceImageLayer,
                      let b64 = layer.refImageBase64,
                      let imgData = Data(base64Encoded: b64) else { continue }

                let tempImg = sessionTempDirectory.appendingPathComponent("psdtrace_\(id).png")
                let tempDxf = sessionTempDirectory.appendingPathComponent("psdtrace_\(id).dxf")
                do {
                    try imgData.write(to: tempImg)
                    let traceRes = try await PythonBridge.shared.run(
                        module: "dxf_ops", op: "trace_raster",
                        args: ["input": tempImg.path, "output": tempDxf.path,
                               "threshold": threshold, "tolerance": tol,
                               "corner_smoothness": corner, "path_optimization": popt,
                               "backgroundless": bgless, "remove_background": useRembg])
                    guard traceRes["status"] as? String == "ok" else { continue }

                    let listRes = try await PythonBridge.shared.run(
                        module: "dxf_ops", op: "list_entities", args: ["input": tempDxf.path])
                    guard let ldata = listRes["data"] as? [String: Any],
                          let entDicts = ldata["entities"] as? [[String: Any]] else { continue }
                    let decoded = entDicts.compactMap { d -> DXFEntity? in
                        guard let jd = try? JSONSerialization.data(withJSONObject: d),
                              let e = try? JSONDecoder().decode(DXFEntity.self, from: jd) else { return nil }
                        return e
                    }
                    let dicts = self.transformTraceEntities(decoded, layer: layer)
                    guard !dicts.isEmpty else { continue }
                    let targetName = self.sanitizeLayerName("\(layer.name)_traced")
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops", op: "commit_trace",
                        args: ["input": activeDxfURL.path, "output": activeDxfURL.path,
                               "layer": targetName, "entities": dicts])
                    committedNames.append(targetName)
                } catch { /* skip this layer, keep going */ }
                try? FileManager.default.removeItem(at: tempImg)
                try? FileManager.default.removeItem(at: tempDxf)
            }

            let names = committedNames
            let processedIds = ids
            await MainActor.run {
                for n in names where !self.layers.contains(where: { $0.name == n }) {
                    self.layers.append(DXFLayer(id: UUID().uuidString, name: n, color: .green, visible: true))
                }
                for id in processedIds {
                    if let idx = self.layers.firstIndex(where: { $0.id == id }) {
                        self.layers[idx].visible = false
                    }
                }
                self.currentFilePath = activeDxfURL
                self.activeMode = .twoD
                self.isTracingRefImage = false
                self.tracePreviewEntities = []
                self.psdVectorizeBatchLayerIds = []
                self.reloadDXF()
                self.hasUnsavedChanges = true
                self.logAction("PSD Vectorize", details: "Vectorized \(names.count) PSD raster layer(s).")
            }
        }
    }

    /// Maps traced entities (image-pixel space) into model space using a
    /// reference-image layer's placement. Shared by `commitTrace` and the PSD
    /// batch vectorize pass.
    func transformTraceEntities(_ entities: [DXFEntity], layer: DXFLayer) -> [[String: Any]] {
        let w = layer.refImageWidth, h = layer.refImageHeight
        let scaleX = layer.refImageScaleX, scaleY = layer.refImageScaleY
        let rot = layer.refImageRotation
        let offX = layer.refImageOffsetX, offY = layer.refImageOffsetY
        let pixelW = layer.refImagePixelWidth > 0 ? layer.refImagePixelWidth : w
        let pixelH = layer.refImagePixelHeight > 0 ? layer.refImagePixelHeight : h
        let rad = rot * .pi / 180.0
        let cosR = cos(rad), sinR = sin(rad)

        var out: [[String: Any]] = []
        for ent in entities {
            guard let vertices = ent.vertices else { continue }
            var tv: [[Double]] = []
            for pt in vertices where pt.count >= 2 {
                let sx = pt[0] * (w / pixelW)
                let sy = pt[1] * (h / pixelH)
                let x1 = sx - w / 2.0, y1 = sy - h / 2.0
                let x2 = x1 * scaleX, y2 = y1 * scaleY
                let x3 = x2 * cosR - y2 * sinR
                let y3 = x2 * sinR + y2 * cosR
                tv.append([offX + x3, offY + y3])
            }
            if tv.count >= 2 {
                out.append(["type": "LWPOLYLINE", "vertices": tv, "closed": ent.closed ?? true])
            }
        }
        return out
    }

    func commitCalibrationDistance() {
        guard var activeL = activeLayer, activeL.isReferenceImageLayer else { return }
        guard calibrationPoints.count == 2 else { return }
        if let val = Double(calibrationTempDistanceText), val > 0 {
            self.calibrationDistance = val
            let p1 = calibrationPoints[0]
            let p2 = calibrationPoints[1]
            let modelDistance = Double(hypot(p2.x - p1.x, p2.y - p1.y))
            if modelDistance > 1e-5 {
                let ratio = val / modelDistance
                activeL.refImageScaleX = activeL.refImageScaleX * ratio
                activeL.refImageScaleY = activeL.refImageScaleY * ratio
                
                // Update the layer in the layers array
                if let idx = layers.firstIndex(where: { $0.id == activeL.id }) {
                    layers[idx] = activeL
                }
                
                logEntries.append(LogEntry(action: "Calibrate Reference Image", details: "Calibrated 2 points. Target: \(val)mm, Measured: \(modelDistance)mm, scale factor: \(ratio)"))
            }
        }
        calibrationPoints.removeAll()
        isCalibratingDistanceInput = false
        hasUnsavedChanges = true
    }
    
    private var traceTask: Task<Void, Never>? = nil
    
    func updateTracePreview() {
        guard let activeL = activeLayer, activeL.isReferenceImageLayer else { return }
        
        traceTask?.cancel()
        
        traceTask = Task {
            // Write base64 image to temp PNG file
            guard let imgData = Data(base64Encoded: activeL.refImageBase64 ?? "") else { return }
            let tempDir = sessionTempDirectory
            let tempImgURL = tempDir.appendingPathComponent("trace_temp_\(activeL.id).png")
            let tempDxfURL = tempDir.appendingPathComponent("trace_temp_\(activeL.id).dxf")
            
            do {
                try imgData.write(to: tempImgURL)
                
                // Run python trace_raster
                let traceRes = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "trace_raster",
                    args: [
                        "input": tempImgURL.path,
                        "output": tempDxfURL.path,
                        "threshold": Int(self.traceThreshold),
                        "tolerance": self.traceTolerance,
                        "corner_smoothness": self.traceCornerSmoothness,
                        "path_optimization": self.tracePathOptimization,
                        "backgroundless": self.backgroundlessMode,
                        "remove_background": self.removeBackgroundMode
                    ]
                )
                
                guard traceRes["status"] as? String == "ok" else {
                    print("Python trace failed: \(traceRes["message"] ?? "")")
                    return
                }
                
                // Run python list_entities to parse the generated DXF
                let listRes = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "list_entities",
                    args: ["input": tempDxfURL.path]
                )
                
                guard listRes["status"] as? String == "ok" else { return }
                
                // Parse entities
                if let data = listRes["data"] as? [String: Any],
                   let entDicts = data["entities"] as? [[String: Any]] {
                    let decoded = entDicts.compactMap { dict -> DXFEntity? in
                        guard let data = try? JSONSerialization.data(withJSONObject: dict),
                              let ent = try? JSONDecoder().decode(DXFEntity.self, from: data) else {
                            return nil
                        }
                        return ent
                    }
                    
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.tracePreviewEntities = decoded
                        }
                    }
                }
                
                // Cleanup temp files
                try? FileManager.default.removeItem(at: tempImgURL)
                try? FileManager.default.removeItem(at: tempDxfURL)
            } catch {
                print("Failed to run trace preview: \(error)")
            }
        }
    }
    
    func commitTrace() {
        guard let activeL = activeLayer, activeL.isReferenceImageLayer else { return }

        // Target layer name is "{RefImageName}_traced"
        let targetLayerName = sanitizeLayerName("\(activeL.name)_traced")

        // Transform the entities into model space (shared with PSD vectorize).
        let transformedDicts = transformTraceEntities(tracePreviewEntities, layer: activeL)

        guard !transformedDicts.isEmpty else { return }
        
        saveToHistory()
        let activeDxfURL = ensureActiveDXFFileExists()
        isProcessing = true
        
        Task {
            do {
                await reconcileBufferIfNeeded()
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "commit_trace",
                    args: [
                        "input": activeDxfURL.path,
                        "output": activeDxfURL.path,
                        "layer": targetLayerName,
                        "entities": transformedDicts
                    ]
                )
                
                await MainActor.run {
                    self.isProcessing = false
                    if res["status"] as? String == "ok" {
                        // Create target layer if not exists
                        if !self.layers.contains(where: { $0.name == targetLayerName }) {
                            let newL = DXFLayer(
                                id: UUID().uuidString,
                                name: targetLayerName,
                                color: .green,
                                visible: true,
                                parentFolderId: nil
                            )
                            self.layers.append(newL)
                            self.activeLayerId = newL.id
                        } else if let matched = self.layers.first(where: { $0.name == targetLayerName }) {
                            self.activeLayerId = matched.id
                        }
                        
                        // Hide the reference image layer
                        if let idx = self.layers.firstIndex(where: { $0.id == activeL.id }) {
                            self.layers[idx].visible = false
                        }
                        
                        // Turn off trace mode
                        self.isTracingRefImage = false
                        self.tracePreviewEntities = []
                        
                        // Reload DXF to show the newly committed vectors
                        self.reloadDXF()
                        self.hasUnsavedChanges = true
                    } else {
                        self.errorMessage = res["message"] as? String ?? "Failed to commit trace."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    func generatePreviewPNG(size: CGSize = CGSize(width: 1500, height: 1000)) -> Data? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        
        // Opaque white background — previews are plain black-on-white line art so
        // they read correctly as Finder/Quick Look thumbnails and recent-project
        // cards regardless of the surrounding chrome.
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        context.fill(CGRect(origin: .zero, size: size))

        if entities.isEmpty {
            // Draw a generic placeholder wordmark centered (font scales with the
            // canvas so it reads the same regardless of render resolution).
            let font = NSFont.systemFont(ofSize: size.height * 0.0875, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
            ]
            let string = NSAttributedString(string: "Pathstitch", attributes: attrs)
            let sizeStr = string.size()
            let rect = CGRect(
                x: (size.width - sizeStr.width) / 2,
                y: (size.height - sizeStr.height) / 2,
                width: sizeStr.width,
                height: sizeStr.height
            )
            
            let nsGraphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsGraphicsContext
            string.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Compute bounds
            var minX = Double.infinity
            var maxX = -Double.infinity
            var minY = Double.infinity
            var maxY = -Double.infinity
            
            for ent in entities {
                // Frame only what's actually drawn: skip geometry on hidden layers
                // so an invisible (toggled-off) entity can't inflate the bounds and
                // shove the visible drawing into a corner.
                let layerVisible = layers.first(where: { $0.name == ent.layer })?.visible ?? true
                if !layerVisible { continue }

                if ent.type == "LINE", let s = ent.start, let e = ent.end {
                    minX = min(minX, s[0], e[0])
                    maxX = max(maxX, s[0], e[0])
                    minY = min(minY, s[1], e[1])
                    maxY = max(maxY, s[1], e[1])
                } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
                    minX = min(minX, center[0] - radius)
                    maxX = max(maxX, center[0] + radius)
                    minY = min(minY, center[1] - radius)
                    maxY = max(maxY, center[1] + radius)
                } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius {
                    minX = min(minX, center[0] - radius)
                    maxX = max(maxX, center[0] + radius)
                    minY = min(minY, center[1] - radius)
                    maxY = max(maxY, center[1] + radius)
                } else if let vertices = ent.vertices {
                    for pt in vertices {
                        minX = min(minX, pt[0])
                        maxX = max(maxX, pt[0])
                        minY = min(minY, pt[1])
                        maxY = max(maxY, pt[1])
                    }
                }
            }
            
            let bounds: CGRect
            if minX == .infinity {
                bounds = CGRect(x: -50, y: -50, width: 100, height: 100)
            } else {
                bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            
            let centerX = bounds.midX
            let centerY = bounds.midY
            // Tight framing: a small fixed margin (≈6%) instead of a fat 20% inset,
            // so the drawing fills the card and the scale adapts to whatever the
            // visible bounds happen to be — little blank space, no fixed gutter.
            let margin = max(min(size.width, size.height) * 0.06, 8.0)
            let usableW = size.width - margin * 2
            let usableH = size.height - margin * 2
            let scaleX = bounds.width > 0 ? (usableW / bounds.width) : 1.0
            let scaleY = bounds.height > 0 ? (usableH / bounds.height) : 1.0
            let scale = min(scaleX, scaleY)

            // Line width scales with render resolution so strokes stay visible when
            // a high-res preview is downscaled to a Finder icon and crisp when it's
            // shown large in Quick Look.
            let strokeWidth = max(1.5, min(size.width, size.height) / 240.0)
            
            // The CGContext is y-up (origin bottom-left), same as DXF model space,
            // so map y with a + sign. Subtracting here flipped every preview
            // upside-down.
            func toScreen(dx: Double, dy: Double) -> CGPoint {
                return CGPoint(
                    x: size.width / 2 + CGFloat(dx - centerX) * scale,
                    y: size.height / 2 + CGFloat(dy - centerY) * scale
                )
            }
            
            // Draw each visible entity
            for ent in entities {
                let layerVisible = layers.first(where: { $0.name == ent.layer })?.visible ?? true
                if !layerVisible { continue }

                // Plain black line art, irrespective of layer colour.
                context.setStrokeColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
                context.setLineWidth(strokeWidth)
                
                if ent.type == "LINE", let s = ent.start, let e = ent.end {
                    let p1 = toScreen(dx: s[0], dy: s[1])
                    let p2 = toScreen(dx: e[0], dy: e[1])
                    context.move(to: p1)
                    context.addLine(to: p2)
                    context.strokePath()
                } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
                    let sc = toScreen(dx: center[0], dy: center[1])
                    let r = CGFloat(radius) * scale
                    context.addEllipse(in: CGRect(x: sc.x - r, y: sc.y - r, width: r * 2, height: r * 2))
                    context.strokePath()
                } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius,
                          let sa = ent.start_angle, let ea = ent.end_angle {
                    let sc = toScreen(dx: center[0], dy: center[1])
                    let r = CGFloat(radius) * scale
                    // y-up context matches DXF's CCW angle convention.
                    let startRad = CGFloat(sa * .pi / 180.0)
                    let endRad = CGFloat(ea * .pi / 180.0)
                    context.addArc(center: sc, radius: r, startAngle: startRad, endAngle: endRad, clockwise: false)
                    context.strokePath()
                } else if let vertices = ent.vertices, vertices.count >= 2 {
                    let pStart = toScreen(dx: vertices[0][0], dy: vertices[0][1])
                    context.move(to: pStart)
                    for i in 1..<vertices.count {
                        let p = toScreen(dx: vertices[i][0], dy: vertices[i][1])
                        context.addLine(to: p)
                    }
                    if ent.closed == true {
                        context.closePath()
                    }
                    context.strokePath()
                }
            }
        }
        
        guard let cgImage = context.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: size)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
    }
    
    func saveProject(to url: URL) {
        // A blank project is valid and must be saveable — materialise an empty
        // working buffer if one doesn't exist yet rather than erroring out.
        let dxfURL: URL
        if let p = currentFilePath, FileManager.default.fileExists(atPath: p.path) {
            dxfURL = p
        } else {
            dxfURL = writeEmptyActiveDXF()
            currentFilePath = dxfURL
        }

        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            let dxfData = try Data(contentsOf: dxfURL)
            let base64Dxf = dxfData.base64EncodedString()

            // Snapshot any batch session so .stch round-trips it (MAS-24).
            let savedBatch: [BatchItemSave]? = batchItems.isEmpty ? nil : batchItems.compactMap { item in
                guard let data = try? Data(contentsOf: item.fileURL) else { return nil }
                return BatchItemSave(
                    originalName: item.originalName,
                    dxfDataBase64: data.base64EncodedString(),
                    isSelected: item.isSelected,
                    svgContent: item.svgContent,
                    entities: item.entities
                )
            }

            let container = ProjectSaveContainer(
                dxfDataBase64: base64Dxf,
                measurements: measurements,
                logEntries: logEntries,
                canvasScale: Double(canvasScale),
                canvasOffsetX: Double(canvasOffset.width),
                canvasOffsetY: Double(canvasOffset.height),
                refImageBase64: refImageBase64,
                refImageOffsetX: Double(refImageOffset.width),
                refImageOffsetY: Double(refImageOffset.height),
                refImageScale: Double(refImageScale),
                refImageOpacity: refImageOpacity,
                refImageCalibrationDistance: calibrationDistance,
                refImageCalibrationStartX: calibrationPoints.first.map { Double($0.x) },
                refImageCalibrationStartY: calibrationPoints.first.map { Double($0.y) },
                refImageCalibrationEndX: calibrationPoints.count > 1 ? Double(calibrationPoints[1].x) : nil,
                refImageCalibrationEndY: calibrationPoints.count > 1 ? Double(calibrationPoints[1].y) : nil,
                isLearnModeEnabled: isLearnModeEnabled,
                parametricShapes: parametricShapes.isEmpty ? nil : parametricShapes,
                penPaths: penPaths.isEmpty ? nil : penPaths,
                offsetDistance: offsetDistance,
                offsetSide: offsetSide,
                holeOffsetDistance: holeOffsetDistance,
                holeDiameter: holeDiameter,
                holeSpacing: holeSpacing,
                holeDistribution: holeDistribution,
                holeCount: holeCount,
                holePattern: holePattern,
                holeCornerBehavior: holeCornerBehavior,
                holeSide: holeSide,
                holeRowSpacing: holeRowSpacing,
                glueTabHeight: glueTabHeight,
                glueTabType: glueTabType,
                glueTabSide: glueTabSide,
                glueTabStartOffset: glueTabStartOffset,
                glueTabEndOffset: glueTabEndOffset,
                batchItems: savedBatch,
                exportMeasurementLines: exportMeasurementLines,
                savedLayers: layers,
                savedLayerFolders: layerFolders,
                savedActiveLayerId: activeLayerId,
                savedStepJson: stepJsonContent,
                savedBodies3D: bodies3D.isEmpty ? nil : bodies3D,
                savedBodyOffsets: bodyOffsets.isEmpty ? nil : bodyOffsets.map {
                    BodyOffsetSave(bodyIndex: $0.key, x: $0.value[0], y: $0.value[1], z: $0.value[2])
                }
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let jsonData = try encoder.encode(container)
            
            // Delete old file if it exists to overwrite completely
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            
            let archive = try Archive(url: url, accessMode: .create)
            
            // Add project.json
            try archive.addEntry(with: "project.json", type: .file, uncompressedSize: UInt32(jsonData.count), provider: { (position, size) -> Data in
                return jsonData.subdata(in: position..<position+size)
            })
            
            // Generate and add preview.png
            if let previewData = generatePreviewPNG() {
                try archive.addEntry(with: "preview.png", type: .file, uncompressedSize: UInt32(previewData.count), provider: { (position, size) -> Data in
                    return previewData.subdata(in: position..<position+size)
                })
            }
            
            self.currentProjectPath = url
            self.hasUnsavedChanges = false
            logEntries.append(LogEntry(action: "Save Project", details: "Saved project successfully to \(url.lastPathComponent)"))
        } catch {
            errorMessage = "Failed to save project: \(error.localizedDescription)"
        }
    }
    
    func loadProject(from url: URL) {
        if !checkUnsavedChangesBeforeProceeding() { return }
        errorMessage = nil
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            var container: ProjectSaveContainer? = nil
            
            // Try loading as ZIP archive first
            if let archive = try? Archive(url: url, accessMode: .read) {
                if let entry = archive["project.json"] {
                    var projectData = Data()
                    _ = try archive.extract(entry, consumer: { chunk in
                        projectData.append(chunk)
                    })
                    container = try? JSONDecoder().decode(ProjectSaveContainer.self, from: projectData)
                }
            }
            
            // Fallback to plain JSON for older project files
            if container == nil {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                container = try decoder.decode(ProjectSaveContainer.self, from: data)
            }
            
            guard let validContainer = container else {
                errorMessage = "Failed to decode project save container."
                return
            }
            
            let tempDir = sessionTempDirectory
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let targetURL = tempDir.appendingPathComponent("active.dxf")
            
            if let dxfBase64 = validContainer.dxfDataBase64, let dxfData = Data(base64Encoded: dxfBase64) {
                try dxfData.write(to: targetURL)
                self.currentFilePath = targetURL
            } else {
                // Project carried no geometry → open onto a valid blank buffer.
                self.currentFilePath = writeEmptyActiveDXF()
            }

            self.currentProjectPath = url
            self.measurements = validContainer.measurements
            self.rebuildDimensionEngine()   // restore parameter table (MAS-110)
            self.layers = validContainer.savedLayers ?? []
            self.layerFolders = validContainer.savedLayerFolders ?? []
            self.activeLayerId = validContainer.savedActiveLayerId
            // Restore the 3D workspace that travels inside the .stch (MAS-75).
            self.stepJsonContent = validContainer.savedStepJson
            self.bodies3D = validContainer.savedBodies3D ?? []
            self.bodyOffsets = Dictionary(uniqueKeysWithValues:
                (validContainer.savedBodyOffsets ?? []).map { ($0.bodyIndex, [$0.x, $0.y, $0.z]) })
            self.logEntries = validContainer.logEntries
            self.canvasScale = CGFloat(validContainer.canvasScale)
            self.canvasOffset = CGSize(width: CGFloat(validContainer.canvasOffsetX), height: CGFloat(validContainer.canvasOffsetY))
            
            self.refImageBase64 = validContainer.refImageBase64
            if let base64 = validContainer.refImageBase64, let imgData = Data(base64Encoded: base64) {
                self.refImage = NSImage(data: imgData)
            } else {
                self.refImage = nil
            }
            
            self.refImageOffset = CGSize(width: CGFloat(validContainer.refImageOffsetX), height: CGFloat(validContainer.refImageOffsetY))
            self.refImageScale = CGFloat(validContainer.refImageScale)
            self.refImageOpacity = validContainer.refImageOpacity
            self.calibrationDistance = validContainer.refImageCalibrationDistance
            
            self.calibrationPoints.removeAll()
            if let sx = validContainer.refImageCalibrationStartX, let sy = validContainer.refImageCalibrationStartY {
                self.calibrationPoints.append(CGPoint(x: sx, y: sy))
            }
            if let ex = validContainer.refImageCalibrationEndX, let ey = validContainer.refImageCalibrationEndY {
                self.calibrationPoints.append(CGPoint(x: ex, y: ey))
            }
            
            if let learn = validContainer.isLearnModeEnabled { self.isLearnModeEnabled = learn }
            if let pShapes = validContainer.parametricShapes { self.parametricShapes = pShapes }
            if let pp = validContainer.penPaths { self.penPaths = pp }
            if let dist = validContainer.offsetDistance { self.offsetDistance = dist }
            if let side = validContainer.offsetSide { self.offsetSide = side }
            if let hDist = validContainer.holeOffsetDistance { self.holeOffsetDistance = hDist }
            if let hDiam = validContainer.holeDiameter { self.holeDiameter = hDiam }
            if let hSpac = validContainer.holeSpacing { self.holeSpacing = hSpac }
            if let hDistr = validContainer.holeDistribution { self.holeDistribution = hDistr }
            if let hCnt = validContainer.holeCount { self.holeCount = hCnt }
            if let hPat = validContainer.holePattern { self.holePattern = hPat }
            if let hCorn = validContainer.holeCornerBehavior { self.holeCornerBehavior = hCorn }
            if let hSide = validContainer.holeSide { self.holeSide = hSide }
            if let hRow = validContainer.holeRowSpacing { self.holeRowSpacing = hRow }
            if let gtHeight = validContainer.glueTabHeight { self.glueTabHeight = gtHeight }
            if let gtType = validContainer.glueTabType { self.glueTabType = gtType }
            if let gtSide = validContainer.glueTabSide { self.glueTabSide = gtSide }
            if let gtStart = validContainer.glueTabStartOffset { self.glueTabStartOffset = gtStart }
            if let gtEnd = validContainer.glueTabEndOffset { self.glueTabEndOffset = gtEnd }
            self.exportMeasurementLines = validContainer.exportMeasurementLines ?? false

            // Restore a persisted batch session, if any (MAS-24). DXFs are
            // written back to the session batch dir; svg/entities come straight
            // from the snapshot so no Python work is needed on load.
            self.batchItems = []
            if let savedBatch = validContainer.batchItems, !savedBatch.isEmpty {
                let batchDir = sessionTempDirectory.appendingPathComponent("batch")
                try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
                for saved in savedBatch {
                    guard let data = Data(base64Encoded: saved.dxfDataBase64) else { continue }
                    let fileURL = batchDir.appendingPathComponent("\(UUID().uuidString).dxf")
                    do {
                        try data.write(to: fileURL)
                        self.batchItems.append(BatchItem(
                            fileURL: fileURL,
                            originalName: saved.originalName,
                            isSelected: saved.isSelected,
                            entities: saved.entities,
                            svgContent: saved.svgContent
                        ))
                    } catch { }
                }
            }

            self.activeMode = .twoD
            self.selectedHandles.removeAll()
            self.reloadDXF()
            self.hasUnsavedChanges = false
            
            logEntries.append(LogEntry(action: "Load Project", details: "Loaded project successfully from \(url.lastPathComponent)"))
        } catch {
            errorMessage = "Failed to load project: \(error.localizedDescription)"
        }
    }

    func saveProjectWithDialog() {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Project"
        
        let defaultDir: URL
        if let currentPath = currentProjectPath {
            defaultDir = currentPath.deletingLastPathComponent()
        } else {
            defaultDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        
        var index = 0
        var filename = "untitled.stch"
        while FileManager.default.fileExists(atPath: defaultDir.appendingPathComponent(filename).path) {
            index += 1
            filename = "untitled-\(index).stch"
        }
        
        savePanel.directoryURL = defaultDir
        savePanel.nameFieldStringValue = filename
        
        if let stchType = UTType("com.chen.pathstitch.stch") {
            savePanel.allowedContentTypes = [stchType]
        } else {
            savePanel.allowedContentTypes = [UTType(filenameExtension: "stch")].compactMap { $0 }
        }
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            self.saveProject(to: url)
        }
    }
    
    func combineProject(from url: URL) {
        errorMessage = nil
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            var container: ProjectSaveContainer? = nil
            
            // Try loading as ZIP archive first
            if let archive = try? Archive(url: url, accessMode: .read) {
                if let entry = archive["project.json"] {
                    var projectData = Data()
                    _ = try archive.extract(entry, consumer: { chunk in
                        projectData.append(chunk)
                    })
                    container = try? JSONDecoder().decode(ProjectSaveContainer.self, from: projectData)
                }
            }
            
            // Fallback to plain JSON for older project files
            if container == nil {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                container = try decoder.decode(ProjectSaveContainer.self, from: data)
            }
            
            guard let validContainer = container else {
                errorMessage = "Failed to decode project save container."
                return
            }
            
            let tempDir = sessionTempDirectory
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let importedDxfURL = tempDir.appendingPathComponent("imported_combine.dxf")
            
            let activeDxfURL = ensureActiveDXFFileExists()
            
            if let dxfBase64 = validContainer.dxfDataBase64, let dxfData = Data(base64Encoded: dxfBase64) {
                try dxfData.write(to: importedDxfURL)
                
                saveToHistory()
                isProcessing = true
                
                Task {
                    do {
                        await reconcileBufferIfNeeded()
                        
                        _ = try await PythonBridge.shared.run(
                            module: "dxf_ops",
                            op: "append_dxf",
                            args: [
                                "primary": activeDxfURL.path,
                                "secondary": importedDxfURL.path,
                                "output": activeDxfURL.path
                            ]
                        )
                        
                        await MainActor.run {
                            // Merge measurements
                            let existingMeasureIds = Set(self.measurements.map { $0.id })
                            for m in validContainer.measurements {
                                if !existingMeasureIds.contains(m.id) {
                                    self.measurements.append(m)
                                }
                            }
                            
                            // Merge layers
                            var existingLayersByName = Dictionary(uniqueKeysWithValues: self.layers.map { ($0.name, $0) })
                            if let importedLayers = validContainer.savedLayers {
                                for layer in importedLayers {
                                    if existingLayersByName[layer.name] == nil {
                                        self.layers.append(layer)
                                        existingLayersByName[layer.name] = layer
                                    }
                                }
                            }
                            
                            // Merge folders
                            let existingFolderIds = Set(self.layerFolders.map { $0.id })
                            if let importedFolders = validContainer.savedLayerFolders {
                                for f in importedFolders {
                                    if !existingFolderIds.contains(f.id) {
                                        self.layerFolders.append(f)
                                    }
                                }
                            }
                            
                            // Append log entries
                            let existingLogIds = Set(self.logEntries.map { $0.id })
                            for entry in validContainer.logEntries {
                                if !existingLogIds.contains(entry.id) {
                                    self.logEntries.append(entry)
                                }
                            }
                            
                            try? FileManager.default.removeItem(at: importedDxfURL)
                            
                            self.reloadDXF()
                            self.hasUnsavedChanges = true
                            
                            logEntries.append(LogEntry(action: "Combine Project", details: "Combined project successfully from \(url.lastPathComponent)"))
                        }
                    } catch {
                        await MainActor.run {
                            self.errorMessage = "Failed to combine project: \(error.localizedDescription)"
                            self.isProcessing = false
                        }
                    }
                }
            } else {
                errorMessage = "Imported project contains no geometry."
            }
        } catch {
            errorMessage = "Failed to combine project: \(error.localizedDescription)"
        }
    }
    
    func exportWithDialog() {
        let format = self.exportFormat
        let savePanel = NSSavePanel()
        savePanel.title = "Export Drawing"
        savePanel.nameFieldStringValue = "drawing.\(format)"
        savePanel.allowedContentTypes = [UTType(filenameExtension: format)].compactMap { $0 }
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            self.exportFile(to: url, format: format, selectedOnly: self.exportSelectedOnly)
        }
    }
    
    func updateRectangleDimensions(handle: String, width: Double?, height: Double?, filletRadius: Double?) {
        guard let url = currentFilePath else { return }
        
        // Find existing measurements for this rectangle to get the current rectP1, rectP2, and filletRadius
        guard let wMeasure = measurements.first(where: { $0.entityHandle == handle && $0.dimensionType == "width" }),
              let hMeasure = measurements.first(where: { $0.entityHandle == handle && $0.dimensionType == "height" }),
              let p1 = wMeasure.rectP1,
              let p2 = wMeasure.rectP2 else {
            return
        }
        
        saveToHistory()
        isProcessing = true
        
        Task {
            do {
                // Apply background reconcile if needed before writing to backend DXF
                await reconcileBufferIfNeeded()
                
                var newP2 = p2
                let finalWidth = width ?? wMeasure.distanceMm
                let finalHeight = height ?? hMeasure.distanceMm
                let finalFillet = filletRadius ?? wMeasure.filletRadius
                
                // Calculate newP2 based on finalWidth and finalHeight
                let currentW = abs(p2.x - p1.x)
                if currentW > 1e-5 {
                    let sign: CGFloat = p2.x >= p1.x ? 1.0 : -1.0
                    newP2.x = p1.x + sign * CGFloat(finalWidth)
                }
                let currentH = abs(p2.y - p1.y)
                if currentH > 1e-5 {
                    let sign: CGFloat = p2.y >= p1.y ? 1.0 : -1.0
                    newP2.y = p1.y + sign * CGFloat(finalHeight)
                }
                
                var params: [String: Any] = [:]
                params["p1"] = [Double(p1.x), Double(p1.y)]
                params["p2"] = [Double(newP2.x), Double(newP2.y)]
                params["fillet_radius"] = finalFillet
                
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "update_entity",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handle": handle,
                        "type": "rectangle",
                        "params": params
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    
                    // Update in-memory measurements
                    for mIdx in 0..<self.measurements.count {
                        if self.measurements[mIdx].entityHandle == handle {
                            self.measurements[mIdx].rectP1 = p1
                            self.measurements[mIdx].rectP2 = newP2
                            self.measurements[mIdx].filletRadius = finalFillet
                            
                            if self.measurements[mIdx].dimensionType == "width" {
                                let w = abs(newP2.x - p1.x)
                                self.measurements[mIdx].start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                self.measurements[mIdx].end = CGPoint(x: max(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                self.measurements[mIdx].distanceMm = Double(w)
                            } else if self.measurements[mIdx].dimensionType == "height" {
                                let h = abs(newP2.y - p1.y)
                                self.measurements[mIdx].start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                self.measurements[mIdx].end = CGPoint(x: min(p1.x, newP2.x), y: max(p1.y, newP2.y))
                                self.measurements[mIdx].distanceMm = Double(h)
                            }
                        }
                    }
                    
                    // Update selectedMeasurement if it points to this rectangle
                    if let sel = self.selectedMeasurement, sel.entityHandle == handle {
                        self.selectedMeasurement?.rectP1 = p1
                        self.selectedMeasurement?.rectP2 = newP2
                        self.selectedMeasurement?.filletRadius = finalFillet
                        if sel.dimensionType == "width" {
                            self.selectedMeasurement?.start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                            self.selectedMeasurement?.end = CGPoint(x: max(p1.x, newP2.x), y: min(p1.y, newP2.y))
                            self.selectedMeasurement?.distanceMm = finalWidth
                        } else if sel.dimensionType == "height" {
                            self.selectedMeasurement?.start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                            self.selectedMeasurement?.end = CGPoint(x: min(p1.x, newP2.x), y: max(p1.y, newP2.y))
                            self.selectedMeasurement?.distanceMm = finalHeight
                        }
                    }
                    
                    self.reloadDXF()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func loadProjectWithDialog() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [UTType(filenameExtension: "stch")].compactMap { $0 }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            self.loadProject(from: url)
        }
    }


    func importPDF(from url: URL) {
        errorMessage = nil
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let targetURL = tempDir.appendingPathComponent("active.dxf")
        
        isProcessing = true
        Task {
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "import_pdf",
                    args: [
                        "input": url.path,
                        "output": targetURL.path
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = targetURL
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Import PDF", details: "Imported PDF vectors from \(url.lastPathComponent)"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to import PDF: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    func traceRaster(from url: URL, threshold: Int = 127, turdsize: Int = 2) {
        errorMessage = nil
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let targetURL = tempDir.appendingPathComponent("active.dxf")
        
        isProcessing = true
        Task {
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "trace_raster",
                    args: [
                        "input": url.path,
                        "output": targetURL.path,
                        "threshold": threshold,
                        "turdsize": turdsize
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = targetURL
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Trace Raster", details: "Traced raster image \(url.lastPathComponent) (threshold: \(threshold))"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to trace image: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }

    func translateSelected(dx: CGFloat, dy: CGFloat) {
        guard currentFilePath != nil, !selectedHandles.isEmpty else { return }
        saveToHistory()
        
        let dxDouble = Double(dx)
        let dyDouble = Double(dy)
        
        // 1. Optimistic in-memory update for entities
        self.entities = self.entities.map { entity in
            if self.selectedHandles.contains(entity.handle) {
                return entity.translated(dx: dxDouble, dy: dyDouble)
            } else {
                return entity
            }
        }
        
        // 2. Optimistic in-memory update for measurements
        for idx in 0..<self.measurements.count {
            if let handle = self.measurements[idx].entityHandle, self.selectedHandles.contains(handle) {
                var m = self.measurements[idx]
                m.start.x += dx
                m.start.y += dy
                m.end.x += dx
                m.end.y += dy
                if var p1 = m.rectP1 {
                    p1.x += dx
                    p1.y += dy
                    m.rectP1 = p1
                }
                if var p2 = m.rectP2 {
                    p2.x += dx
                    p2.y += dy
                    m.rectP2 = p2
                }
                self.measurements[idx] = m
            }
        }

        // 2b. Keep parametric corner models in sync. Without this the sharp
        //     base stays at the old origin, so corner/fillet handles are "left
        //     behind" and the next parametric edit snaps the shape back (MAS-90).
        for h in self.selectedHandles {
            if var model = self.parametricShapes[h] {
                model.base = model.base.map { [$0[0] + dxDouble, $0[1] + dyDouble] }
                self.parametricShapes[h] = model
            }
        }

        self.hasUnsavedChanges = true
        logEntries.append(LogEntry(action: "Translate Entities", details: "Translated selected entities by dx: \(dx), dy: \(dy)"))
        
        // 3. Asynchronous background buffer write (serialized; never re-enters
        //    reconcileBufferIfNeeded → no self-deadlock).
        let selectedHandlesSnapshot = self.selectedHandles
        let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        enqueueBufferWrite {
            let inputPath = (await MainActor.run { self.currentFilePath?.path }) ?? activeDxfURL.path
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "translate_entities",
                    args: [
                        "input": inputPath,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandlesSnapshot),
                        "dx": dxDouble,
                        "dy": dyDouble
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                }
            } catch {
                print("Background translation failed: \(error)")
            }
        }
    }

    func rotateSelected(angleDegrees: Double, center: [Double]) {
        guard currentFilePath != nil, !selectedHandles.isEmpty else { return }
        saveToHistory()
        
        let angleRad = angleDegrees * .pi / 180.0
        let cosA = cos(angleRad)
        let sinA = sin(angleRad)
        let cx = center[0]
        let cy = center[1]
        
        func rotPt(_ pt: CGPoint) -> CGPoint {
            let dx = pt.x - cx
            let dy = pt.y - cy
            let rx = cx + dx * cosA - dy * sinA
            let ry = cy + dx * sinA + dy * cosA
            return CGPoint(x: rx, y: ry)
        }
        
        // 1. Optimistic in-memory update for entities
        self.entities = self.entities.map { entity in
            if self.selectedHandles.contains(entity.handle) {
                return entity.rotated(angleDegrees: angleDegrees, centerPt: center)
            } else {
                return entity
            }
        }
        
        // 2. Optimistic in-memory update for measurements
        for idx in 0..<self.measurements.count {
            if let handle = self.measurements[idx].entityHandle, self.selectedHandles.contains(handle) {
                var m = self.measurements[idx]
                m.start = rotPt(m.start)
                m.end = rotPt(m.end)
                if let p1 = m.rectP1 {
                    m.rectP1 = rotPt(p1)
                }
                if let p2 = m.rectP2 {
                    m.rectP2 = rotPt(p2)
                }
                self.measurements[idx] = m
            }
        }

        // Keep parametric corner models in sync with the rotation so corner/
        // fillet handles track the shape and edits don't snap back (MAS-90).
        for h in self.selectedHandles {
            if var model = self.parametricShapes[h] {
                model.base = model.base.map { pt in
                    let p = rotPt(CGPoint(x: pt[0], y: pt[1]))
                    return [Double(p.x), Double(p.y)]
                }
                self.parametricShapes[h] = model
            }
        }
        
        self.hasUnsavedChanges = true
        logEntries.append(LogEntry(action: "Rotate Entities", details: "Rotated selected entities by angle: \(angleDegrees) around center: \(center)"))
        
        // 3. Asynchronous background buffer write (serialized; never re-enters
        //    reconcileBufferIfNeeded → no self-deadlock).
        let selectedHandlesSnapshot = self.selectedHandles
        let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        enqueueBufferWrite {
            let inputPath = (await MainActor.run { self.currentFilePath?.path }) ?? activeDxfURL.path
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "rotate_entities",
                    args: [
                        "input": inputPath,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandlesSnapshot),
                        "angle": angleDegrees,
                        "center": center
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                }
            } catch {
                print("Background rotation failed: \(error)")
            }
        }
    }

    /// Flips the selected entities in place about their own bounding-box
    /// center. axis "horizontal" mirrors left/right, "vertical" top/bottom.
    func reflectSelectedEntities(axis: String) {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        isProcessing = true

        let handlesSnapshot = Array(selectedHandles)
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "reflect_entities",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": handlesSnapshot,
                        "axis": axis
                    ]
                )
                await MainActor.run {
                    if let status = res["status"] as? String, status != "ok" {
                        self.errorMessage = (res["message"] as? String) ?? "Reflect failed."
                        self.isProcessing = false
                        return
                    }
                    self.currentFilePath = activeDxfURL
                    self.reloadDXF()
                    self.logEntries.append(LogEntry(action: "Reflect", details: "Reflected selected entities (\(axis))"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    /// Duplicates the current selection, offset slightly, and selects the copies
    /// (right-click → Duplicate, MAS-77). Offset scales with zoom so the copy is
    /// always visibly nudged from the original.
    func duplicateSelectedEntities() {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        let handlesSnapshot = Array(selectedHandles)
        let offset = 5.0
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "duplicate_entities",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": handlesSnapshot,
                        "dx": offset,
                        "dy": offset
                    ]
                )
                await MainActor.run {
                    if let status = res["status"] as? String, status != "ok" {
                        self.errorMessage = (res["message"] as? String) ?? "Duplicate failed."
                        self.isProcessing = false
                        return
                    }
                    let newHandles = (res["data"] as? [String: Any])?["new_handles"] as? [String] ?? []
                    self.currentFilePath = activeDxfURL
                    self.reloadDXF()
                    if !newHandles.isEmpty { self.selectedHandles = Set(newHandles) }
                    self.logEntries.append(LogEntry(action: "Duplicate", details: "Duplicated \(handlesSnapshot.count) entit\(handlesSnapshot.count == 1 ? "y" : "ies")"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    /// Reloads every selected imported file from disk in place (MAS-76). The
    /// fork's geometry is re-read and re-centred on where it currently sits, so
    /// the user's placement is preserved; the 2D↔3D link is untouched.
    func reloadSelectedImportFromDisk() {
        guard let url = currentFilePath else { return }
        // Snapshot the jobs on the main actor: group id, source, old handles, layer.
        let jobs: [(gid: String, source: ImportSource, layer: String)] = Array(
            Set(selectedHandles.compactMap { importGroupId(for: $0) })
        ).compactMap { gid in
            guard let src = importSources[gid] else { return nil }
            let layer = entities.first { src.handles.contains($0.handle) }?.layer ?? "0"
            return (gid, src, layer)
        }
        guard !jobs.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        Task {
            do {
                var allNew: [String] = []
                var updates: [String: [String]] = [:]
                for job in jobs {
                    guard let temp = try await convertToTempDXF(job.source.url) else { continue }
                    let res = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "replace_import",
                        args: [
                            "input": url.path,
                            "output": activeDxfURL.path,
                            "delete_handles": job.source.handles,
                            "secondary": temp.path,
                            "layer": job.layer
                        ]
                    )
                    try? FileManager.default.removeItem(at: temp)
                    if let status = res["status"] as? String, status != "ok" {
                        await MainActor.run {
                            self.errorMessage = (res["message"] as? String) ?? "Reload failed."
                        }
                        continue
                    }
                    let newHandles = (res["data"] as? [String: Any])?["new_handles"] as? [String] ?? []
                    updates[job.gid] = newHandles
                    allNew.append(contentsOf: newHandles)
                }
                await MainActor.run {
                    for (gid, handles) in updates {
                        if var src = self.importSources[gid] { src.handles = handles; self.importSources[gid] = src }
                    }
                    self.currentFilePath = activeDxfURL
                    self.reloadDXF()
                    if !allNew.isEmpty { self.selectedHandles = Set(allNew) }
                    self.isProcessing = false
                    self.logAction("Reload from Disk", details: "Reloaded \(jobs.count) import(s) from disk")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    func deleteSelectedMeasurement() {
        guard let selected = selectedMeasurement else { return }
        saveToHistory()
        measurements.removeAll { $0.id == selected.id }
        selectedMeasurement = nil
        hasUnsavedChanges = true
        logAction("Delete Measurement", details: "Deleted selected measurement line")
    }


    func applyDashedCreases() {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "add_dashed_creases",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "layer": "CREASES"
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Add Creases", details: "Added paper folding crease pattern on selected lines"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applyGlueTabs() {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        
        let height = glueTabHeight
        let type = glueTabType
        let side = glueTabSide
        let startOffset = glueTabStartOffset
        let endOffset = glueTabEndOffset
        
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "add_glue_tabs",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "height": height,
                        "type": type,
                        "side": side,
                        "start_offset": startOffset,
                        "end_offset": endOffset,
                        "layer": "GLUE_TABS"
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Add Glue Tabs", details: "Added \(type) glue tabs on \(side) side, height: \(height)mm, offsets: \(startOffset)/\(endOffset)mm"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applyPatternGrid(columns: Int, rows: Int, colSpacing: Double, rowSpacing: Double) {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "pattern_grid",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "columns": columns,
                        "rows": rows,
                        "col_spacing": colSpacing,
                        "row_spacing": rowSpacing,
                        "layer": "PATTERN"
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Grid Pattern", details: "Patterned grid of \(columns)x\(rows) with spacing X:\(colSpacing) Y:\(rowSpacing)"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    /// Circular pattern (MAS-113): `count` copies of the selection spread over
    /// `angle` degrees about the pivot (picked point, or selection bbox center).
    func applyPatternCircular(count: Int, angle: Double) {
        guard let url = currentFilePath, !selectedHandles.isEmpty, let bbox = selectionBBox else { return }
        let pivot = patternPivotModel ?? CGPoint(x: bbox.midX, y: bbox.midY)
        let handles = Array(selectedHandles)
        saveToHistory()
        isProcessing = true
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops", op: "pattern_circular",
                    args: ["input": url.path, "output": activeDxfURL.path,
                           "handles": handles, "count": count,
                           "cx": Double(pivot.x), "cy": Double(pivot.y),
                           "total_angle": angle])
                await MainActor.run {
                    if let status = res["status"] as? String, status != "ok" {
                        self.errorMessage = (res["message"] as? String) ?? "Circular pattern failed."
                        self.isProcessing = false
                        return
                    }
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    self.logEntries.append(LogEntry(action: "Circular Pattern", details: "×\(count) over \(Int(angle))°"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    func applyPatternPath(pathHandle: String, spacing: Double) {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "pattern_path",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "path_handle": pathHandle,
                        "spacing": spacing,
                        "layer": "PATTERN"
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Path Pattern", details: "Patterned along path \(pathHandle) with spacing \(spacing)mm"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applyAddText(text: String, insert: CGPoint, height: Double,
                      font: String = "", bold: Bool = false, italic: Bool = false,
                      underline: Bool = false, charSpacing: Double = 0.0) {
        saveToHistory()
        let activeDxfURL = ensureActiveDXFFileExists()
        let activeLayerName = self.activeLayer?.isReferenceImageLayer == true ? "0" : (self.activeLayer?.name ?? "TEXT")
        isProcessing = true

        Task {
            do {
                // Flush deferred deletes so text appends to current geometry (MAS-21).
                await reconcileBufferIfNeeded()
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "add_text",
                    args: [
                        "input": activeDxfURL.path,
                        "output": activeDxfURL.path,
                        "text": text,
                        "insert": [Double(insert.x), Double(insert.y)],
                        "height": height,
                        "layer": activeLayerName,
                        "font": font,
                        "bold": bold,
                        "italic": italic,
                        "underline": underline,
                        "char_spacing": charSpacing
                    ]
                )
                await MainActor.run {
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Add Text", details: "Placed text: \"\(text)\" at (\(Int(insert.x)), \(Int(insert.y)))"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    // MARK: - In-memory source of truth (MAS-21 / MAS-24)
    //
    // The authoritative working state is the in-memory model (`entities`,
    // `measurements`, `layers`), which `DxfCanvasView` renders directly. The
    // on-disk `active.dxf` is a *derived mirror* used only to hand heavy
    // geometry to the Python engine and to persist on Save/Export. Interactive
    // edits update the in-memory model optimistically — instantly, with no
    // Python round-trip and no loading screen — and queue a lightweight buffer
    // reconcile. Any code path that feeds the buffer to Python or serializes it
    // calls `await reconcileBufferIfNeeded()` first, so the mirror is current.

    /// Handles deleted in memory but not yet flushed to the working buffer.
    @ObservationIgnored private var pendingDeletedHandles: Set<String> = []
    /// The in-flight buffer reconcile, if any, so readers can coalesce/await it.
    @ObservationIgnored private var reconcileTask: Task<Void, Never>? = nil

    /// Rebuilds the layer list from the current in-memory entities, preserving
    /// existing color/visibility. Keeps the Layers panel correct after an
    /// optimistic in-memory edit without a Python round-trip.
    func recomputeLayersFromEntities() {
        let uniqueLayers = Array(Set(entities.map { $0.layer })).sorted()
        
        var computedLayers: [DXFLayer] = []
        // First add existing reference image layers
        for layer in self.layers {
            if layer.isReferenceImageLayer {
                computedLayers.append(layer)
            } else if uniqueLayers.contains(layer.name) {
                computedLayers.append(layer)
            }
        }
        // Then add new layers from uniqueLayers that weren't in computedLayers
        for layerName in uniqueLayers {
            if !computedLayers.contains(where: { $0.name == layerName }) {
                let newL = DXFLayer(
                    id: UUID().uuidString,
                    name: layerName,
                    color: self.colorForLayerName(layerName),
                    visible: true,
                    parentFolderId: nil
                )
                computedLayers.append(newL)
            }
        }
        self.layers = computedLayers
        
        // Back-populate layerId on entities
        for i in 0..<entities.count {
            if entities[i].layerId == nil {
                if let matched = layers.first(where: { $0.name == entities[i].layer }) {
                    entities[i].layerId = matched.id
                }
            }
        }
        
        if activeLayerId == nil || !layers.contains(where: { $0.id == activeLayerId }) {
            activeLayerId = layers.first?.id
        }
    }

    /// Flushes any deferred optimistic deletions into the on-disk working
    /// buffer so the Python engine and Save/Export operate on current geometry.
    /// Cheap no-op when nothing is pending; safe to call from any op that reads
    /// the buffer. `op_delete_entities` is idempotent, so an occasional
    /// double-flush is harmless.
    func reconcileBufferIfNeeded() async {
        // Wait for any in-flight optimistic op write (rotate/translate/text) and
        // the delete-reconcile so readers see a fully up-to-date buffer.
        if let write = await MainActor.run(body: { self.bufferWriteTask }) {
            await write.value
        }
        if let running = await MainActor.run(body: { self.reconcileTask }) {
            await running.value
        }
        let snapshot: (handles: [String], input: URL)? = await MainActor.run {
            guard !self.pendingDeletedHandles.isEmpty,
                  let input = self.currentFilePath,
                  FileManager.default.fileExists(atPath: input.path) else {
                self.pendingDeletedHandles.removeAll()
                return nil
            }
            return (Array(self.pendingDeletedHandles), input)
        }
        guard let snap = snapshot else { return }
        let activeURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        let task = Task<Void, Never> {
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "delete_entities",
                    args: ["input": snap.input.path, "output": activeURL.path, "handles": snap.handles]
                )
                await MainActor.run {
                    self.currentFilePath = activeURL
                    self.pendingDeletedHandles.subtract(snap.handles)
                }
            } catch {
                // The in-memory truth already reflects the deletion; a later
                // reader retries. Don't surface an error for a background sync.
            }
        }
        await MainActor.run { self.reconcileTask = task }
        await task.value
        await MainActor.run { self.reconcileTask = nil }
    }

    /// In-flight serialized background buffer write for optimistic ops
    /// (rotate/translate/text). Separate from `reconcileTask` so these writes
    /// never await themselves — the old self-assignment deadlocked text export.
    @ObservationIgnored private var bufferWriteTask: Task<Void, Never>? = nil

    /// Serializes an optimistic op's background buffer write after any in-flight
    /// delete-reconcile and prior writes. The in-memory model is already updated;
    /// this only brings the on-disk mirror in line. It must NOT call
    /// `reconcileBufferIfNeeded()` (which awaits this task → deadlock). The work
    /// closure should read `currentFilePath` fresh as its Python input.
    @discardableResult
    private func enqueueBufferWrite(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let prevReconcile = reconcileTask
        let prevWrite = bufferWriteTask
        let task = Task<Void, Never> {
            await prevReconcile?.value
            await prevWrite?.value
            await work()
        }
        bufferWriteTask = task
        return task
    }

    /// Reconciles the working buffer, then saves the project. Use this from
    /// user-facing Save entry points so a just-performed optimistic edit (e.g.
    /// a delete) is reflected in the persisted `.stch` even in a fast sequence.
    func reconcileThenSave(to url: URL) {
        Task {
            await reconcileBufferIfNeeded()
            await MainActor.run { self.saveProject(to: url) }
        }
    }

    /// Deletes the selected entities. A delete that empties the canvas is a
    /// fully valid state — the in-memory model simply becomes empty and the
    /// canvas renders blank, never an error (MAS-8 / MAS-49). The update is
    /// optimistic (instant, zero Python round-trips, no loading screen); the
    /// working buffer is reconciled in the background for later heavy ops/Save.
    func deleteSelectedEntities() {
        guard !selectedHandles.isEmpty else { return }
        saveToHistory()
        let removed = selectedHandles

        entities.removeAll { removed.contains($0.handle) }
        previewEntities.removeAll { removed.contains($0.handle) }
        measurements.removeAll { m in
            if let h = m.entityHandle { return removed.contains(h) }
            return false
        }
        if let sel = selectedMeasurement, let h = sel.entityHandle, removed.contains(h) {
            selectedMeasurement = nil
        }
        selectedHandles.removeAll()
        recomputeLayersFromEntities()
        hasUnsavedChanges = true
        logAction("Delete Entities", details: "Deleted \(removed.count) selected entit\(removed.count == 1 ? "y" : "ies")")

        pendingDeletedHandles.formUnion(removed)
        Task { await reconcileBufferIfNeeded() }
    }

    func deleteEntity(handle: String) {
        saveToHistory()
        entities.removeAll { $0.handle == handle }
        previewEntities.removeAll { $0.handle == handle }
        measurements.removeAll { $0.entityHandle == handle }
        selectedHandles.remove(handle)
        recomputeLayersFromEntities()
        hasUnsavedChanges = true
        pendingDeletedHandles.insert(handle)
        Task { await reconcileBufferIfNeeded() }
    }

    private func colorForLayerName(_ name: String) -> Color {
        switch name.uppercased() {
        case "ORIGINAL": return Color(red: 228/255, green: 228/255, blue: 234/255)
        case "OFFSET": return Color.status_warn
        case "SEWING_HOLES": return Color.status_ok
        case "CUTLINE": return Color.accent
        case "DRAWN_SHAPES": return Color.cyan
        case "UNFOLDED_3D": return Color(red: 0.9, green: 0.1, blue: 0.9)
        case "PROJECTED_SKETCH": return Color(red: 1.0, green: 0.8, blue: 0.0)
        case "CREASES": return Color.blue
        case "GLUE_TABS": return Color.orange
        case "PATTERN": return Color.yellow
        case "TEXT": return Color.green
        default:
            let hash = abs(name.hashValue)
            let r = Double((hash & 0xFF0000) >> 16) / 255.0
            let g = Double((hash & 0x00FF00) >> 8) / 255.0
            let b = Double(hash & 0x0000FF) / 255.0
            return Color(red: r, green: g, blue: b)
        }
    }

    // MARK: - Layer & Folder Management
    
    struct LayerHierarchicalItem: Identifiable {
        let id: String
        let name: String
        let isFolder: Bool
        let depth: Int
        let visible: Bool
        let color: Color?
        var parentFolderId: String?
        var isReferenceImageLayer: Bool = false
        var locked: Bool = false
    }
    
    func getFlattenedLayerItems() -> [LayerHierarchicalItem] {
        var items: [LayerHierarchicalItem] = []
        
        func traverse(folderId: String?, depth: Int) {
            // Add folders at this level
            let levelFolders = layerFolders.filter { $0.parentFolderId == folderId }
            for folder in levelFolders {
                let isExpanded = expandedFolderIds.contains(folder.id)
                items.append(LayerHierarchicalItem(
                    id: folder.id,
                    name: folder.name,
                    isFolder: true,
                    depth: depth,
                    visible: true,
                    color: nil,
                    parentFolderId: folder.parentFolderId,
                    isReferenceImageLayer: false,
                    locked: false
                ))
                
                if isExpanded {
                    traverse(folderId: folder.id, depth: depth + 1)
                }
            }
            
            // Add layers at this level
            let levelLayers = layers.filter { $0.parentFolderId == folderId }
            for layer in levelLayers {
                items.append(LayerHierarchicalItem(
                    id: layer.id,
                    name: layer.name,
                    isFolder: false,
                    depth: depth,
                    visible: layer.visible,
                    color: layer.color,
                    parentFolderId: layer.parentFolderId,
                    isReferenceImageLayer: layer.isReferenceImageLayer,
                    locked: layer.locked
                ))
            }
        }
        
        traverse(folderId: nil, depth: 0)
        return items
    }
    
    var selectionCenterModel: CGPoint? {
        if selectedHandles.isEmpty { return nil }
        var pts: [CGPoint] = []
        for h in selectedHandles {
            if let ent = entities.first(where: { $0.handle == h }) {
                if let s = ent.start, s.count >= 2 { pts.append(CGPoint(x: s[0], y: s[1])) }
                if let e = ent.end, e.count >= 2 { pts.append(CGPoint(x: e[0], y: e[1])) }
                if let c = ent.center, c.count >= 2 { pts.append(CGPoint(x: c[0], y: c[1])) }
                if let vertices = ent.vertices {
                    for v in vertices {
                        if v.count >= 2 { pts.append(CGPoint(x: v[0], y: v[1])) }
                    }
                }
            }
        }
        if pts.isEmpty { return nil }
        let sumX = pts.map { $0.x }.reduce(0, +)
        let sumY = pts.map { $0.y }.reduce(0, +)
        return CGPoint(x: sumX / CGFloat(pts.count), y: sumY / CGFloat(pts.count))
    }
    
    /// Keeps the Layers panel highlight in lock-step with the canvas selection
    /// (MAS-70): the active layers are exactly those owning the selected geometry,
    /// and an empty selection clears the highlight. `activeLayerId` (the draw
    /// target for new sketches) is preserved so creating geometry still has a home.
    func updateActiveLayersFromSelection() {
        guard !selectedHandles.isEmpty else {
            // Nothing selected → no layers highlighted, but keep a draw target.
            activeLayerIds = []
            return
        }
        var selectedLayerIds = Set<String>()
        for entity in entities {
            if selectedHandles.contains(entity.handle) {
                if let matchedLayer = layers.first(where: { $0.id == entity.layerId || $0.name == entity.layer }) {
                    selectedLayerIds.insert(matchedLayer.id)
                }
            }
        }
        self.activeLayerIds = selectedLayerIds
        if let first = selectedLayerIds.first {
            self.activeLayerId = first
        }
    }

    /// Clicking a layer selects every geometry entity it contains (MAS-105), the
    /// inverse of `updateActiveLayersFromSelection`. A reference-image layer has no
    /// selectable viewport geometry, so it only becomes the active layer (which
    /// opens its transform panel via the `activeLayerId` didSet — MAS-137). Setting
    /// `selectedHandles` drives the active-layer highlight; `activeLayerId` is then
    /// pinned explicitly so an empty layer still activates as the draw target.
    func selectAllInLayer(layerId: String) {
        guard let layer = layers.first(where: { $0.id == layerId }) else { return }
        if layer.isReferenceImageLayer {
            activeLayerId = layerId
            return
        }
        let handles = entities
            .filter { $0.layerId == layerId || $0.layer == layer.name }
            .map { $0.handle }
        selectedHandles = Set(handles)
        activeLayerId = layerId
        // Make the selection actionable — a creation tool would ignore it.
        if !handles.isEmpty && currentTool != .select {
            currentTool = .select
        }
    }

    func addLayer(name: String, color: Color? = nil) {
        let sanitizedName = sanitizeLayerName(name)
        let actualColor = color ?? self.colorForLayerName(sanitizedName)
        let newLayer = DXFLayer(
            id: UUID().uuidString,
            name: sanitizedName,
            color: actualColor,
            visible: true,
            parentFolderId: nil
        )
        self.layers.append(newLayer)
        self.activeLayerId = newLayer.id
        self.hasUnsavedChanges = true
        self.logAction("ADD LAYER", details: "Added layer \(sanitizedName)")
    }
    
    func addFolder(name: String) {
        let newFolder = DXFLayerFolder(id: UUID().uuidString, name: name, parentFolderId: nil)
        self.layerFolders.append(newFolder)
        self.hasUnsavedChanges = true
        self.expandedFolderIds.insert(newFolder.id) // Auto expand new folders
        self.logAction("ADD FOLDER", details: "Added folder \(name)")
    }
    
    func deleteLayer(id: String) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        let layerName = layers[idx].name
        
        saveToHistory()
        
        // Find entities in this layer
        let toRemove = entities.filter { $0.layerId == id || ($0.layerId == nil && $0.layer == layerName) }
        let removedHandles = Set(toRemove.map { $0.handle })
        
        entities.removeAll { removedHandles.contains($0.handle) }
        previewEntities.removeAll { removedHandles.contains($0.handle) }
        measurements.removeAll { m in
            if let h = m.entityHandle { return removedHandles.contains(h) }
            return false
        }
        if let sel = selectedMeasurement, let h = sel.entityHandle, removedHandles.contains(h) {
            selectedMeasurement = nil
        }
        selectedHandles.subtract(removedHandles)
        
        layers.remove(at: idx)
        if activeLayerId == id {
            activeLayerId = layers.first?.id
        }
        
        pendingDeletedHandles.formUnion(removedHandles)
        hasUnsavedChanges = true
        logAction("DELETE LAYER", details: "Deleted layer \(layerName) and \(removedHandles.count) associated entities")
        
        Task { await reconcileBufferIfNeeded() }
    }
    
    func deleteFolder(id: String) {
        guard let idx = layerFolders.firstIndex(where: { $0.id == id }) else { return }
        let folderName = layerFolders[idx].name
        
        saveToHistory()
        layerFolders.remove(at: idx)
        
        // Flatten children (move nested layers and subfolders to root level)
        for i in 0..<layers.count {
            if layers[i].parentFolderId == id {
                layers[i].parentFolderId = nil
            }
        }
        for i in 0..<layerFolders.count {
            if layerFolders[i].parentFolderId == id {
                layerFolders[i].parentFolderId = nil
            }
        }
        expandedFolderIds.remove(id)
        
        hasUnsavedChanges = true
        logAction("DELETE FOLDER", details: "Deleted folder \(folderName)")
    }
    
    func renameLayer(id: String, newName: String) {
        let sanitizedName = sanitizeLayerName(newName)
        guard !sanitizedName.isEmpty else { return }
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        let oldName = layers[idx].name
        layers[idx].name = sanitizedName
        
        saveToHistory()
        
        entities = entities.map { ent in
            if ent.layerId == id || (ent.layerId == nil && ent.layer == oldName) {
                var newEnt = ent
                newEnt.layer = sanitizedName
                newEnt.layerId = id
                return newEnt
            }
            return ent
        }
        
        let handles = entities.filter { $0.layerId == id }.map { $0.handle }
        if !handles.isEmpty {
            let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
            enqueueBufferWrite {
                let inputPath = (await MainActor.run { self.currentFilePath?.path }) ?? activeDxfURL.path
                do {
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "set_layer",
                        args: [
                            "input": inputPath,
                            "output": activeDxfURL.path,
                            "handles": handles,
                            "layer": sanitizedName
                        ]
                    )
                } catch {
                    print("Background layer rename failed: \(error)")
                }
            }
        }
        
        hasUnsavedChanges = true
        logAction("RENAME LAYER", details: "Renamed layer \(oldName) to \(sanitizedName)")
    }
    
    func renameFolder(id: String, newName: String) {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let idx = layerFolders.firstIndex(where: { $0.id == id }) else { return }
        let oldName = layerFolders[idx].name
        layerFolders[idx].name = newName
        hasUnsavedChanges = true
        logAction("RENAME FOLDER", details: "Renamed folder \(oldName) to \(newName)")
    }
    
    func colorLayer(id: String, newColorHex: String) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].colorHex = newColorHex
        hasUnsavedChanges = true
    }
    
    func moveLayer(id: String, toFolderId: String?) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].parentFolderId = toFolderId
        hasUnsavedChanges = true
    }
    
    func moveFolder(id: String, toFolderId: String?) {
        guard id != toFolderId else { return }
        guard let idx = layerFolders.firstIndex(where: { $0.id == id }) else { return }
        
        var currentParent = toFolderId
        while let parentId = currentParent {
            if parentId == id {
                return // Cycle detected
            }
            currentParent = layerFolders.first(where: { $0.id == parentId })?.parentFolderId
        }
        
        layerFolders[idx].parentFolderId = toFolderId
        hasUnsavedChanges = true
    }
    
    func moveUp(id: String, isFolder: Bool) {
        if isFolder {
            guard let idx = layerFolders.firstIndex(where: { $0.id == id }), idx > 0 else { return }
            layerFolders.swapAt(idx, idx - 1)
        } else {
            guard let idx = layers.firstIndex(where: { $0.id == id }), idx > 0 else { return }
            layers.swapAt(idx, idx - 1)
        }
        hasUnsavedChanges = true
    }
    
    func moveDown(id: String, isFolder: Bool) {
        if isFolder {
            guard let idx = layerFolders.firstIndex(where: { $0.id == id }), idx < layerFolders.count - 1 else { return }
            layerFolders.swapAt(idx, idx + 1)
        } else {
            guard let idx = layers.firstIndex(where: { $0.id == id }), idx < layers.count - 1 else { return }
            layers.swapAt(idx, idx + 1)
        }
        hasUnsavedChanges = true
    }

    func reorderLayerOrFolder(sourceId: String, targetId: String) {
        guard sourceId != targetId else { return }
        
        let sourceIsFolder = layerFolders.contains(where: { $0.id == sourceId })
        let targetIsFolder = layerFolders.contains(where: { $0.id == targetId })
        
        if sourceIsFolder {
            if targetIsFolder {
                var currentParent: String? = targetId
                while let pId = currentParent {
                    if pId == sourceId { return }
                    currentParent = layerFolders.first(where: { $0.id == pId })?.parentFolderId
                }
            }
            
            guard let sourceIdx = layerFolders.firstIndex(where: { $0.id == sourceId }) else { return }
            let sourceFolder = layerFolders.remove(at: sourceIdx)
            
            if targetIsFolder {
                var updatedFolder = sourceFolder
                updatedFolder.parentFolderId = targetId
                layerFolders.insert(updatedFolder, at: 0)
            } else {
                guard let targetLayer = layers.first(where: { $0.id == targetId }) else {
                    layerFolders.insert(sourceFolder, at: sourceIdx)
                    return
                }
                var updatedFolder = sourceFolder
                updatedFolder.parentFolderId = targetLayer.parentFolderId
                layerFolders.insert(updatedFolder, at: 0)
            }
        } else {
            guard let sourceIdx = layers.firstIndex(where: { $0.id == sourceId }) else { return }
            let sourceLayer = layers.remove(at: sourceIdx)
            
            if targetIsFolder {
                var updatedLayer = sourceLayer
                updatedLayer.parentFolderId = targetId
                layers.insert(updatedLayer, at: 0)
            } else {
                guard let targetIdx = layers.firstIndex(where: { $0.id == targetId }) else {
                    layers.insert(sourceLayer, at: sourceIdx)
                    return
                }
                var updatedLayer = sourceLayer
                updatedLayer.parentFolderId = layers[targetIdx].parentFolderId
                layers.insert(updatedLayer, at: targetIdx)
            }
        }
        hasUnsavedChanges = true
        logAction("REORDER LAYER/FOLDER", details: "Moved item \(sourceId) to target \(targetId)")
    }

    // MARK: - Text Inline Editing
    func generateNextHandle() -> String {
        var maxHandleVal = 0
        for ent in entities {
            if let val = Int(ent.handle, radix: 16) {
                if val > maxHandleVal {
                    maxHandleVal = val
                }
            }
        }
        let nextVal = max(maxHandleVal + 1, 0xF0000)
        return String(nextVal, radix: 16).uppercased()
    }

    func startEditingNewText(insert: CGPoint, height: Double, width: Double = 0.0) {
        self.isEditingText = true
        self.editingTextHandle = nil
        self.editingTextString = ""
        self.editingTextInsert = insert
        self.editingTextHeight = height
        self.editingTextWidth = width
        // Seed the live styling from the Text tool's current defaults so the new
        // text inherits the font/B/I/U the user picked in the panel (MAS-134/135).
        self.editingTextFont = textToolFont
        self.editingTextBold = textToolBold
        self.editingTextItalic = textToolItalic
        self.editingTextUnderline = textToolUnderline
        self.editingTextCharSpacing = textToolCharSpacing
    }

    func startEditingText(entity: DXFEntity) {
        self.isEditingText = true
        self.editingTextHandle = entity.handle
        self.editingTextString = entity.text ?? ""
        if let start = entity.start {
            self.editingTextInsert = CGPoint(x: start[0], y: start[1])
        }
        self.editingTextHeight = entity.height ?? 5.0
        self.editingTextFont = entity.fontName ?? ""
        self.editingTextBold = entity.bold ?? false
        self.editingTextItalic = entity.italic ?? false
        self.editingTextUnderline = entity.underline ?? false
        self.editingTextCharSpacing = entity.charSpacing ?? 0.0
        // Estimate the box width from the longest line (cf. AGENTS Rule 3).
        let longest = (entity.text ?? "").components(separatedBy: "\n").map { $0.count }.max() ?? 0
        self.editingTextWidth = Double(longest) * (entity.height ?? 5.0) * 0.6
    }
    
    func cancelTextEditing() {
        self.isEditingText = false
        self.editingTextHandle = nil
        self.editingTextString = ""
    }
    
    func commitTextEditing() {
        guard isEditingText else { return }
        let text = editingTextString.isEmpty ? "Label" : editingTextString
        let insert = editingTextInsert
        let height = editingTextHeight
        let handle = editingTextHandle
        // Snapshot the live styling so the entity and Python args stay in sync.
        let font = editingTextFont
        let bold = editingTextBold
        let italic = editingTextItalic
        let underline = editingTextUnderline
        let charSpacing = editingTextCharSpacing
        // Only attach style fields when they differ from plain defaults, so plain
        // text stays clean (and Python skips writing XDATA for it).
        func styled(_ ent: DXFEntity) -> DXFEntity {
            var e = ent
            e.fontName = font.isEmpty ? nil : font
            e.bold = bold ? true : nil
            e.italic = italic ? true : nil
            e.underline = underline ? true : nil
            e.charSpacing = charSpacing != 0 ? charSpacing : nil
            return e
        }
        let styleArgs: [String: Any] = [
            "font": font,
            "bold": bold,
            "italic": italic,
            "underline": underline,
            "char_spacing": charSpacing
        ]

        self.isEditingText = false
        self.editingTextHandle = nil
        self.editingTextString = ""

        if let h = handle {
            // Edit existing text in-memory
            saveToHistory()
            self.entities = self.entities.map { entity in
                if entity.handle == h {
                    return styled(DXFEntity(
                        handle: entity.handle,
                        type: entity.type,
                        layer: entity.layer,
                        color: entity.color,
                        start: [Double(insert.x), Double(insert.y)],
                        end: nil,
                        center: nil,
                        radius: nil,
                        start_angle: nil,
                        end_angle: nil,
                        vertices: nil,
                        closed: nil,
                        text: text,
                        height: height,
                        rotation: entity.rotation,
                        layerId: entity.layerId
                    ))
                } else {
                    return entity
                }
            }
            self.hasUnsavedChanges = true

            // Background buffer write (serialized; no self-deadlock).
            let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
            enqueueBufferWrite {
                let inputPath = (await MainActor.run { self.currentFilePath?.path }) ?? activeDxfURL.path
                do {
                    var args: [String: Any] = [
                        "input": inputPath,
                        "output": activeDxfURL.path,
                        "handle": h,
                        "text": text,
                        "height": height
                    ]
                    args.merge(styleArgs) { _, new in new }
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "update_text",
                        args: args
                    )
                    await MainActor.run {
                        self.currentFilePath = activeDxfURL
                    }
                } catch {
                    print("Background text update failed: \(error)")
                }
            }
        } else {
            // Create new text in-memory
            saveToHistory()
            let tempHandle = "TEMP_" + UUID().uuidString
            let activeLayerName = self.activeLayer?.isReferenceImageLayer == true ? "0" : (self.activeLayer?.name ?? "TEXT")
            let activeLayerIdVal = self.activeLayer?.isReferenceImageLayer == true ? nil : self.activeLayerId
            let newEntity = styled(DXFEntity(
                handle: tempHandle,
                type: "TEXT",
                layer: activeLayerName,
                color: 7,
                start: [Double(insert.x), Double(insert.y)],
                end: nil,
                center: nil,
                radius: nil,
                start_angle: nil,
                end_angle: nil,
                vertices: nil,
                closed: nil,
                text: text,
                height: height,
                layerId: activeLayerIdVal
            ))
            self.entities.append(newEntity)
            self.recomputeLayersFromEntities()
            self.hasUnsavedChanges = true

            // Background buffer write (serialized; no self-deadlock).
            let activeDxfURL = ensureActiveDXFFileExists()
            enqueueBufferWrite {
                do {
                    var args: [String: Any] = [
                        "input": activeDxfURL.path,
                        "output": activeDxfURL.path,
                        "text": text,
                        "insert": [Double(insert.x), Double(insert.y)],
                        "height": height,
                        "layer": activeLayerName
                    ]
                    args.merge(styleArgs) { _, new in new }
                    let res = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "add_text",
                        args: args
                    )
                    if let data = res["data"] as? [String: Any],
                       let realHandle = data["handle"] as? String {
                        await MainActor.run {
                            // Update the temporary handle in-memory
                            self.entities = self.entities.map { entity in
                                if entity.handle == tempHandle {
                                    var e = entity
                                    return DXFEntity(
                                        handle: realHandle,
                                        type: entity.type,
                                        layer: entity.layer,
                                        color: entity.color,
                                        start: entity.start,
                                        end: entity.end,
                                        center: entity.center,
                                        radius: entity.radius,
                                        start_angle: entity.start_angle,
                                        end_angle: entity.end_angle,
                                        vertices: entity.vertices,
                                        closed: entity.closed,
                                        text: entity.text,
                                        height: entity.height,
                                        rotation: e.rotation,
                                        layerId: e.layerId
                                    ).withTextStyleCopied(from: e)
                                } else {
                                    return entity
                                }
                            }
                            if self.selectedHandles.contains(tempHandle) {
                                self.selectedHandles.remove(tempHandle)
                                self.selectedHandles.insert(realHandle)
                            }
                            for idx in 0..<self.measurements.count {
                                if self.measurements[idx].entityHandle == tempHandle {
                                    self.measurements[idx].entityHandle = realHandle
                                }
                            }
                        }
                    }
                } catch {
                    print("Background text add failed: \(error)")
                }
            }
        }
    }

    /// The single selected TEXT entity, or nil — drives the Select-tool text
    /// properties panel (MAS-135).
    var singleSelectedTextEntity: DXFEntity? {
        guard selectedHandles.count == 1, let h = selectedHandles.first else { return nil }
        return entities.first(where: { $0.handle == h && $0.type.uppercased() == "TEXT" })
    }

    /// Updates one or more style/content attributes of an existing TEXT entity in
    /// place (MAS-134/135), updating the in-memory model optimistically and
    /// syncing the on-disk mirror's XDATA via `update_text`. Any nil argument is
    /// left unchanged. `clearFont` explicitly resets to the system default.
    func updateTextEntity(handle: String,
                          text: String? = nil,
                          height: Double? = nil,
                          font: String? = nil,
                          bold: Bool? = nil,
                          italic: Bool? = nil,
                          underline: Bool? = nil,
                          charSpacing: Double? = nil) {
        guard let idx = entities.firstIndex(where: { $0.handle == handle }),
              entities[idx].type.uppercased() == "TEXT" else { return }
        saveToHistory()
        var ent = entities[idx]
        let newText = text ?? ent.text
        let newHeight = height ?? ent.height
        let newFont = font ?? ent.fontName
        let newBold = bold ?? ent.bold ?? false
        let newItalic = italic ?? ent.italic ?? false
        let newUnderline = underline ?? ent.underline ?? false
        let newSpacing = charSpacing ?? ent.charSpacing ?? 0.0
        let rebuilt = DXFEntity(
            handle: ent.handle, type: ent.type, layer: ent.layer, color: ent.color,
            start: ent.start, end: nil, center: nil, radius: nil,
            start_angle: nil, end_angle: nil, vertices: nil, closed: nil,
            text: newText, height: newHeight, rotation: ent.rotation, layerId: ent.layerId
        )
        ent = rebuilt
        ent.fontName = (newFont?.isEmpty ?? true) ? nil : newFont
        ent.bold = newBold ? true : nil
        ent.italic = newItalic ? true : nil
        ent.underline = newUnderline ? true : nil
        ent.charSpacing = newSpacing != 0 ? newSpacing : nil
        entities[idx] = ent
        hasUnsavedChanges = true

        let styleArgs: [String: Any] = [
            "text": newText ?? "",
            "height": newHeight ?? 5.0,
            "font": newFont ?? "",
            "bold": newBold,
            "italic": newItalic,
            "underline": newUnderline,
            "char_spacing": newSpacing
        ]
        let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        enqueueBufferWrite {
            let inputPath = (await MainActor.run { self.currentFilePath?.path }) ?? activeDxfURL.path
            do {
                var args: [String: Any] = ["input": inputPath, "output": activeDxfURL.path, "handle": handle]
                args.merge(styleArgs) { _, new in new }
                _ = try await PythonBridge.shared.run(module: "dxf_ops", op: "update_text", args: args)
                await MainActor.run { self.currentFilePath = activeDxfURL }
            } catch {
                print("Background text style update failed: \(error)")
            }
        }
    }
}
