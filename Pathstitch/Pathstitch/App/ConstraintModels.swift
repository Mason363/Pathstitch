import Foundation

/// A point-level operand for a sketch constraint: an entity handle plus the
/// named point on it. Roles: "start"/"end" (LINE, ARC), "center" (CIRCLE, ARC).
struct PointRef: Codable, Equatable, Hashable {
    var handle: String
    var role: String
}

/// One geometric constraint record. This exact shape travels Swift ⇄ Python
/// and is persisted in `.stch`. `branch` is the tangency/signed-distance side,
/// captured by the solver on first solve and stored opaquely so re-solves are
/// deterministic.
struct SketchConstraint: Codable, Equatable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var kind: String
    var points: [PointRef] = []
    var entities: [String] = []
    var value: Double? = nil
    var branch: Int? = nil
    /// Optional formula for `value` (parameter model, Phase 3): evaluated
    /// against the DimensionEngine table (e.g. "strap_width/2 + 5"), so a
    /// parameter edit re-drives every constraint that references it. `value`
    /// always holds the last evaluated number — the solver only sees numbers.
    var expression: String? = nil

    /// Every handle this constraint references (for pruning + highlighting).
    var referencedHandles: Set<String> {
        Set(points.map { $0.handle }).union(entities)
    }

    /// True when the expression is a real formula (not just a number literal).
    var hasFormula: Bool {
        guard let e = expression else { return false }
        return Double(e.trimmingCharacters(in: .whitespaces)) == nil
    }

    /// Wire/JSON dictionary for the Python solver. `expression` rides along
    /// (the solver ignores it) so the enriched records the solve returns keep
    /// it — the response replaces `sketchConstraints` wholesale.
    var asDictionary: [String: Any] {
        var d: [String: Any] = ["id": id, "kind": kind]
        if !points.isEmpty { d["points"] = points.map { ["handle": $0.handle, "role": $0.role] } }
        if !entities.isEmpty { d["entities"] = entities }
        if let v = value { d["value"] = v }
        if let b = branch { d["branch"] = b }
        if let e = expression { d["expression"] = e }
        return d
    }
}

/// Solve-state feedback from the constraint solver (see sketch_constraints.py).
struct SolveDiagnostics: Codable, Equatable {
    var converged: Bool
    var dof: Int
    var nParams: Int
    var rank: Int
    var fullyConstrained: [String]
    var conflictingConstraints: [String]
    var redundantCount: Int
    var residualMax: Double

    enum CodingKeys: String, CodingKey {
        case converged, dof, rank
        case nParams = "n_params"
        case fullyConstrained = "fully_constrained"
        case conflictingConstraints = "conflicting_constraints"
        case redundantCount = "redundant_count"
        case residualMax = "residual_max"
    }
}

/// The constraint catalog: display metadata plus the operand signature that
/// drives the canvas picking state machine and the inspector.
enum ConstraintKind: String, CaseIterable, Identifiable {
    case coincident, horizontal, vertical, parallel, perpendicular
    case tangent, equal, distance, angle, ground

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coincident: return "Coincident"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .parallel: return "Parallel"
        case .perpendicular: return "Perpendicular"
        case .tangent: return "Tangent"
        case .equal: return "Equal"
        case .distance: return "Distance"
        case .angle: return "Angle"
        case .ground: return "Ground"
        }
    }

    var icon: String {
        switch self {
        case .coincident: return "smallcircle.filled.circle"
        case .horizontal: return "minus"
        case .vertical: return "poweron"
        case .parallel: return "equal"
        case .perpendicular: return "perspective"
        case .tangent: return "circle.and.line.horizontal"
        case .equal: return "equal.circle"
        case .distance: return "arrow.left.and.right"
        case .angle: return "angle"
        case .ground: return "pin.fill"
        }
    }

    /// How many picks (points or entities) complete this constraint.
    var pickCount: Int {
        switch self {
        case .horizontal, .vertical, .ground: return 1
        default: return 2
        }
    }

    /// Whether the picks are point-level (endpoint/center) or whole entities.
    /// `distance` and `ground` accept both — see `DxfCanvasView`'s picker.
    var picksPoints: Bool {
        switch self {
        case .coincident, .distance, .ground: return true
        default: return false
        }
    }

    var needsValue: Bool { self == .distance || self == .angle }

    var valueUnit: String { self == .angle ? "°" : "mm" }

    var defaultValue: Double { self == .angle ? 90.0 : 10.0 }

    /// One-line guidance shown while picking.
    var pickHint: String {
        switch self {
        case .coincident: return "Click two points (endpoints or centers)"
        case .horizontal: return "Click a line"
        case .vertical: return "Click a line"
        case .parallel: return "Click two lines"
        case .perpendicular: return "Click two lines"
        case .tangent: return "Click a line and a circle/arc, or two circles"
        case .equal: return "Click two lines or two circles/arcs"
        case .distance: return "Click two points, or a point and a line"
        case .angle: return "Click two lines"
        case .ground: return "Click a point or an entity to pin it"
        }
    }
}

/// Entity types the solver can constrain. Polylines/splines are deferred —
/// the picker refuses them with an "Explode to lines" hint.
enum SketchSolvable {
    static let types: Set<String> = ["LINE", "CIRCLE", "ARC"]
    static func isSolvable(_ entity: DXFEntity) -> Bool { types.contains(entity.type) }
}

/// Derived geometry that stays linked (Phase 7): a live offset. The derived
/// entities are regenerated from the current source geometry whenever a
/// source-touching edit commits, so a kerf compensation or seam allowance
/// follows the pattern instead of going stale. Persisted in .stch and
/// snapshotted in history.
struct OffsetLink: Codable, Equatable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    /// The source handles offset together as one group (they merge/miter).
    var sources: [String]
    /// The current derived entity handles (replaced wholesale on each regen).
    var derived: [String]
    var distance: Double
    var side: String            // "outer" | "inner" | "left" | "right" | "both"
    var layer: String = "OFFSET"
    var construction: Bool = false

    var asDictionary: [String: Any] {
        ["id": id, "sources": sources, "derived": derived, "distance": distance,
         "side": side, "layer": layer, "construction": construction]
    }
}
