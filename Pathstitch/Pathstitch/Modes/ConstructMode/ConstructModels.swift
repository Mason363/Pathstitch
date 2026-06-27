import Foundation

/// Construct mode = Pathstitch's assembly workspace. Flat panels (from the live
/// 2D sketch) are triangulated into a bar-and-hinge mesh and folded / stitched
/// into the 3D object by an XPBD solver in the viewport. These are the small,
/// persistable descriptors the Swift/SwiftUI side owns; the heavy mesh + solver
/// state live in `construct_ops.py` and `constructViewport.html` respectively.

/// Tools available in construct mode (its own set, not the 2D `TwoDTool`).
enum ConstructTool: String, CaseIterable, Identifiable {
    case select     // orbit + pick panels/folds
    case move       // move / rotate / scale a panel with a 3D gizmo (pose only)
    case fold       // click a fold edge, then set its angle
    case crease     // click two points on a panel to add a new fold line in 3D
    case ground     // click a panel to pin it as the ground
    case stitch     // click chain A then chain B to sew them together
    case glue       // click two panels to glue (weld) their meeting edges

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "Select"
        case .move:   return "Move"
        case .fold:   return "Fold"
        case .crease: return "Crease"
        case .ground: return "Ground"
        case .stitch: return "Stitch"
        case .glue:   return "Glue"
        }
    }

    /// SF Symbol for the tool rail.
    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .move:   return "move.3d"
        case .fold:   return "arrow.uturn.up"
        case .crease: return "scribble.variable"
        case .ground: return "square.grid.3x3.fill.square"
        case .stitch: return "point.topleft.down.to.point.bottomright.curvepath"
        case .glue:   return "link"
        }
    }

    /// Tools shipped so far.
    static var available: [ConstructTool] { [.select, .move, .fold, .crease, .ground, .stitch, .glue] }
}

/// A fold line the user drew in 3D (two points in a panel's 2D space), re-fed to
/// the triangulator so it becomes a real hinge. Persisted in `ConstructAssembly`.
struct ConstructUserFold: Codable, Hashable {
    var panelId: Int
    var x0: Double; var y0: Double
    var x1: Double; var y1: Double
}

/// One controllable fold: every hinge tagged with `foldId` on panel `panelId`
/// shares this target dihedral angle. Built from the construct model; the angle
/// is what the user drives (slider / gizmo) and what persists.
struct FoldSpec: Codable, Identifiable, Hashable {
    var panelId: Int
    var foldId: Int
    var angleDeg: Double = 0
    /// 0 = knife-sharp crease … 1 = max rounded radius. Real leather rarely folds
    /// dead-sharp; this softens the crease over a true radius (no stretch).
    var roundness: Double = 0

    var id: String { "\(panelId)-\(foldId)" }
}

/// One sewing hole embedded in a panel's triangulation: its 2D position plus the
/// containing triangle and barycentric weights, so the hole rides the mesh as the
/// panel folds (its 3D position is a barycentric blend of the triangle's folded
/// vertices). Produced by `construct_ops._build_hole_chains`.
struct ConstructHole: Codable, Hashable {
    var x: Double
    var y: Double
    var tri: Int
    var bary: [Double]
}

/// An ordered run of sewing holes along one seam, on one panel — "holes stored as
/// holes," auto-detected from the 2D `SEWING_HOLES` layer rather than left as
/// anonymous circles. The user stitches one chain to another (`StitchSeam`).
struct HoleChain: Codable, Identifiable, Hashable {
    var id: Int
    var panelId: Int
    var closed: Bool = false
    var pitch: Double = 0
    var holes: [ConstructHole] = []
}

/// How a seam resolves when the two chains have different perimeters.
enum StitchMode: String, Codable, CaseIterable, Identifiable {
    case ease       // default: keep both hole counts, gather the longer onto the shorter
    case deform     // rescale the longer seam onto the shorter for a clean 1:1 (alters that panel)
    case oneToOne   // manual 1:1 (counts assumed to match)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ease:     return "Ease / Gather"
        case .deform:   return "Deform to Fit"
        case .oneToOne: return "1 : 1"
        }
    }
    var blurb: String {
        switch self {
        case .ease:     return "Keep every hole; gather the longer seam onto the shorter (lossless)."
        case .deform:   return "Stretch the longer seam's spacing to meet the shorter 1:1 (alters that panel)."
        case .oneToOne: return "Pair holes one-to-one in order (best when counts already match)."
        }
    }
}

