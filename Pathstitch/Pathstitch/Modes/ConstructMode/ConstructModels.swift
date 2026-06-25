import Foundation

/// Construct mode = Pathstitch's assembly workspace. Flat panels (from the live
/// 2D sketch) are triangulated into a bar-and-hinge mesh and folded / stitched
/// into the 3D object by an XPBD solver in the viewport. These are the small,
/// persistable descriptors the Swift/SwiftUI side owns; the heavy mesh + solver
/// state live in `construct_ops.py` and `constructViewport.html` respectively.

/// Tools available in construct mode (its own set, not the 2D `TwoDTool`).
enum ConstructTool: String, CaseIterable, Identifiable {
    case select     // orbit + pick panels/folds
    case fold       // click a fold edge, then set its angle
    case crease     // click two points on a panel to add a new fold line in 3D
    case ground     // click a panel to pin it as the ground
    case stitch     // click chain A then chain B to sew them together
    case glue       // click two panels to glue (weld) their meeting edges

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "Select"
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
        case .fold:   return "arrow.uturn.up"
        case .crease: return "scribble.variable"
        case .ground: return "square.grid.3x3.fill.square"
        case .stitch: return "point.topleft.down.to.point.bottomright.curvepath"
        case .glue:   return "link"
        }
    }

    /// Tools shipped so far.
    static var available: [ConstructTool] { [.select, .fold, .crease, .ground, .stitch, .glue] }
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

    /// True when the seams differ enough in length to warrant a heads-up.
    var hasWarning: Bool { mismatch >= 0.12 }
}

/// PBR material + thickness for the Posing & Mockup phase (Phase 4). Stored now
/// so the `.stch` schema is stable; unused until materials land.
struct MaterialRef: Codable, Hashable {
    var source: String = "polyhaven"  // "polyhaven" | "bundled" | "custom"
    var id: String = ""               // PolyHaven slug or bundled name
    var thicknessMm: Double = 2.0
    var colorHex: String = "8A5A2B"   // leather tint
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
}

/// A glue/weld join: panel B is seated onto panel A where their edges meet and
/// held rigidly coincident (no thread). For glue-tab designs.
struct GlueJoint: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var panelA: Int
    var panelB: Int
}
