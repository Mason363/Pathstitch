"""Manufacturing-output ops (assembly_workflow.md Phase 3).

Operates on the 2D sketch via ezdxf + shapely — the same geometry the cut files
come from — and adds the three pieces that turn a pattern into a production plan:

  - op_bom            : bill of materials + costing (leather area, thread, hardware)
  - op_validate_dfm   : leather-specific design-for-manufacture checks
  - op_nest           : hide-aware nesting (grain-aligned, defect-avoiding)

These are deliberately a separate module from `dxf_ops` so the manufacturing
layer stays small and independently testable.
"""
import math
from typing import Any, Dict, List, Optional, Tuple

import ezdxf
from ezdxf.path import make_path
from shapely.geometry import Polygon, Point

Pt = Tuple[float, float]

# Layers that are NOT cut leather outlines.
_HOLE_LAYERS = {"SEWING_HOLES", "HOLES", "STITCH", "STITCHES"}
_HARDWARE_LAYERS = {"HARDWARE"}
_SKIP_LAYERS = {"CONSTRUCTION", "GUIDES", "DISTORTION", "DIM", "DIMENSIONS",
                "FOLD", "FOLDS", "CREASE", "CREASES", "FOLD_LINES",
                "EDGE_TURN", "BINDING", "TEMPLATE"}


def _layer(ent) -> str:
    return (ent.dxf.layer or "").upper()


def _entity_center(ent) -> Optional[Pt]:
    et = ent.dxftype()
    if et in ("CIRCLE", "ELLIPSE"):
        return (float(ent.dxf.center.x), float(ent.dxf.center.y))
    if et == "POINT":
        return (float(ent.dxf.location.x), float(ent.dxf.location.y))
    if et == "LINE":
        return ((float(ent.dxf.start.x) + float(ent.dxf.end.x)) / 2.0,
                (float(ent.dxf.start.y) + float(ent.dxf.end.y)) / 2.0)
    if et in ("LWPOLYLINE", "POLYLINE"):
        try:
            pts = [(p.x, p.y) for p in make_path(ent).flattening(distance=0.3)]
        except Exception:
            return None
        if not pts:
            return None
        return (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))
    return None


def _panel_polys(msp) -> List[Tuple[str, Polygon]]:
    """Closed cut outlines as (handle, polygon) — skips holes, hardware, guides, folds."""
    out: List[Tuple[str, Polygon]] = []
    for ent in msp:
        lay = _layer(ent)
        if lay in _HOLE_LAYERS or lay in _HARDWARE_LAYERS or lay in _SKIP_LAYERS:
            continue
        et = ent.dxftype()
        if et not in ("LWPOLYLINE", "POLYLINE", "SPLINE", "ELLIPSE", "CIRCLE"):
            continue
        closed = (et in ("CIRCLE", "ELLIPSE")
                  or bool(getattr(ent, "closed", False) or getattr(ent, "is_closed", False)))
        if not closed:
            continue
        try:
            pts = [(p.x, p.y) for p in make_path(ent).flattening(distance=0.2)]
        except Exception:
            continue
        if len(pts) < 3:
            continue
        pg = Polygon(pts)
        if not pg.is_valid:
            pg = pg.buffer(0)
        if (not pg.is_empty) and pg.area > 1e-6 and pg.geom_type == "Polygon":
            out.append((str(ent.dxf.handle), pg))
    return out


def _hole_centers(msp) -> List[Pt]:
    out: List[Pt] = []
    for ent in msp:
        if _layer(ent) in _HOLE_LAYERS:
            c = _entity_center(ent)
            if c is not None:
                out.append(c)
    return out