/// A stitched seam: chain B is pulled onto chain A (rigid Kabsch alignment), then
/// the matched hole pairs are coupled so the seam sews shut. `pairs`/`lenA`/`lenB`/
/// `mismatch`/`reversed` come from `construct_ops.match_chains`; the FLAGSHIP.
struct StitchSeam: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var chainA: Int
    var chainB: Int
    var mode: StitchMode = .ease
    var pairs: [[Int]] = []     // [aHoleIndex, bHoleIndex] correspondence
    var lenA: Double = 0
    var lenB: Double = 0
    var mismatch: Double = 0    // 0…1 perimeter mismatch (>0.12 surfaces a warning)
    var reversed: Bool = false  // B was wound the other way and auto-flipped
    // Fusion-Loft alignment pins: user-locked [aHoleIndex, bHoleIndex] pairs the
    // matcher must honor; runs between pins are filled proportionally. `flip` forces
    // chain B reversed. Optional so older `.stch` seams still decode.
    var anchors: [[Int]]? = nil
    var flip: Bool? = nil
    // Live fit, reported by the viewport after seating (recomputed each pose).
    var holesA: Int = 0
    var holesB: Int = 0
    var maxGapMm: Double = 0    // worst hole-to-hole gap after the seam is seated

    /// True when the seams differ enough in length to warrant a heads-up.
    var hasWarning: Bool { verdict == .mismatch }

    /// Where this seam lands against the fit tolerances. Defaults here are sane
    /// for hobbyists; Phase 3 makes the thresholds user-settable.
    enum Verdict { case match, ease, mismatch }
    var verdict: Verdict {
        let countDelta = abs(holesA - holesB)
        if mismatch >= 0.12 || maxGapMm > 4 || (countDelta > 0 && (holesA == 0 || holesB == 0)) {
            return .mismatch
        }
        if countDelta == 0 && mismatch < 0.04 && maxGapMm <= 1.5 { return .match }
        return .ease
    }
}

/// PBR material + thickness for the Posing & Mockup phase (Phase 4). Stored now
/// so the `.stch` schema is stable; unused until materials land.
struct MaterialRef: Codable, Hashable {
    var source: String = "polyhaven"  // "polyhaven" | "bundled" | "custom"
    var id: String = ""               // PolyHaven slug or bundled name
    var thicknessMm: Double = 2.0
    var colorHex: String = "8A5A2B"   // leather tint
    // Mockup finish + custom leather texture (optional → older files default).
    var finish: String? = nil         // "matte" | "satin" | "glossy"
    var leatherTextureURL: String? = nil  // custom albedo data URL (visual only)
    var leatherTiling: Double? = nil  // repeats per panel for the custom texture
}

/// Everything needed to reopen an assembly exactly as posed. Optional in the
/// `.stch` container, so older projects (and 2D-only ones) load untouched.
struct ConstructAssembly: Codable {
    var groundPanel: Int = 0
    var folds: [FoldSpec] = []
    var material: MaterialRef? = nil
    /// Flattened solved vertex positions per panel (panel-major), so a saved
    /// pose reopens posed instead of flat. Filled on save (Phase 1: optional).
    var poseSnapshot: [Double]? = nil
    var targetLen: Double = 0
    /// Fold stiffness (0 soft … 1 crisp). Optional → older files default to crisp.
    var stiffness: Double? = nil
    /// Stitched seams (the user's "which chains, how to resolve mismatch" choices).
    /// Optional → older `.stch` files load untouched.
    var seams: [StitchSeam]? = nil
    /// Hole-chain snapshot ("holes stored as holes"). Chains normally re-derive
    /// from the live sketch on rebuild; this is the metadata fallback.
    var holeChains: [HoleChain]? = nil
    /// Fold lines the user added directly in 3D.
    var userFolds: [ConstructUserFold]? = nil
    /// Glue (weld) joints between panels — for glue-tab construction.
    var glues: [GlueJoint]? = nil
    /// Artwork decals: panelId (as string) → image data URL. Visual-only.
    var decals: [String: String]? = nil
    /// Per-panel artwork framing: panelId (as string) → [offX, offY, scale,
    /// rotDeg, mirror(0/1)]. Optional → older files just centre the art.
    var decalFrames: [String: [Double]]? = nil
    /// DXF handles of the only areas to assemble (selective assembly). Empty/nil =
    /// assemble every enclosed area.
    var includeHandles: [String]? = nil
    /// Per-engulfed-area treatment: inner DXF handle → "stamp"|"patch"|"cutout"|
    /// "independent". Optional → older files have no overlaps resolved.
    var areaTreatments: [String: String]? = nil
    /// Per-panel base region ("which side stays flat"): panelId (as string) → [x,y].
    var baseRegions: [String: [Double]]? = nil
    /// Per-panel pose override (move/rotate/scale): DXF handle → [tx,ty,tz, qx,qy,
    /// qz,qw, scale]. Pose only — never edits the 2D sketch.
    var panelXf: [String: [Double]]? = nil
    /// Mockup lighting: the studio lights + ambient + render mode. Optional → older
    /// files open with the default lighting.
    var lights: [ConstructLight]? = nil
    var ambient: Double? = nil
    var renderMode: String? = nil   // "edit" | "mockup"
}

/// A full snapshot of the editable assembly state for the panel's own undo/redo
/// stack (separate from the 2D DXF history). Cheap to copy — all value types.
struct ConstructUndoState {
    var groundPanel: Int
    var folds: [FoldSpec]
    var seams: [StitchSeam]
    var glues: [GlueJoint]
    var userFolds: [ConstructUserFold]
    var materialHex: String
    var thicknessMm: Double
    var decals: [Int: String]
    var decalXforms: [Int: [Double]]
    var includeHandles: Set<String>
    var areaTreatments: [String: String]
    var baseRegions: [Int: [Double]]
    var panelXf: [String: [Double]]
}

/// A glue/weld join seating panel B onto panel A. `mode` picks how they bond —
/// "panel" (closest boundary run, general), "face" (lay the two clicked planes
/// flat together), or "edge" (align the two clicked edges). `aPt`/`bPt` are the
/// clicked 2D points on A and B that select the face/edge for those modes.
struct GlueJoint: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var panelA: Int
    var panelB: Int
    var mode: String = "panel"
    var aPt: [Double]? = nil
    var bPt: [Double]? = nil
    // Which visible side of each panel the user clicked (±1, relative to the
    // region's winding normal). 0 = unknown → seats on the winding side (legacy).
    var aSide: Double = 0
    var bSide: Double = 0

    init(panelA: Int, panelB: Int, mode: String = "panel", aPt: [Double]? = nil, bPt: [Double]? = nil,
         aSide: Double = 0, bSide: Double = 0) {
        self.panelA = panelA; self.panelB = panelB; self.mode = mode; self.aPt = aPt; self.bPt = bPt
        self.aSide = aSide; self.bSide = bSide
    }
    // Tolerant decode so older .stch glues (no mode/aPt/bPt/side) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        panelA = try c.decode(Int.self, forKey: .panelA)
        panelB = try c.decode(Int.self, forKey: .panelB)
        mode = (try? c.decode(String.self, forKey: .mode)) ?? "panel"
        aPt = try? c.decode([Double].self, forKey: .aPt)
        bPt = try? c.decode([Double].self, forKey: .bPt)
        aSide = (try? c.decode(Double.self, forKey: .aSide)) ?? 0
        bSide = (try? c.decode(Double.self, forKey: .bSide)) ?? 0
    }
}

/// One studio light for the Mockup render (Illustrator-style 3D lighting): a colour
/// + intensity, aimed by `rotation` (azimuth, 0…360°) and `height` (elevation,
/// 0…90°), with `softness` driving the shadow blur. The first visible light throws
/// the contact shadow. Visual-only — persisted with the assembly's mockup settings.
struct ConstructLight: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var colorHex: String = "FFFFFF"
    var intensity: Double = 2.2     // ~0…5 (slider shows 0…100%)
    var rotation: Double = 145      // azimuth degrees
    var height: Double = 45         // elevation degrees (0 = grazing … 90 = overhead)
    var softness: Double = 0.4      // 0 = crisp shadow … 1 = very soft

    init(id: UUID = UUID(), colorHex: String = "FFFFFF", intensity: Double = 2.2,
         rotation: Double = 145, height: Double = 45, softness: Double = 0.4, on: Bool = true) {
        self.id = id; self.colorHex = colorHex; self.intensity = intensity
        self.rotation = rotation; self.height = height; self.softness = softness; self.on = on
    }
    var on: Bool = true
}

/// The named lighting setups shown as thumbnails atop the lighting panel (mirrors
/// Illustrator's Standard / Diffuse / Top-Left / Right presets).
enum ConstructLightPreset: String, CaseIterable, Identifiable {
    case standard, diffuse, topLeft, right
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Standard"
        case .diffuse:  return "Diffuse"
        case .topLeft:  return "Top Left"
        case .right:    return "Right"
        }
    }
    var ambient: Double {
        switch self {
        case .standard: return 0.26
        case .diffuse:  return 0.55
        case .topLeft:  return 0.22
        case .right:    return 0.24
        }
    }
    var lights: [ConstructLight] {
        switch self {
        case .standard:
            return [ConstructLight(intensity: 2.2, rotation: 135, height: 50, softness: 0.4),
                    ConstructLight(colorHex: "DCE6FF", intensity: 0.7, rotation: 300, height: 28, softness: 0.85)]
        case .diffuse:
            return [ConstructLight(intensity: 1.1, rotation: 145, height: 62, softness: 1.0)]
        case .topLeft:
            return [ConstructLight(intensity: 2.5, rotation: 315, height: 55, softness: 0.4)]
        case .right:
            return [ConstructLight(intensity: 2.5, rotation: 90, height: 40, softness: 0.45)]
        }
    }
}