def _median_nn(pts: List[Pt]) -> float:
    if len(pts) < 2:
        return 0.0
    nn = []
    for i, p in enumerate(pts):
        best = float("inf")
        for j, q in enumerate(pts):
            if i == j:
                continue
            d = math.hypot(p[0] - q[0], p[1] - q[1])
            if d < best:
                best = d
        if best < float("inf"):
            nn.append(best)
    nn.sort()
    return nn[len(nn) // 2] if nn else 0.0


# ---------------------------------------------------------------------------
# BOM + costing
# ---------------------------------------------------------------------------

def op_bom(args: Dict[str, Any]) -> Dict[str, Any]:
    """Bill of materials + costing for the current sketch.

    args: input, thread_waste (×, default 1.4), cost_per_dm2, cost_per_part.
    Returns leather area (mm²/dm²/sq ft), cut length, sewing-hole count, an
    estimated thread length (holes × pitch × waste × 2 for a saddle stitch),
    hardware-cut count, and an estimated material cost.
    """
    path = args.get("input")
    if not path:
        return {"status": "error", "message": "Input path required."}
    waste = float(args.get("thread_waste", 1.4) or 1.4)
    cost_per_dm2 = float(args.get("cost_per_dm2", 0.0) or 0.0)
    cost_per_part = float(args.get("cost_per_part", 0.0) or 0.0)
    try:
        msp = ezdxf.readfile(path).modelspace()
    except Exception as e:
        return {"status": "error", "message": f"DXF read failed: {e}"}

    panels = _panel_polys(msp)
    area_mm2 = sum(pg.area for _, pg in panels)
    cut_len = sum(pg.exterior.length for _, pg in panels)
    centers = _hole_centers(msp)
    hole_count = len(centers)
    pitch = _median_nn(centers)
    thread_len = hole_count * pitch * waste * 2.0
    hw_count = sum(1 for e in msp if _layer(e) in _HARDWARE_LAYERS)
    area_dm2 = area_mm2 / 10000.0
    cost = area_dm2 * cost_per_dm2 + hw_count * cost_per_part
    return {"status": "ok", "data": {
        "panelCount": len(panels),
        "areaMm2": area_mm2,
        "areaDm2": area_dm2,
        "areaSqFt": area_mm2 / 92903.04,
        "cutLengthMm": cut_len,
        "holeCount": hole_count,
        "pitchMm": pitch,
        "threadLengthMm": thread_len,
        "hardwareCount": hw_count,
        "estimatedCost": cost,
    }}


# ---------------------------------------------------------------------------
# DFM validation (leather-specific rules)
# ---------------------------------------------------------------------------

def op_validate_dfm(args: Dict[str, Any]) -> Dict[str, Any]:
    """Runs leather design-for-manufacture checks over the sketch.

    args: input, min_hole_edge (mm, default 3.0), stock_w, stock_h (mm; 0 = skip).
    Returns a list of human-readable warnings + counts. Soft checks — they advise,
    they don't block. Mirrors the rules in assembly_workflow.md §11.
    """
    path = args.get("input")
    if not path:
        return {"status": "error", "message": "Input path required."}
    min_edge = float(args.get("min_hole_edge", 3.0) or 0.0)
    stock_w = float(args.get("stock_w", 0.0) or 0.0)
    stock_h = float(args.get("stock_h", 0.0) or 0.0)
    try:
        msp = ezdxf.readfile(path).modelspace()
    except Exception as e:
        return {"status": "error", "message": f"DXF read failed: {e}"}

    panels = _panel_polys(msp)
    centers = _hole_centers(msp)
    warnings: List[str] = []

    # Hole-to-edge distance: a hole too close to its panel boundary tears out.
    too_close = 0
    if min_edge > 0:
        for (hx, hy) in centers:
            p = Point(hx, hy)
            for _, pg in panels:
                if pg.contains(p):
                    if pg.exterior.distance(p) < min_edge - 1e-6:
                        too_close += 1
                    break
    if too_close:
        warnings.append(f"{too_close} stitch hole(s) closer than {min_edge:.1f} mm "
                        f"to the edge — may tear out.")

    # Panel fits the available stock (try both orientations).
    if stock_w > 0 and stock_h > 0:
        oversize = 0
        for _, pg in panels:
            minx, miny, maxx, maxy = pg.bounds
            w, h = maxx - minx, maxy - miny
            fits = (w <= stock_w + 1e-6 and h <= stock_h + 1e-6) or \
                   (h <= stock_w + 1e-6 and w <= stock_h + 1e-6)
            if not fits:
                oversize += 1
        if oversize:
            warnings.append(f"{oversize} panel(s) don't fit the "
                            f"{stock_w:.0f}×{stock_h:.0f} mm stock.")

    return {"status": "ok", "data": {
        "warnings": warnings,
        "panelCount": len(panels),
        "holeCount": len(centers),
        "ok": len(warnings) == 0,
    }}


# ---------------------------------------------------------------------------
# Hide-aware nesting (grain-aligned shelf packing, defect avoidance)
# ---------------------------------------------------------------------------

def _bbox(pg: Polygon) -> Tuple[float, float, float, float]:
    return pg.bounds  # (minx, miny, maxx, maxy)


def _rect_hits_defect(x0: float, y0: float, w: float, h: float,
                      defects: List[Dict[str, float]], gap: float) -> bool:
    for d in defects:
        dx, dy, r = float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("r", 0)) + gap
        # closest point on the rect to the defect center
        cx = min(max(dx, x0), x0 + w)
        cy = min(max(dy, y0), y0 + h)
        if math.hypot(dx - cx, dy - cy) < r:
            return True
    return False


def op_nest(args: Dict[str, Any]) -> Dict[str, Any]:
    """Nests panels onto a hide: grain-aligned (no rotation) shelf packing that
    routes around marked defects.

    args: input, hide_w, hide_h (mm), gap (mm, default 4), margin (mm, default 5),
          defects = [{x,y,r}, ...] (mm), output (optional), apply (bool).
    When `apply` is true, each placed panel — together with the sewing holes and
    hardware cuts inside it — is translated to its nested position and written to
    `output`. Returns the placements, placed/unplaced counts, and the yield.
    """
    path = args.get("input")
    if not path:
        return {"status": "error", "message": "Input path required."}
    hide_w = float(args.get("hide_w", 0.0) or 0.0)
    hide_h = float(args.get("hide_h", 0.0) or 0.0)
    if hide_w <= 0 or hide_h <= 0:
        return {"status": "error", "message": "hide_w and hide_h must be positive."}
    gap = float(args.get("gap", 4.0) or 0.0)
    margin = float(args.get("margin", 5.0) or 0.0)
    defects = args.get("defects") or []
    apply = bool(args.get("apply", False))
    try:
        doc = ezdxf.readfile(path)
    except Exception as e:
        return {"status": "error", "message": f"DXF read failed: {e}"}
    msp = doc.modelspace()
    panels = _panel_polys(msp)
    if not panels:
        return {"status": "error", "message": "No panels to nest."}

    # Sort tallest-first (classic shelf packing) for a tighter pack.
    items = []
    for handle, pg in panels:
        minx, miny, maxx, maxy = _bbox(pg)
        items.append((handle, pg, minx, miny, maxx - minx, maxy - miny))
    items.sort(key=lambda it: it[5], reverse=True)

    placements: List[Dict[str, Any]] = []
    unplaced: List[str] = []
    cursor_x, cursor_y, shelf_h = margin, margin, 0.0
    used_area = 0.0
    for handle, pg, minx, miny, w, h in items:
        if w > hide_w - 2 * margin or h > hide_h - 2 * margin:
            unplaced.append(handle)
            continue
        placed = False
        # try shelves; advance x, wrap to a new shelf, skip defect-clobbered slots
        attempts = 0
        while not placed and attempts < 10000:
            attempts += 1
            if cursor_x + w > hide_w - margin:                 # wrap to next shelf
                cursor_x = margin
                cursor_y += shelf_h + gap
                shelf_h = 0.0
            if cursor_y + h > hide_h - margin:                 # off the hide
                break
            if _rect_hits_defect(cursor_x, cursor_y, w, h, defects, gap):
                cursor_x += max(w, 5.0) * 0.25 + gap           # nudge past the defect
                continue
            # place here
            placements.append({"handle": handle,
                               "x": cursor_x, "y": cursor_y, "w": w, "h": h,
                               "dx": cursor_x - minx, "dy": cursor_y - miny})
            used_area += w * h
            shelf_h = max(shelf_h, h)
            cursor_x += w + gap
            placed = True
        if not placed:
            unplaced.append(handle)

    # Optionally bake the layout: move each panel together with everything that
    # rides on it — holes, hardware cuts, fold creases, art — so nothing desyncs.
    if apply and placements:
        place_by_handle = {p["handle"]: p for p in placements}
        poly_by_handle = {h: pg for h, pg in panels}
        panel_handles = {h for h, _ in panels}
        moved: set = set()
        for ph, p in place_by_handle.items():
            dx, dy = p["dx"], p["dy"]
            pg = poly_by_handle[ph]
            try:
                msp.doc.entitydb[ph].translate(dx, dy, 0); moved.add(ph)
            except Exception:
                pass
            for ent in msp:
                h = str(ent.dxf.handle)
                if h in panel_handles or h in moved:
                    continue
                c = _entity_center(ent)
                if c and pg.contains(Point(c)):
                    try:
                        ent.translate(dx, dy, 0); moved.add(h)
                    except Exception:
                        pass
        out = args.get("output") or path
        try:
            doc.saveas(out)
        except Exception as e:
            return {"status": "error", "message": f"Write failed: {e}"}

    hide_area = hide_w * hide_h
    return {"status": "ok", "data": {
        "placements": placements,
        "placed": len(placements),
        "unplaced": len(unplaced),
        "unplacedHandles": unplaced,
        "yield": (used_area / hide_area) if hide_area > 0 else 0.0,
        "hideAreaMm2": hide_area,
        "usedAreaMm2": used_area,
    }}


OPERATIONS = {
    "bom": op_bom,
    "validate_dfm": op_validate_dfm,
    "nest": op_nest,
}
