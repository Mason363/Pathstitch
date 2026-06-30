"""
dxf_ops.py

Core geometry and DXF operations module for Pathstitch.
Provides tools to list entities, perform parallel offsets, add sewing holes,
cleanup geometry, and export to SVG.
"""

import sys
import json
import argparse
import os
import math
from typing import Dict, List, Any, Tuple, Optional

import ezdxf
import ezdxf.colors
from ezdxf.math import Matrix44
from ezdxf.path import make_path, Path
from shapely.geometry import LineString, LinearRing, MultiLineString, Polygon, MultiPolygon, Point as ShapelyPoint
from shapely.ops import linemerge, unary_union, polygonize
from shapely.prepared import prep

# --- Text styling persistence (MAS-134 / MAS-135) -------------------------
# DXF TEXT entities only natively carry a value, height, rotation and a style
# reference. To round-trip Pathstitch's rich text styling (font family,
# bold/italic/underline, per-character spacing and true multi-line content)
# through the .dxf mirror — and therefore through saved .stch projects — we
# stash it as XDATA under our own app id. Geometry ops that modify entities in
# place (translate/rotate/etc.) leave XDATA untouched, so styling survives them
# automatically; only add/update text writes it.
PATHSTITCH_APPID = "PATHSTITCH"
# Sentinel for newlines inside XDATA strings (raw newlines break the DXF parser).
_NL_TOKEN = "\x01NL\x01"


def _ensure_pathstitch_appid(doc) -> None:
    if PATHSTITCH_APPID not in doc.appids:
        doc.appids.new(PATHSTITCH_APPID)


def _set_text_xdata(ent, doc, *, font: str, bold: bool, italic: bool,
                    underline: bool, char_spacing: float, text: str) -> None:
    """Writes the full Pathstitch text styling onto a TEXT entity as XDATA.

    Layout (after the implicit 1001 appid marker):
      1000 font-family (may be "")
      1070 bold (0/1)  1070 italic (0/1)  1070 underline (0/1)
      1040 char-spacing (mm)
      1000* text chunks (joined back together; chunked so the per-tag 255-byte
            XDATA string limit can't truncate longer / multi-line content)
    """
    _ensure_pathstitch_appid(doc)
    text = text or ""
    # DXF is a line-based format; a literal newline inside an XDATA string tag
    # corrupts the file on reload, so encode newlines with a sentinel token and
    # decode it back in `_get_text_xdata`.
    encoded = text.replace("\r\n", "\n").replace("\n", _NL_TOKEN)
    # 250 keeps each chunk safely under the 255-byte XDATA string ceiling.
    chunks = [encoded[i:i + 250] for i in range(0, len(encoded), 250)] or [""]
    data = [(1000, font or "")]
    data += [(1070, 1 if bold else 0),
             (1070, 1 if italic else 0),
             (1070, 1 if underline else 0)]
    data += [(1040, float(char_spacing or 0.0))]
    data += [(1000, c) for c in chunks]
    ent.set_xdata(PATHSTITCH_APPID, data)


def _get_text_xdata(ent) -> Dict[str, Any]:
    """Reads back the styling written by `_set_text_xdata`; {} if absent."""
    try:
        tags = ent.get_xdata(PATHSTITCH_APPID)
    except Exception:
        return {}
    strs: List[str] = []
    ints: List[int] = []
    reals: List[float] = []
    for code, val in tags:
        if code == 1000:
            strs.append(val)
        elif code == 1070:
            ints.append(int(val))
        elif code == 1040:
            reals.append(float(val))
    res: Dict[str, Any] = {}
    if strs:
        res["font"] = strs[0]
        if len(strs) > 1:
            res["text"] = "".join(strs[1:]).replace(_NL_TOKEN, "\n")
    if len(ints) >= 3:
        res["bold"] = bool(ints[0])
        res["italic"] = bool(ints[1])
        res["underline"] = bool(ints[2])
    if reals:
        res["char_spacing"] = reals[0]
    return res


def sanitize_layer_name(name: str) -> str:
    """
    Sanitizes a layer name to ensure compatibility with AutoCAD / ezdxf constraints.
    AutoCAD layer names cannot contain the characters: \ / : * ? " < > | ; = , `
    Also strips trailing/leading whitespaces and limits length to 255.
    """
    if not name:
        return "Layer"
    invalid_chars = ['\\', '/', ':', '*', '?', '"', '<', '>', '|', ';', '=', ',', '`']
    for char in invalid_chars:
        name = name.replace(char, '_')
    sanitized = name.strip()[:255]
    return sanitized if sanitized else "Layer"

def aci_to_hex(aci: int) -> str:
    """Converts AutoCAD Color Index (ACI) to hex color string."""
    try:
        rgb = ezdxf.colors.aci2rgb(aci)
        return f"#{rgb[0]:02x}{rgb[1]:02x}{rgb[2]:02x}"
    except Exception:
        return "#ffffff"

def snap_endpoints(geoms: List[LineString], tolerance: float = 0.05) -> List[LineString]:
    """
    Clusters and snaps endpoints of LineStrings that are within a given tolerance.
    Also snaps endpoints to nearby segments of other LineStrings.
    Helps prepare curves for successful line merging.
    """
    if not geoms:
        return []

    # 1. Cluster and snap endpoints to endpoints first
    endpoints = []
    for g in geoms:
        if len(g.coords) >= 2:
            endpoints.append(g.coords[0])
            endpoints.append(g.coords[-1])

    clusters: List[Tuple[float, float]] = []
    for pt in endpoints:
        matched = False
        for cl in clusters:
            dist = math.hypot(pt[0] - cl[0], pt[1] - cl[1])
            if dist < tolerance:
                matched = True
                break
        if not matched:
            clusters.append(pt)

    snapped_geoms = []
    for g in geoms:
        coords = list(g.coords)
        if len(coords) < 2:
            continue
        
        # Snap start point
        start = coords[0]
        for cl in clusters:
            if math.hypot(start[0] - cl[0], start[1] - cl[1]) < tolerance:
                coords[0] = cl
                break
                
        # Snap end point
        end = coords[-1]
        for cl in clusters:
            if math.hypot(end[0] - cl[0], end[1] - cl[1]) < tolerance:
                coords[-1] = cl
                break

        snapped_geoms.append(LineString(coords))

    # 2. Project remaining endpoints onto nearby segments of other geometries
    final_geoms = []
    for i, g in enumerate(snapped_geoms):
        coords = list(g.coords)
        if len(coords) < 2:
            final_geoms.append(g)
            continue
            
        # Check start point
        start_pt = ShapelyPoint(coords[0])
        best_dist = float('inf')
        best_pt = None
        for j, other in enumerate(snapped_geoms):
            if i == j:
                continue
            dist = other.distance(start_pt)
            if 1e-5 < dist < tolerance and dist < best_dist:
                proj_dist = other.project(start_pt)
                closest_pt = other.interpolate(proj_dist)
                actual_dist = math.hypot(coords[0][0] - closest_pt.x, coords[0][1] - closest_pt.y)
                if actual_dist < tolerance:
                    best_dist = dist
                    best_pt = (closest_pt.x, closest_pt.y)
        if best_pt is not None:
            coords[0] = best_pt
            
        # Check end point
        end_pt = ShapelyPoint(coords[-1])
        best_dist = float('inf')
        best_pt = None
        for j, other in enumerate(snapped_geoms):
            if i == j:
                continue
            dist = other.distance(end_pt)
            if 1e-5 < dist < tolerance and dist < best_dist:
                proj_dist = other.project(end_pt)
                closest_pt = other.interpolate(proj_dist)
                actual_dist = math.hypot(coords[-1][0] - closest_pt.x, coords[-1][1] - closest_pt.y)
                if actual_dist < tolerance:
                    best_dist = dist
                    best_pt = (closest_pt.x, closest_pt.y)
        if best_pt is not None:
            coords[-1] = best_pt
            
        final_geoms.append(LineString(coords))

    return final_geoms

def find_corners(coords: List[Tuple[float, float]], angle_threshold_deg: float = 15.0) -> List[Tuple[float, float]]:
    """
    Identifies sharp corner vertices in a sequence of coordinates.
    Angles are calculated between consecutive segments.
    """
    corners = []
    coords = list(coords)
    n = len(coords)
    if n < 3:
        return corners

    threshold_rad = math.radians(angle_threshold_deg)

    # Check loop state
    is_loop = coords[0] == coords[-1] or math.hypot(coords[0][0] - coords[-1][0], coords[0][1] - coords[-1][1]) < 1e-5

    # A closed ring usually repeats its first point as the last. Drop that
    # duplicate so the modular wrap below doesn't create a zero-length segment at
    # the seam — which would otherwise hide the corner sitting on the seam vertex.
    if is_loop and n >= 4 and math.hypot(coords[0][0] - coords[-1][0],
                                         coords[0][1] - coords[-1][1]) < 1e-9:
        coords = coords[:-1]
        n = len(coords)
        if n < 3:
            return corners

    start_idx = 0 if is_loop else 1
    end_idx = n if is_loop else n - 1

    for i in range(start_idx, end_idx):
        prev_pt = coords[(i - 1) % n]
        curr_pt = coords[i % n]
        next_pt = coords[(i + 1) % n]

        ux, uy = curr_pt[0] - prev_pt[0], curr_pt[1] - prev_pt[1]
        wx, wy = next_pt[0] - curr_pt[0], next_pt[1] - curr_pt[1]

        u_len = math.hypot(ux, uy)
        w_len = math.hypot(wx, wy)

        if u_len < 1e-5 or w_len < 1e-5:
            continue

        # Normalized dot product
        dot = (ux * wx + uy * wy) / (u_len * w_len)
        dot = max(-1.0, min(1.0, dot))
        angle = math.acos(dot)

        if angle > threshold_rad:
            corners.append(curr_pt)

    return corners

def sample_path(path: LineString, spacing: float, is_closed: bool, shift: float = 0.0) -> List[Tuple[float, float]]:
    """
    Samples points along a LineString at specified spacing.
    - If closed, adjusts spacing to eliminate closure gaps.
    - If open, centers the points along the line and applies shift.
    """
    L = path.length
    if L < 1e-5:
        return []

    points = []
    if is_closed:
        N = max(1, round(L / spacing))
        adjusted_spacing = L / N
        for i in range(N):
            offset = (i * adjusted_spacing + shift) % L
            pt = path.interpolate(offset)
            points.append((pt.x, pt.y))
    else:
        N = int(L // spacing)
        if N == 0:
            pt = path.interpolate((L / 2.0 + shift) % L if L > 0 else 0.0)
            points.append((pt.x, pt.y))
        else:
            rem = L - N * spacing
            start_offset = rem / 2.0 + shift
            for i in range(N + 1):
                offset = start_offset + i * spacing
                if 0.0 <= offset <= L:
                    pt = path.interpolate(offset)
                    points.append((pt.x, pt.y))
    return points

def get_offset_geometry(geom: LineString, distance: float, side: str,
                        join_style: str = "mitre") -> Optional[Any]:
    """Offsets a curve, expanding/shrinking closed shapes and side-offsetting open
    ones. Uses polygon ``buffer`` for closed rings (robust expand/shrink that never
    self-intersects into a "shifted" copy) and ``offset_curve`` for open lines —
    replacing shapely's deprecated, unreliable ``parallel_offset`` (MAS-71).

    Side semantics:
      * ``outer`` / ``inner`` — always expand / shrink (winding independent).
      * ``left`` / ``right``  — offset toward the first edge's left / right normal,
        which is what the on-canvas drag handle uses. Mapped to expand/shrink via
        the ring winding so dragging the handle outward always grows the shape.
    ``join_style`` selects the corner treatment of the offset: ``"mitre"`` keeps
    sharp corners (the default), ``"round"`` fillets them, ``"bevel"`` chamfers.
    Returns a ``LinearRing`` (closed), ``LineString``/``MultiLineString`` (open),
    ``MultiLineString`` (closed result that split), or ``None`` (e.g. shrunk away).
    """
    from shapely.geometry import Polygon, MultiPolygon, MultiLineString as _MLS, LinearRing as _LR

    if abs(distance) < 1e-5:
        return geom

    # mitre_limit only matters for mitre joins; a large limit keeps sharp corners
    # sharp instead of beveling them, while round/bevel ignore it.
    mlimit = 4.0
    dist = abs(distance)
    is_closed = geom.is_closed or isinstance(geom, LinearRing)

    if is_closed:
        try:
            ring = geom if isinstance(geom, LinearRing) else LinearRing(geom.coords)
            poly = Polygon(ring)
            if not poly.is_valid:
                poly = poly.buffer(0)
            if poly.is_empty:
                return None

            if side == "outer":
                d = dist
            elif side == "inner":
                d = -dist
            else:
                # 'left'/'right' are handle-relative; the left normal points
                # inward exactly when the ring is counter-clockwise.
                toward_inside = (side == "left") == ring.is_ccw
                d = -dist if toward_inside else dist

            if join_style == "round" and d < 0:
                # Eroding a polygon keeps its convex corners sharp — a plain round
                # join only rounds reflex corners on the way in. To actually fillet
                # the inner offset's corners we open the shape: erode by 2·dist then
                # dilate back by dist (round), which rounds the convex corners with
                # radius `dist` while keeping the straight runs at the right offset.
                opened = poly.buffer(2.0 * d, join_style="round").buffer(-d, join_style="round")
                result = opened if (opened is not None and not opened.is_empty) \
                    else poly.buffer(d, join_style="round")
            else:
                result = poly.buffer(d, join_style=join_style, mitre_limit=mlimit)
            if result.is_empty:
                return None
            if isinstance(result, MultiPolygon):
                rings = [_LR(p.exterior.coords) for p in result.geoms if not p.is_empty]
                return _MLS(rings) if rings else None
            return _LR(result.exterior.coords)
        except Exception:
            return None
    else:
        try:
            d = dist if side in ("left", "outer") else -dist
            oc = geom.offset_curve(d, join_style=join_style, mitre_limit=mlimit)
            return None if oc.is_empty else oc
        except Exception:
            return None

def op_list_entities(args: Dict[str, Any]) -> Dict[str, Any]:
    """Lists properties and geometry coordinates for entities in the DXF file."""
    input_path = args.get("input")
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()
    entities = []

    for ent in msp:
        if ent.dxftype() not in ("LINE", "ARC", "CIRCLE", "LWPOLYLINE", "SPLINE", "ELLIPSE", "TEXT", "HATCH"):
            continue
            
        data = {
            "handle": ent.dxf.handle,
            "type": ent.dxftype(),
            "layer": ent.dxf.layer,
            "color": ent.dxf.color
        }

        try:
            if ent.dxftype() == "LINE":
                data["start"] = [ent.dxf.start.x, ent.dxf.start.y]
                data["end"] = [ent.dxf.end.x, ent.dxf.end.y]
            elif ent.dxftype() == "CIRCLE":
                data["center"] = [ent.dxf.center.x, ent.dxf.center.y]
                data["radius"] = ent.dxf.radius
            elif ent.dxftype() == "ARC":
                data["center"] = [ent.dxf.center.x, ent.dxf.center.y]
                data["radius"] = ent.dxf.radius
                data["start_angle"] = ent.dxf.start_angle
                data["end_angle"] = ent.dxf.end_angle
            elif ent.dxftype() in ("LWPOLYLINE", "POLYLINE", "SPLINE", "ELLIPSE"):
                path = make_path(ent)
                vertices = list(path.flattening(distance=0.1))
                data["vertices"] = [[p.x, p.y] for p in vertices]
                data["closed"] = ent.closed if hasattr(ent, "closed") else ent.is_closed
            elif ent.dxftype() == "TEXT":
                data["text"] = ent.dxf.text
                data["start"] = [ent.dxf.insert.x, ent.dxf.insert.y]
                data["height"] = ent.dxf.height
                data["rotation"] = float(getattr(ent.dxf, "rotation", 0.0) or 0.0)
                # Horizontal warp factor (MAS-157): native DXF TEXT width factor.
                wf = float(getattr(ent.dxf, "width", 1.0) or 1.0)
                if abs(wf - 1.0) > 1e-6:
                    data["widthFactor"] = wf
                # Rich styling (font/B/I/U/spacing/multiline) lives in XDATA so it
                # survives the .dxf round-trip and .stch saves (MAS-134/135).
                xd = _get_text_xdata(ent)
                if xd:
                    if xd.get("text") is not None:
                        data["text"] = xd["text"]
                    if xd.get("font"):
                        data["fontName"] = xd["font"]
                    if "bold" in xd:
                        data["bold"] = xd["bold"]
                    if "italic" in xd:
                        data["italic"] = xd["italic"]
                    if "underline" in xd:
                        data["underline"] = xd["underline"]
                    if "char_spacing" in xd:
                        data["charSpacing"] = xd["char_spacing"]
            elif ent.dxftype() == "HATCH":
                # Filled region (MAS-146). Surface the largest boundary loop as
                # the entity's outline (for selection/bounds), all loops for
                # hole-aware fill rendering, and a `filled` flag so the canvas
                # paints a solid interior.
                loops = _hatch_boundary_loops(ent)
                if not loops:
                    continue
                def _loop_area(L):
                    a = 0.0
                    for i in range(len(L)):
                        x1, y1 = L[i]; x2, y2 = L[(i + 1) % len(L)]
                        a += x1 * y2 - x2 * y1
                    return abs(a) * 0.5
                outer = max(loops, key=_loop_area)
                data["vertices"] = [[x, y] for (x, y) in outer]
                data["closed"] = True
                data["filled"] = True
                data["fillLoops"] = [[[x, y] for (x, y) in L] for L in loops]
            entities.append(data)
        except Exception as e:
            # Skip invalid entities
            pass

    return {"status": "ok", "data": {"entities": entities}}

def op_offset_lines(args: Dict[str, Any]) -> Dict[str, Any]:
    """Generates offset lines and adds them to the DXF."""
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    distance = float(args.get("distance", 1.0))
    side = args.get("side", "left")
    construction = bool(args.get("construction", False))
    layer = sanitize_layer_name(args.get("layer", "OFFSET"))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    if layer not in doc.layers:
        doc.layers.new(layer, dxfattribs={"color": 3})  # Green by default

    # Construction offsets are emitted as dashed reference geometry (MAS-109).
    base_attribs = {"layer": layer}
    if construction:
        if "DASHED" not in doc.linetypes:
            try:
                doc.linetypes.add("DASHED", pattern="A,.5,-.25")
            except Exception:
                pass
        base_attribs["linetype"] = "DASHED"
        base_attribs["color"] = 8  # gray

    # Find target entities
    targets = []
    if handles:
        for h in handles:
            try:
                targets.append(doc.entitydb[h])
            except KeyError:
                pass
    else:
        targets = [e for e in msp if e.dxftype() in ("LINE", "ARC", "CIRCLE", "LWPOLYLINE", "SPLINE", "ELLIPSE")]

    new_handles = []

    # Standalone CIRCLE optimization or other individual handling if needed
    circles = [ent for ent in targets if ent.dxftype() == "CIRCLE"]
    non_circles = [ent for ent in targets if ent.dxftype() != "CIRCLE"]

    # Handle circles separately
    for ent in circles:
        cx, cy = ent.dxf.center.x, ent.dxf.center.y
        r = ent.dxf.radius
        sides_to_try = ["inner", "outer"] if side == "both" else [side]
        for s in sides_to_try:
            if s in ("left", "outer"):
                r_offset = r + distance
            else:
                r_offset = r - distance
            if r_offset > 0:
                new_ent = msp.add_circle(center=(cx, cy), radius=r_offset, dxfattribs=dict(base_attribs))
                new_handles.append(new_ent.dxf.handle)

    # For non-circles, snap and merge them first to prevent segment gaps/skipping
    geoms = []
    for ent in non_circles:
        try:
            path = make_path(ent)
            vertices = [(p.x, p.y) for p in path.flattening(distance=0.01)]
            if len(vertices) >= 2:
                is_closed = getattr(ent, "closed", False) or getattr(ent, "is_closed", False)
                geoms.append(LinearRing(vertices) if is_closed else LineString(vertices))
        except Exception:
            pass

    if geoms:
        snapped = snap_endpoints(geoms, tolerance=0.05)
        try:
            merged = linemerge(snapped)
        except Exception:
            merged = snapped

        # NOTE: do NOT re-import LineString/LinearRing/MultiLineString here — they
        # are module-level (top of file). A function-local import binds those names
        # as locals for the WHOLE function, which made the LinearRing(...) call in
        # the geom-building loop above raise UnboundLocalError (silently swallowed),
        # so closed-shape offsets produced nothing. (MAS-71)
        if isinstance(merged, (LineString, LinearRing, MultiLineString)):
            if isinstance(merged, MultiLineString):
                merged_list = list(merged.geoms)
            else:
                merged_list = [merged]
        elif isinstance(merged, list):
            merged_list = merged
        else:
            merged_list = []

        def _emit(piece):
            # Add one offset piece as an LWPOLYLINE, honoring closedness (a closed
            # ring is stored with the closed flag, not a duplicate last vertex).
            closed = piece.is_closed or isinstance(piece, LinearRing)
            coords = list(piece.coords)
            if closed and len(coords) > 1 and coords[0] == coords[-1]:
                coords = coords[:-1]
            if len(coords) < 2:
                return
            new_ent = msp.add_lwpolyline(coords, dxfattribs=dict(base_attribs))
            new_ent.closed = closed
            new_handles.append(new_ent.dxf.handle)

        for geom in merged_list:
            sides_to_try = ["inner", "outer"] if side == "both" else [side]
            for s in sides_to_try:
                offset_geom = get_offset_geometry(geom, distance, s)
                if not offset_geom:
                    continue

                if isinstance(offset_geom, MultiLineString):
                    for sub_geom in offset_geom.geoms:
                        _emit(sub_geom)
                elif isinstance(offset_geom, (LineString, LinearRing)):
                    _emit(offset_geom)

    doc.saveas(output_path)
    return {"status": "ok", "data": {"new_entities": new_handles}}


# --- Add Thickness ---------------------------------------------------------
# Converts a zero-width centerline (line / arc / open or closed polyline / spline
# / circle / ellipse) into a closed, manufacturable outline of a given width, by
# buffering the curve symmetrically (±thickness/2). Geometry that already encloses
# area / carries width ("already has thickness") is left untouched.

THICKENED_LAYER = "THICKENED"
THICKENABLE_TYPES = ("LINE", "ARC", "CIRCLE", "LWPOLYLINE", "POLYLINE", "SPLINE", "ELLIPSE")
THICKEN_APPID = "PATHSTITCH"
THICKEN_FLAG = "THICKENED"


def _entity_already_has_thickness(ent) -> bool:
    """True when an entity should be SKIPPED by add-thickness because it already
    has thickness: a filled/solid region, a polyline carrying a DXF width, or the
    output of a previous add-thickness pass (so the op is idempotent). The
    previous-pass check is an XDATA marker, so it survives whatever layer the
    outline lives on (e.g. SVG outlines keep their source layer)."""
    dt = ent.dxftype()
    if dt in ("HATCH", "SOLID", "3DSOLID", "REGION", "3DFACE", "MESH", "BODY"):
        return True
    try:
        if ent.dxf.layer == THICKENED_LAYER:
            return True
    except Exception:
        pass
    try:
        for code, val in ent.get_xdata(THICKEN_APPID):
            if code == 1000 and val == THICKEN_FLAG:
                return True
    except Exception:
        pass
    if dt == "LWPOLYLINE":
        # A const width, or any per-vertex start/end width, means it renders thick.
        try:
            if float(getattr(ent.dxf, "const_width", 0) or 0) > 1e-9:
                return True
        except Exception:
            pass
        try:
            for v in ent.get_points("xyseb"):
                # format xyseb -> (x, y, start_width, end_width, bulge)
                if (len(v) >= 4) and (abs(v[2]) > 1e-9 or abs(v[3]) > 1e-9):
                    return True
        except Exception:
            pass
    return False


def _thicken_entities(msp, doc, entities, thickness: float, layer: Optional[str]):
    """Buffers each thin centerline entity into closed outline LWPOLYLINEs.

    ``layer``: target layer for every outline, or ``None`` to keep each source
    entity's own layer (used by SVG import to preserve the file's layering).
    Returns (new_handles, consumed_entities, skipped_existing). Does NOT delete
    the originals — the caller decides whether to replace them."""
    if layer is not None and layer not in doc.layers:
        doc.layers.new(layer, dxfattribs={"color": 1})
    if THICKEN_APPID not in doc.appids:
        doc.appids.new(THICKEN_APPID)

    r = thickness / 2.0
    new_handles: List[str] = []
    consumed = []
    skipped_existing = 0

    for ent in entities:
        if ent is None or ent.dxftype() not in THICKENABLE_TYPES:
            continue
        if _entity_already_has_thickness(ent):
            skipped_existing += 1
            continue
        try:
            path = make_path(ent)
            verts = [(p.x, p.y) for p in path.flattening(distance=0.05)]
        except Exception:
            continue
        if len(verts) < 2:
            continue
        is_closed = bool(getattr(ent, "closed", False) or getattr(ent, "is_closed", False))
        base = None
        if is_closed:
            try:
                base = LinearRing(verts)
            except Exception:
                base = None
        if base is None:
            try:
                base = LineString(verts)
            except Exception:
                continue

        try:
            buffered = base.buffer(r, cap_style="flat", join_style="round")
        except Exception:
            buffered = None
        if buffered is None or buffered.is_empty:
            continue

        if isinstance(buffered, MultiPolygon):
            polys = list(buffered.geoms)
        elif isinstance(buffered, Polygon):
            polys = [buffered]
        else:
            polys = [g for g in getattr(buffered, "geoms", []) if isinstance(g, Polygon)]

        emitted_any = False
        for poly in polys:
            if not isinstance(poly, Polygon) or poly.is_empty:
                continue
            for ring in [poly.exterior, *list(poly.interiors)]:
                coords = list(ring.coords)
                if len(coords) > 1 and coords[0] == coords[-1]:
                    coords = coords[:-1]
                if len(coords) < 3:
                    continue
                out_layer = layer if layer is not None else ent.dxf.layer
                ne = msp.add_lwpolyline(coords, dxfattribs={"layer": out_layer})
                ne.closed = True
                # Mark as a thickened outline so a later add-thickness pass skips
                # it (idempotent regardless of which layer it ended up on).
                try:
                    ne.set_xdata(THICKEN_APPID, [(1000, THICKEN_FLAG)])
                except Exception:
                    pass
                new_handles.append(ne.dxf.handle)
                emitted_any = True
        if emitted_any:
            consumed.append(ent)

    return new_handles, consumed, skipped_existing


def op_add_thickness(args: Dict[str, Any]) -> Dict[str, Any]:
    """Adds thickness to selected (or all) zero-width lines, turning each into a
    closed outline of the given width. Geometry that already has thickness is
    skipped. The original centerline is replaced by its outline unless
    ``replace`` is false."""
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    thickness = float(args.get("thickness", 3.0))
    layer = sanitize_layer_name(args.get("layer", THICKENED_LAYER))
    replace = bool(args.get("replace", True))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if thickness <= 0:
        return {"status": "error", "message": "Thickness must be a positive value."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    if handles:
        targets = []
        for h in handles:
            try:
                targets.append(doc.entitydb[h])
            except KeyError:
                pass
    else:
        targets = [e for e in msp if e.dxftype() in THICKENABLE_TYPES]

    new_handles, consumed, skipped_existing = _thicken_entities(msp, doc, targets, thickness, layer)

    if replace:
        for ent in consumed:
            try:
                msp.delete_entity(ent)
            except Exception:
                pass

    doc.saveas(output_path)
    return {
        "status": "ok",
        "data": {
            "new_entities": new_handles,
            "thickened_count": len(consumed),
            "skipped_existing": skipped_existing,
        },
    }


def make_rounded_rectangle_points(x1: float, y1: float, x2: float, y2: float, r: float) -> List[Tuple[float, float]]:
    """Generates coordinates for a rounded rectangle (filleted corners) CCW direction."""
    min_x, max_x = min(x1, x2), max(x1, x2)
    min_y, max_y = min(y1, y2), max(y1, y2)
    w = max_x - min_x
    h = max_y - min_y
    r = max(0.0, min(r, w / 2.0, h / 2.0))
    if r < 1e-5:
        return [(min_x, min_y), (max_x, min_y), (max_x, max_y), (min_x, max_y)]
        
    pts = []
    # Corner 1: Bottom-Right (angle from 270 to 360 deg)
    for i in range(9):
        angle = math.radians(270 + i * 11.25)
        pts.append((max_x - r + r * math.cos(angle), min_y + r + r * math.sin(angle)))
    # Corner 2: Top-Right (angle from 0 to 90 deg)
    for i in range(9):
        angle = math.radians(0 + i * 11.25)
        pts.append((max_x - r + r * math.cos(angle), max_y - r + r * math.sin(angle)))
    # Corner 3: Top-Left (angle from 90 to 180 deg)
    for i in range(9):
        angle = math.radians(90 + i * 11.25)
        pts.append((min_x + r + r * math.cos(angle), max_y - r + r * math.sin(angle)))
    # Corner 4: Bottom-Left (angle from 180 to 270 deg)
    for i in range(9):
        angle = math.radians(180 + i * 11.25)
        pts.append((min_x + r + r * math.cos(angle), min_y + r + r * math.sin(angle)))
        
    return pts

def op_add_entity(args: Dict[str, Any]) -> Dict[str, Any]:
    """Adds a new sketch entity (line, circle, or rectangle) to the DXF."""
    input_path = args.get("input")
    output_path = args.get("output")
    ent_type = args.get("type")  # line, circle, rectangle
    params = args.get("params", {})
    layer = sanitize_layer_name(args.get("layer", "ORIGINAL"))

    if not input_path:
        return {"status": "error", "message": "Input path must be specified."}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    # If input file doesn't exist, create a blank new DXF
    if not os.path.exists(input_path):
        doc = ezdxf.new(dxfversion="R2010")
    else:
        doc = ezdxf.readfile(input_path)
        
    msp = doc.modelspace()
    
    if layer not in doc.layers:
        doc.layers.new(layer, dxfattribs={"color": 7})  # white/black

    new_handle = None
    try:
        if ent_type == "line":
            start = params.get("start", [0.0, 0.0])
            end = params.get("end", [0.0, 0.0])
            new_ent = msp.add_line(start=start, end=end, dxfattribs={"layer": layer})
            new_handle = new_ent.dxf.handle
        elif ent_type == "circle":
            center = params.get("center", [0.0, 0.0])
            radius = float(params.get("radius", 1.0))
            if radius > 0:
                new_ent = msp.add_circle(center=center, radius=radius, dxfattribs={"layer": layer})
                new_handle = new_ent.dxf.handle
        elif ent_type == "rectangle":
            p1 = params.get("p1", [0.0, 0.0])
            p2 = params.get("p2", [0.0, 0.0])
            fillet_radius = float(params.get("fillet_radius", 0.0))
            pts = make_rounded_rectangle_points(p1[0], p1[1], p2[0], p2[1], fillet_radius)
            new_ent = msp.add_lwpolyline(pts, dxfattribs={"layer": layer, "closed": True})
            new_handle = new_ent.dxf.handle
        elif ent_type == "path":
            # Pen-tool path (MAS-94): an already-flattened point list becomes an
            # editable LWPOLYLINE (open or closed), so fillet/vertex tools work on it.
            raw_pts = params.get("points", [])
            closed = bool(params.get("closed", False))
            pts = [(float(p[0]), float(p[1])) for p in raw_pts if len(p) >= 2]
            if len(pts) < 2:
                return {"status": "error", "message": "A path needs at least two points."}
            new_ent = msp.add_lwpolyline(pts, dxfattribs={"layer": layer, "closed": closed})
            new_handle = new_ent.dxf.handle
        else:
            return {"status": "error", "message": f"Unsupported entity type: {ent_type}"}
            
        doc.saveas(output_path)
        return {"status": "ok", "data": {"handle": new_handle}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to add entity: {str(e)}"}

# ---------------------------------------------------------------------------
# hardware footprints (assembly_workflow.md Phase 2)
# ---------------------------------------------------------------------------
#
# A piece of hardware (snap, rivet, magnetic clasp, eyelet …) brings its own
# *footprint*: the holes and slots it cuts into the leather. Placing a part stamps
# that footprint onto a HARDWARE layer at a point, so the cut file is correct and
# the part can't drift out of registration. The stamped cuts also double as
# keep-out geometry — `op_add_holes` already gaps the stitch line around tagged
# hardware (the MAS-120 avoidance path), so a placed snap automatically pushes the
# saddle stitch away from itself.

def _hw_rotate_pt(x: float, y: float, ang_rad: float) -> Tuple[float, float]:
    c, s = math.cos(ang_rad), math.sin(ang_rad)
    return (x * c - y * s, x * s + y * c)


def _hw_stadium_points(cx: float, cy: float, length: float, width: float,
                       ang_rad: float, n_cap: int = 10) -> List[Tuple[float, float]]:
    """Closed stadium (rounded-slot) outline centred at (cx,cy): a `length`-long,
    `width`-wide capsule whose long axis is +x rotated by `ang_rad`."""
    r = max(width, 0.0) / 2.0
    half = max(length / 2.0 - r, 0.0)
    local: List[Tuple[float, float]] = []
    # right cap: +90° → -90° (through the rightmost point)
    for k in range(n_cap + 1):
        a = math.pi / 2.0 - math.pi * k / n_cap
        local.append((half + r * math.cos(a), r * math.sin(a)))
    # left cap: -90° → -270° (through the leftmost point)
    for k in range(n_cap + 1):
        a = -math.pi / 2.0 - math.pi * k / n_cap
        local.append((-half + r * math.cos(a), r * math.sin(a)))
    return [(cx + rx, cy + ry)
            for (rx, ry) in (_hw_rotate_pt(x, y, ang_rad) for (x, y) in local)]


def op_place_hardware(args: Dict[str, Any]) -> Dict[str, Any]:
    """Stamps a hardware footprint — the holes / slots a part cuts — into the sketch.

    args:
      input, output : DXF paths
      footprint      : [{kind:"hole", dx, dy, dia}
                        | {kind:"slot", dx, dy, length, width, angle}]
                       offsets are in the part's local frame (mm), about `center`.
      center         : [x, y] placement point (default origin)
      rotation       : whole-part rotation (degrees, default 0)
      layer          : target layer (default "HARDWARE")

    Returns the new entity handles. The stamped cuts double as keep-out geometry.
    """
    input_path = args.get("input")
    output_path = args.get("output")
    if not input_path or not output_path:
        return {"status": "error", "message": "Input and output paths are required."}
    footprint = args.get("footprint") or []
    center = args.get("center") or [0.0, 0.0]
    cx, cy = float(center[0]), float(center[1])
    rot = math.radians(float(args.get("rotation", 0.0) or 0.0))
    layer = sanitize_layer_name(args.get("layer", "HARDWARE"))

    doc = ezdxf.new(dxfversion="R2010") if not os.path.exists(input_path) else ezdxf.readfile(input_path)
    msp = doc.modelspace()
    if layer not in doc.layers:
        doc.layers.new(layer, dxfattribs={"color": 6})  # magenta — hardware cuts

    handles: List[str] = []
    try:
        for prim in footprint:
            kind = prim.get("kind", "hole")
            ox, oy = _hw_rotate_pt(float(prim.get("dx", 0.0)), float(prim.get("dy", 0.0)), rot)
            px, py = cx + ox, cy + oy
            if kind == "hole":
                r = float(prim.get("dia", 1.0)) / 2.0
                if r > 0:
                    e = msp.add_circle(center=(px, py), radius=r, dxfattribs={"layer": layer})
                    handles.append(e.dxf.handle)
            elif kind == "slot":
                ang = rot + math.radians(float(prim.get("angle", 0.0) or 0.0))
                pts = _hw_stadium_points(px, py, float(prim.get("length", 1.0)),
                                         float(prim.get("width", 1.0)), ang)
                e = msp.add_lwpolyline(pts, dxfattribs={"layer": layer, "closed": True})
                handles.append(e.dxf.handle)
            else:
                return {"status": "error", "message": f"Unknown footprint primitive: {kind}"}
        if not handles:
            return {"status": "error", "message": "Hardware footprint produced no cuts."}
        doc.saveas(output_path)
        return {"status": "ok", "data": {"handles": handles, "count": len(handles), "layer": layer}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to place hardware: {e}"}


def op_edge_treatment(args: Dict[str, Any]) -> Dict[str, Any]:
    """Applies a leather edge treatment that *changes the cut pattern* (Phase 2).

    args:
      input, output
      edge      : [[x0,y0],[x1,y1]] the straight edge to finish
      mode      : "turn" (folded-over edge — add a fold-back hem + a crease) |
                  "bind" (bound edge — emit a separate binding strip + creases)
      allowance : mm — turn: hem depth; bind: wrap width per side (default 8)
      thickness : mm — leather thickness the binding wraps (default 2)
      outward   : [nx,ny] normal pointing OFF the panel (default = left of the
                  directed edge); the hem / strip is built on that side.

    A turned edge adds material to the blank (the fold-back) and a FOLD crease on
    the original line; a bound edge produces a strip panel sized to wrap the edge.
    Returns the new entity handles.
    """
    input_path = args.get("input")
    output_path = args.get("output")
    if not input_path or not output_path:
        return {"status": "error", "message": "Input and output paths are required."}
    edge = args.get("edge") or []
    if len(edge) < 2:
        return {"status": "error", "message": "An edge needs two endpoints."}
    mode = args.get("mode", "turn")
    allowance = float(args.get("allowance", 8.0) or 0.0)
    thickness = float(args.get("thickness", 2.0) or 0.0)
    p0 = (float(edge[0][0]), float(edge[0][1]))
    p1 = (float(edge[1][0]), float(edge[1][1]))
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    L = math.hypot(dx, dy)
    if L < 1e-9:
        return {"status": "error", "message": "Degenerate edge (zero length)."}
    ux, uy = dx / L, dy / L
    out = args.get("outward")
    if out and len(out) >= 2:
        nx, ny = float(out[0]), float(out[1])
        nl = math.hypot(nx, ny) or 1.0
        nx, ny = nx / nl, ny / nl
    else:
        nx, ny = -uy, ux  # left normal of the directed edge

    doc = ezdxf.new(dxfversion="R2010") if not os.path.exists(input_path) else ezdxf.readfile(input_path)
    msp = doc.modelspace()
    for lname, col in (("FOLD", 5), ("EDGE_TURN", 4), ("BINDING", 3)):
        if lname not in doc.layers:
            doc.layers.new(lname, dxfattribs={"color": col})

    def off(p, dist):
        return (p[0] + nx * dist, p[1] + ny * dist)

    handles: List[str] = []
    try:
        if mode == "turn":
            quad = [p0, p1, off(p1, allowance), off(p0, allowance)]
            e = msp.add_lwpolyline(quad, dxfattribs={"layer": "EDGE_TURN", "closed": True})
            handles.append(e.dxf.handle)
            c = msp.add_line(start=p0, end=p1, dxfattribs={"layer": "FOLD"})
            handles.append(c.dxf.handle)
        elif mode == "bind":
            W = 2.0 * allowance + thickness
            strip = [p0, p1, off(p1, W), off(p0, W)]
            e = msp.add_lwpolyline(strip, dxfattribs={"layer": "BINDING", "closed": True})
            handles.append(e.dxf.handle)
            for d in (allowance, allowance + thickness):  # the two wrap creases
                c = msp.add_line(start=off(p0, d), end=off(p1, d), dxfattribs={"layer": "FOLD"})
                handles.append(c.dxf.handle)
        else:
            return {"status": "error", "message": f"Unknown edge treatment: {mode}"}
        doc.saveas(output_path)
        return {"status": "ok", "data": {"handles": handles, "count": len(handles),
                                         "mode": mode, "edgeLength": L}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to apply edge treatment: {e}"}


def op_insert_net(args: Dict[str, Any]) -> Dict[str, Any]:
    """Stamps a fold-up *net* — panel outline(s) + fold lines — into the sketch
    (Phase 2 parametric assembly templates). The outlines are closed panels and the
    fold lines land on the FOLD layer, so switching to Construct mode folds the net
    up into the 3D object (a tray, a sleeve, a flap pouch …).

    args: input, output,
          panels = [[[x,y], ...], ...]  closed outlines,
          folds  = [[[x0,y0],[x1,y1]], ...]  fold segments,
          outline_layer (default "ORIGINAL"), fold_layer (default "FOLD").
    Returns the new entity handles.
    """
    input_path = args.get("input")
    output_path = args.get("output")
    if not input_path or not output_path:
        return {"status": "error", "message": "Input and output paths are required."}
    panels = args.get("panels") or []
    folds = args.get("folds") or []
    if not panels:
        return {"status": "error", "message": "A net needs at least one panel outline."}
    outline_layer = sanitize_layer_name(args.get("outline_layer", "ORIGINAL"))
    fold_layer = sanitize_layer_name(args.get("fold_layer", "FOLD"))

    doc = ezdxf.new(dxfversion="R2010") if not os.path.exists(input_path) else ezdxf.readfile(input_path)
    msp = doc.modelspace()
    if fold_layer not in doc.layers:
        doc.layers.new(fold_layer, dxfattribs={"color": 5})  # blue creases

    handles: List[str] = []
    try:
        for outline in panels:
            pts = [(float(p[0]), float(p[1])) for p in outline if len(p) >= 2]
            if len(pts) < 3:
                continue
            e = msp.add_lwpolyline(pts, dxfattribs={"layer": outline_layer, "closed": True})
            handles.append(e.dxf.handle)
        for seg in folds:
            if len(seg) < 2:
                continue
            c = msp.add_line(start=(float(seg[0][0]), float(seg[0][1])),
                             end=(float(seg[1][0]), float(seg[1][1])),
                             dxfattribs={"layer": fold_layer})
            handles.append(c.dxf.handle)
        if not handles:
            return {"status": "error", "message": "Net produced no geometry."}
        doc.saveas(output_path)
        return {"status": "ok", "data": {"handles": handles, "count": len(handles),
                                         "panels": len(panels), "folds": len(folds)}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to insert net: {e}"}


def get_entities_bounds(msp, handles: List[str]) -> Optional[Tuple[float, float, float, float]]:
    """Calculates bounds of specific entity handles in modelspace, or all if empty."""
    from ezdxf.path import make_path
    min_x, min_y = float('inf'), float('inf')
    max_x, max_y = float('-inf'), float('-inf')
    found = False
    
    # Filter entities
    targets = []
    if handles:
        for h in handles:
            try:
                targets.append(msp.doc.entitydb[h])
            except KeyError:
                pass
    else:
        targets = [e for e in msp if e.dxftype() in ("LINE", "ARC", "CIRCLE", "LWPOLYLINE", "POLYLINE", "SPLINE", "ELLIPSE", "TEXT")]
        
    for ent in targets:
        if ent.dxftype() == "LINE":
            min_x = min(min_x, ent.dxf.start.x, ent.dxf.end.x)
            max_x = max(max_x, ent.dxf.start.x, ent.dxf.end.x)
            min_y = min(min_y, ent.dxf.start.y, ent.dxf.end.y)
            max_y = max(max_y, ent.dxf.start.y, ent.dxf.end.y)
            found = True
        elif ent.dxftype() in ("CIRCLE", "ARC"):
            cx, cy = ent.dxf.center.x, ent.dxf.center.y
            r = ent.dxf.radius
            min_x = min(min_x, cx - r)
            max_x = max(max_x, cx + r)
            min_y = min(min_y, cy - r)
            max_y = max(max_y, cy + r)
            found = True
        elif ent.dxftype() in ("LWPOLYLINE", "POLYLINE"):
            for p in ent.get_points() if hasattr(ent, 'get_points') else ent.points:
                min_x = min(min_x, p[0])
                max_x = max(max_x, p[0])
                min_y = min(min_y, p[1])
                max_y = max(max_y, p[1])
            found = True
        elif ent.dxftype() in ("SPLINE", "ELLIPSE"):
            try:
                path = make_path(ent)
                for p in path.flattening(distance=0.1):
                    min_x = min(min_x, p.x)
                    max_x = max(max_x, p.x)
                    min_y = min(min_y, p.y)
                    max_y = max(max_y, p.y)
                found = True
            except Exception:
                pass
        elif ent.dxftype() == "TEXT":
            min_x = min(min_x, ent.dxf.insert.x)
            max_x = max(max_x, ent.dxf.insert.x)
            min_y = min(min_y, ent.dxf.insert.y)
            max_y = max(max_y, ent.dxf.insert.y + ent.dxf.height)
            found = True
                
    if not found:
        return None
    return min_x, min_y, max_x, max_y

def op_offset_bbox(args: Dict[str, Any]) -> Dict[str, Any]:
    """Creates an expanded bounding box rectangle around selected entities."""
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    distance = float(args.get("distance", 5.0))
    fillet_radius = float(args.get("fillet_radius", 0.0))
    layer = sanitize_layer_name(args.get("layer", "OFFSET"))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    if layer not in doc.layers:
        doc.layers.new(layer, dxfattribs={"color": 3})  # Green by default

    bounds = get_entities_bounds(msp, handles)
    if not bounds:
        return {"status": "error", "message": "No valid geometry bounds found to offset."}

    min_x, min_y, max_x, max_y = bounds
    # Expand by distance
    min_x -= distance
    max_x += distance
    min_y -= distance
    max_y += distance

    try:
        pts = make_rounded_rectangle_points(min_x, min_y, max_x, max_y, fillet_radius)
        new_ent = msp.add_lwpolyline(pts, dxfattribs={"layer": layer, "closed": True})
        doc.saveas(output_path)
        return {"status": "ok", "data": {"handle": new_ent.dxf.handle}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to perform bounding box offset: {str(e)}"}

def op_update_entity(args: Dict[str, Any]) -> Dict[str, Any]:
    """Updates the geometry coordinates or parameters of a sketched entity."""
    input_path = args.get("input")
    output_path = args.get("output")
    handle = args.get("handle")
    ent_type = args.get("type")  # line, circle, rectangle, text
    params = args.get("params", {})

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handle:
        return {"status": "error", "message": "Handle must be specified."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    try:
        ent = doc.entitydb[handle]
    except KeyError:
        return {"status": "error", "message": f"Entity with handle {handle} not found."}

    try:
        if ent_type == "line":
            start = params.get("start")
            end = params.get("end")
            if start:
                ent.dxf.start = (float(start[0]), float(start[1]))
            if end:
                ent.dxf.end = (float(end[0]), float(end[1]))
        elif ent_type == "circle":
            radius = params.get("radius")
            if radius is not None:
                ent.dxf.radius = float(radius)
            center = params.get("center")
            if center:
                ent.dxf.center = (float(center[0]), float(center[1]))
        elif ent_type == "rectangle":
            p1 = params.get("p1")
            p2 = params.get("p2")
            fillet_radius = float(params.get("fillet_radius", 0.0))
            if p1 and p2:
                pts = make_rounded_rectangle_points(float(p1[0]), float(p1[1]), float(p2[0]), float(p2[1]), fillet_radius)
                ent.set_points(pts)
        elif ent_type == "text":
            text = params.get("text")
            if text is not None:
                ent.text = str(text)
                ent.dxf.text = str(text)
            height = params.get("height")
            if height is not None:
                ent.dxf.height = float(height)
            insert = params.get("insert")
            if insert:
                ent.dxf.insert = (float(insert[0]), float(insert[1]))
        else:
            return {"status": "error", "message": f"Unsupported update type: {ent_type}"}

        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to update entity: {str(e)}"}

def get_point_and_normal(path: LineString, d: float, is_closed: bool) -> Tuple[Tuple[float, float], Tuple[float, float]]:
    L = path.length
    if L < 1e-6:
        coord = path.coords[0]
        return (coord[0], coord[1]), (0.0, 1.0)
    if is_closed:
        d = d % L
    pt = path.interpolate(d)
    eps = 1e-4
    if is_closed:
        pt1 = path.interpolate((d - eps) % L)
        pt2 = path.interpolate((d + eps) % L)
    else:
        d1 = max(0.0, d - eps)
        d2 = min(L, d + eps)
        pt1 = path.interpolate(d1)
        pt2 = path.interpolate(d2)
    dx = pt2.x - pt1.x
    dy = pt2.y - pt1.y
    length = math.hypot(dx, dy)
    if length < 1e-8:
        return (pt.x, pt.y), (0.0, 1.0)
    tx = dx / length
    ty = dy / length
    return (pt.x, pt.y), (-ty, tx)

def select_optimal_spacing(candidates: List[Tuple[float, float]], path_is_closed: bool, target_spacing: float, enable_variable_spacing: bool, var_min: float = 4.0, var_max: float = 5.0) -> float:
    if not candidates:
        return target_spacing
    if not path_is_closed or not enable_variable_spacing:
        return target_spacing
    best_spacing = target_spacing
    min_error = float('inf')
    steps = int(math.ceil((var_max - var_min) / 0.1))
    for step in range(steps + 1):
        spacing_val = var_min + step * 0.1
        if spacing_val > var_max + 1e-5:
            break
        count = 0
        first = candidates[0]
        last_selected = first
        for idx in range(1, len(candidates)):
            curr = candidates[idx]
            dist = math.hypot(curr[0] - last_selected[0], curr[1] - last_selected[1])
            if dist >= spacing_val:
                last_selected = curr
                count += 1
        if count > 0:
            d_end = math.hypot(first[0] - last_selected[0], first[1] - last_selected[1])
            error = abs(d_end - spacing_val)
            if error < min_error:
                min_error = error
                best_spacing = spacing_val
    return best_spacing

def filter_by_density(pts: List[Tuple[float, float]], spacing_val: float, shift: float = 0.0) -> List[Tuple[float, float]]:
    selected = []
    if not pts:
        return selected
    start_idx = 0
    if shift > 0.0:
        accum_dist = 0.0
        for i in range(1, len(pts)):
            d = math.hypot(pts[i][0] - pts[i-1][0], pts[i][1] - pts[i-1][1])
            accum_dist += d
            if accum_dist >= shift:
                start_idx = i
                break
    if start_idx >= len(pts):
        return selected
    last = pts[start_idx]
    selected.append(last)
    for i in range(start_idx + 1, len(pts)):
        curr = pts[i]
        dist = math.hypot(curr[0] - last[0], curr[1] - last[1])
        if dist >= spacing_val:
            selected.append(curr)
            last = curr
    return selected

def collapse_ribbon_to_centerline(coords: List[Tuple[float, float]], max_width: float = 5.0) -> List[Tuple[float, float]]:
    if len(coords) < 4:
        return coords
    if coords[0] != coords[-1]:
        coords = list(coords) + [coords[0]]
    try:
        poly = LinearRing(coords)
        from shapely.geometry import Polygon
        poly_geom = Polygon(poly)
        area = poly_geom.area
        perimeter = poly_geom.length
    except Exception:
        return coords
    width_est = 2.0 * area / perimeter if perimeter > 0 else 0.0
    if width_est <= 0.0 or width_est > max_width:
        return coords
    n = len(coords) - 1
    max_d = 0.0
    idx1, idx2 = 0, 0
    for i in range(n):
        for j in range(i + 1, n):
            d = math.hypot(coords[i][0] - coords[j][0], coords[i][1] - coords[j][1])
            if d > max_d:
                max_d = d
                idx1, idx2 = i, j
    if idx1 > idx2:
        idx1, idx2 = idx2, idx1
    path1 = coords[idx1:idx2+1]
    path2 = coords[idx2:] + coords[:idx1+1]
    if not path1 or not path2:
        return coords
    ls1 = LineString(path1)
    ls2 = LineString(path2)
    num_samples = 20
    center_coords = []
    for k in range(num_samples + 1):
        t = k / num_samples
        p1 = ls1.interpolate(t * ls1.length)
        p2 = ls2.interpolate((1.0 - t) * ls2.length)
        mx = (p1.x + p2.x) / 2.0
        my = (p1.y + p2.y) / 2.0
        center_coords.append((mx, my))
    return center_coords

def parse_svg_d(d_str: str) -> List[List[Tuple[float, float]]]:
    import re
    tokens = []
    pattern = re.compile(r'([MmLlHhVvCcSsQqTtAazZ])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)')
    for m in pattern.finditer(d_str):
        cmd, num = m.groups()
        if cmd:
            tokens.append(cmd)
        elif num:
            tokens.append(float(num))
    paths = []
    curr_path = []
    cx, cy = 0.0, 0.0
    sx, sy = 0.0, 0.0
    idx = 0
    n = len(tokens)
    last_cmd = None
    last_cx, last_cy = 0.0, 0.0
    while idx < n:
        tok = tokens[idx]
        if isinstance(tok, str):
            cmd = tok
            idx += 1
        else:
            cmd = last_cmd
        if not cmd:
            break
        if cmd in ('M', 'm'):
            if idx + 1 >= n: break
            x, y = tokens[idx], tokens[idx+1]
            idx += 2
            if cmd == 'm':
                cx += x; cy += y
            else:
                cx = x; cy = y
            sx, sy = cx, cy
            if curr_path:
                paths.append(curr_path)
            curr_path = [(cx, cy)]
            last_cmd = 'L' if cmd == 'M' else 'l'
        elif cmd in ('L', 'l'):
            if idx + 1 >= n: break
            x, y = tokens[idx], tokens[idx+1]
            idx += 2
            if cmd == 'l':
                cx += x; cy += y
            else:
                cx = x; cy = y
            curr_path.append((cx, cy))
            last_cmd = cmd
        elif cmd in ('H', 'h'):
            if idx >= n: break
            x = tokens[idx]
            idx += 1
            if cmd == 'h':
                cx += x
            else:
                cx = x
            curr_path.append((cx, cy))
            last_cmd = cmd
        elif cmd in ('V', 'v'):
            if idx >= n: break
            y = tokens[idx]
            idx += 1
            if cmd == 'v':
                cy += y
            else:
                cy = y
            curr_path.append((cx, cy))
            last_cmd = cmd
        elif cmd in ('C', 'c'):
            if idx + 5 >= n: break
            x1, y1 = tokens[idx], tokens[idx+1]
            x2, y2 = tokens[idx+2], tokens[idx+3]
            x, y = tokens[idx+4], tokens[idx+5]
            idx += 6
            if cmd == 'c':
                x1 += cx; y1 += cy
                x2 += cx; y2 += cy
                x += cx; y += cy
            p0 = (cx, cy)
            for step in range(1, 11):
                t = step / 10.0
                px = (1-t)**3 * p0[0] + 3*(1-t)**2 * t * x1 + 3*(1-t) * t**2 * x2 + t**3 * x
                py = (1-t)**3 * p0[1] + 3*(1-t)**2 * t * y1 + 3*(1-t) * t**2 * y2 + t**3 * y
                curr_path.append((px, py))
            cx, cy = x, y
            last_cx, last_cy = x2, y2
            last_cmd = cmd
        elif cmd in ('S', 's'):
            if idx + 3 >= n: break
            x2, y2 = tokens[idx], tokens[idx+1]
            x, y = tokens[idx+2], tokens[idx+3]
            idx += 4
            if cmd == 's':
                x2 += cx; y2 += cy
                x += cx; y += cy
            if last_cmd in ('C', 'c', 'S', 's'):
                x1 = 2 * cx - last_cx
                y1 = 2 * cy - last_cy
            else:
                x1, y1 = cx, cy
            p0 = (cx, cy)
            for step in range(1, 11):
                t = step / 10.0
                px = (1-t)**3 * p0[0] + 3*(1-t)**2 * t * x1 + 3*(1-t) * t**2 * x2 + t**3 * x
                py = (1-t)**3 * p0[1] + 3*(1-t)**2 * t * y1 + 3*(1-t) * t**2 * y2 + t**3 * y
                curr_path.append((px, py))
            cx, cy = x, y
            last_cx, last_cy = x2, y2
            last_cmd = cmd
        elif cmd in ('Q', 'q'):
            if idx + 3 >= n: break
            x1, y1 = tokens[idx], tokens[idx+1]
            x, y = tokens[idx+2], tokens[idx+3]
            idx += 4
            if cmd == 'q':
                x1 += cx; y1 += cy
                x += cx; y += cy
            p0 = (cx, cy)
            for step in range(1, 11):
                t = step / 10.0
                px = (1-t)**2 * p0[0] + 2*(1-t)*t * x1 + t**2 * x
                py = (1-t)**2 * p0[1] + 2*(1-t)*t * y1 + t**2 * y
                curr_path.append((px, py))
            cx, cy = x, y
            last_cx, last_cy = x1, y1
            last_cmd = cmd
        elif cmd in ('T', 't'):
            if idx + 1 >= n: break
            x, y = tokens[idx], tokens[idx+1]
            idx += 2
            if cmd == 't':
                x += cx; y += cy
            if last_cmd in ('Q', 'q', 'T', 't'):
                x1 = 2 * cx - last_cx
                y1 = 2 * cy - last_cy
            else:
                x1, y1 = cx, cy
            p0 = (cx, cy)
            for step in range(1, 11):
                t = step / 10.0
                px = (1-t)**2 * p0[0] + 2*(1-t)*t * x1 + t**2 * x
                py = (1-t)**2 * p0[1] + 2*(1-t)*t * y1 + t**2 * y
                curr_path.append((px, py))
            cx, cy = x, y
            last_cx, last_cy = x1, y1
            last_cmd = cmd
        elif cmd in ('A', 'a'):
            if idx + 6 >= n: break
            rx, ry = tokens[idx], tokens[idx+1]
            rot = tokens[idx+2]
            large_arc = tokens[idx+3]
            sweep = tokens[idx+4]
            x, y = tokens[idx+5], tokens[idx+6]
            idx += 7
            if cmd == 'a':
                x += cx; y += cy
            p0 = (cx, cy)
            for step in range(1, 6):
                t = step / 5.0
                px = p0[0] + (x - p0[0]) * t
                py = p0[1] + (y - p0[1]) * t
                curr_path.append((px, py))
            cx, cy = x, y
            last_cmd = cmd
        elif cmd in ('Z', 'z'):
            cx, cy = sx, sy
            curr_path.append((cx, cy))
            if curr_path:
                paths.append(curr_path)
            curr_path = []
            last_cmd = cmd
    if curr_path:
        paths.append(curr_path)
    return paths

def op_set_layer(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    layer_raw = args.get("layer")
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not layer_raw:
        return {"status": "error", "message": "Layer name must be specified."}
    layer = sanitize_layer_name(layer_raw)
    doc = ezdxf.readfile(input_path)
    if layer not in doc.layers:
        doc.layers.new(layer)
    for h in handles:
        try:
            ent = doc.entitydb[h]
            ent.dxf.layer = layer
        except KeyError:
            pass
    doc.saveas(output_path)
    return {"status": "ok"}

def parse_svg_val(val_str: Any) -> float:
    if val_str is None:
        return 0.0
    if isinstance(val_str, (int, float)):
        return float(val_str)
    val_str = str(val_str).strip()
    if not val_str:
        return 0.0
    import re
    match = re.match(r'^\s*([+-]?\d*(?:\.\d+)?(?:[eE][+-]?\d+)?)\s*([a-zA-Z%]*)\s*$', val_str)
    if not match:
        return 0.0
    num_str, unit = match.groups()
    if not num_str:
        return 0.0
    val = float(num_str)
    unit = unit.lower()
    if unit == 'mm':
        return val
    elif unit == 'cm':
        return val * 10.0
    elif unit == 'in':
        return val * 25.4
    elif unit == 'pt':
        return val * (25.4 / 72.0)
    elif unit == 'pc':
        return val * (25.4 / 6.0)
    else:
        return val

def translate_to_positive_quadrant(doc, target_min: float = 10.0):
    msp = doc.modelspace()
    import math
    min_x = float('inf')
    min_y = float('inf')
    
    # Calculate bounding box of all modelspace entities
    has_geom = False
    for ent in msp:
        if ent.dxftype() == "LINE":
            min_x = min(min_x, ent.dxf.start.x, ent.dxf.end.x)
            min_y = min(min_y, ent.dxf.start.y, ent.dxf.end.y)
            has_geom = True
        elif ent.dxftype() in ("CIRCLE", "ARC"):
            r = ent.dxf.radius
            min_x = min(min_x, ent.dxf.center.x - r)
            min_y = min(min_y, ent.dxf.center.y - r)
            has_geom = True
        elif ent.dxftype() in ("LWPOLYLINE", "POLYLINE"):
            try:
                for p in (ent.get_points() if hasattr(ent, 'get_points') else ent.points):
                    min_x = min(min_x, p[0])
                    min_y = min(min_y, p[1])
                    has_geom = True
            except Exception:
                pass
        elif ent.dxftype() in ("SPLINE", "ELLIPSE"):
            if hasattr(ent, "control_points") and ent.control_points:
                for p in ent.control_points:
                    min_x = min(min_x, p[0])
                    min_y = min(min_y, p[1])
                    has_geom = True
            if hasattr(ent, "fit_points") and ent.fit_points:
                for p in ent.fit_points:
                    min_x = min(min_x, p[0])
                    min_y = min(min_y, p[1])
                    has_geom = True
        elif ent.dxftype() == "TEXT":
            min_x = min(min_x, ent.dxf.insert.x)
            min_y = min(min_y, ent.dxf.insert.y)
            has_geom = True
            
    if not has_geom or min_x == float('inf'):
        return
        
    dx = target_min - min_x
    dy = target_min - min_y
    translate_doc(doc, dx, dy)


def translate_doc(doc, dx: float, dy: float):
    """Translates every modelspace entity in `doc` by (dx, dy). Shared by the
    positive-quadrant normaliser and the multi-file distribute importer."""
    if abs(dx) < 1e-4 and abs(dy) < 1e-4:
        return
    msp = doc.modelspace()
    for ent in msp:
        if ent.dxftype() == "LINE":
            ent.dxf.start = (ent.dxf.start.x + dx, ent.dxf.start.y + dy)
            ent.dxf.end = (ent.dxf.end.x + dx, ent.dxf.end.y + dy)
        elif ent.dxftype() in ("CIRCLE", "ARC"):
            ent.dxf.center = (ent.dxf.center.x + dx, ent.dxf.center.y + dy)
        elif ent.dxftype() in ("LWPOLYLINE", "POLYLINE"):
            points = []
            for p in (ent.get_points() if hasattr(ent, 'get_points') else ent.points):
                pts_list = list(p)
                pts_list[0] += dx
                pts_list[1] += dy
                points.append(tuple(pts_list))
            if hasattr(ent, 'set_points'):
                ent.set_points(points)
            else:
                ent.points = points
        elif ent.dxftype() in ("SPLINE", "ELLIPSE"):
            if hasattr(ent, "control_points") and ent.control_points:
                ent.control_points = [(p[0]+dx, p[1]+dy, p[2] if len(p) > 2 else 0.0) for p in ent.control_points]
            if hasattr(ent, "fit_points") and ent.fit_points:
                ent.fit_points = [(p[0]+dx, p[1]+dy, p[2] if len(p) > 2 else 0.0) for p in ent.fit_points]
        elif ent.dxftype() == "TEXT":
            ent.dxf.insert = (ent.dxf.insert.x + dx, ent.dxf.insert.y + dy)


# DXF $INSUNITS code -> millimetres-per-unit. Covers the units a real CAD/laser
# file is likely to carry; anything not listed (or 0 = unitless) is left as-is so
# we never silently corrupt a file with no declared units (MAS-148).
INSUNITS_TO_MM = {
    1: 25.4,        # inches
    2: 304.8,       # feet
    4: 1.0,         # millimetres
    5: 10.0,        # centimetres
    6: 1000.0,      # metres
    8: 25.4e-6,     # microinches
    9: 0.0254,      # mils
    10: 914.4,      # yards
    14: 100.0,      # decimetres
    15: 10000.0,    # dekametres
    16: 100000.0,   # hectometres
    17: 1.0e9,      # gigametres? (rare) -- keep mapping coherent
    21: 0.0254,     # US survey mil approximation
}

INSUNITS_NAME = {
    0: "unitless", 1: "inches", 2: "feet", 4: "mm", 5: "cm", 6: "m",
    8: "microinches", 9: "mils", 10: "yards", 14: "dm",
}


def scale_doc(doc, factor: float):
    """Uniformly scales every modelspace entity about the origin by `factor`.
    Mirrors `translate_doc`'s explicit per-type handling so it stays correct for
    the same entity set (no reliance on entity.transform). Used to convert an
    imported file's native units to millimetres (MAS-148)."""
    if abs(factor - 1.0) < 1e-9:
        return
    msp = doc.modelspace()
    for ent in msp:
        t = ent.dxftype()
        if t == "LINE":
            ent.dxf.start = (ent.dxf.start.x * factor, ent.dxf.start.y * factor)
            ent.dxf.end = (ent.dxf.end.x * factor, ent.dxf.end.y * factor)
        elif t in ("CIRCLE", "ARC"):
            ent.dxf.center = (ent.dxf.center.x * factor, ent.dxf.center.y * factor)
            ent.dxf.radius = ent.dxf.radius * factor
        elif t in ("LWPOLYLINE", "POLYLINE"):
            points = []
            for p in (ent.get_points() if hasattr(ent, 'get_points') else ent.points):
                pts_list = list(p)
                pts_list[0] *= factor
                pts_list[1] *= factor
                points.append(tuple(pts_list))
            if hasattr(ent, 'set_points'):
                ent.set_points(points)
            else:
                ent.points = points
            # Constant-width polylines carry width in dxf attribs.
            try:
                if ent.dxf.hasattr("const_width"):
                    ent.dxf.const_width *= factor
            except Exception:
                pass
        elif t in ("SPLINE", "ELLIPSE"):
            if hasattr(ent, "control_points") and ent.control_points:
                ent.control_points = [(p[0]*factor, p[1]*factor, (p[2] if len(p) > 2 else 0.0)*factor) for p in ent.control_points]
            if hasattr(ent, "fit_points") and ent.fit_points:
                ent.fit_points = [(p[0]*factor, p[1]*factor, (p[2] if len(p) > 2 else 0.0)*factor) for p in ent.fit_points]
            if t == "ELLIPSE":
                try:
                    ma = ent.dxf.major_axis
                    ent.dxf.major_axis = (ma[0]*factor, ma[1]*factor, (ma[2] if len(ma) > 2 else 0.0)*factor)
                    ent.dxf.center = (ent.dxf.center.x * factor, ent.dxf.center.y * factor)
                except Exception:
                    pass
        elif t == "TEXT":
            ent.dxf.insert = (ent.dxf.insert.x * factor, ent.dxf.insert.y * factor)
            try:
                ent.dxf.height = ent.dxf.height * factor
            except Exception:
                pass


def dxf_units_info(doc):
    """Reads a doc's declared `$INSUNITS` WITHOUT mutating it. Returns
    `(code, unit_name, factor_to_mm)`. We never silently rescale on import:
    ezdxf (and many CAD exporters) default `$INSUNITS` to 6 (metres) even for
    files actually drawn in millimetres, so trusting it blindly would blow most
    imports up 1000x. Instead the app surfaces this as a prompt (MAS-148)."""
    try:
        code = int(doc.header.get('$INSUNITS', 0))
    except Exception:
        code = 0
    factor = INSUNITS_TO_MM.get(code, 1.0)
    name = INSUNITS_NAME.get(code, f"code {code}")
    return code, name, factor


def _entity_bbox(ent) -> Optional[Tuple[float, float, float, float]]:
    """Axis-aligned bbox (minx, miny, maxx, maxy) of one entity, or None for an
    invisible/degenerate one. POINT entities are deliberately ignored — they are
    invisible markers and must never influence distribution layout (MAS-13)."""
    t = ent.dxftype()
    if t == "POINT":
        return None
    xs: List[float] = []
    ys: List[float] = []
    if t == "LINE":
        xs = [ent.dxf.start.x, ent.dxf.end.x]
        ys = [ent.dxf.start.y, ent.dxf.end.y]
    elif t in ("CIRCLE", "ARC"):
        c = ent.dxf.center
        r = ent.dxf.radius
        xs = [c.x - r, c.x + r]
        ys = [c.y - r, c.y + r]
    elif t in ("LWPOLYLINE", "POLYLINE"):
        try:
            pts = list(ent.get_points()) if hasattr(ent, "get_points") else list(ent.points)
        except Exception:
            pts = []
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
    elif t in ("SPLINE", "ELLIPSE"):
        try:
            from ezdxf.path import make_path
            pts = list(make_path(ent).flattening(distance=0.5))
            xs = [p.x for p in pts]
            ys = [p.y for p in pts]
        except Exception:
            return None
    elif t == "TEXT":
        ins = ent.dxf.insert
        h = ent.dxf.height
        xs = [ins.x, ins.x + max(1, len(str(ent.dxf.text))) * h * 0.6]
        ys = [ins.y, ins.y + h]
    else:
        return None
    if not xs or not ys:
        return None
    return (min(xs), min(ys), max(xs), max(ys))


def _entity_bbox_with_points(ent) -> Optional[Tuple[float, float, float, float]]:
    """Calculates bounding box of any entity including POINT types."""
    t = ent.dxftype()
    if t == "POINT":
        loc = ent.dxf.location
        return (loc.x, loc.y, loc.x, loc.y)
    return _entity_bbox(ent)


def get_point_coords(ent) -> Optional[Tuple[float, float]]:
    """Checks if an entity is point-like (isolated or degenerate) and returns its coordinates."""
    t = ent.dxftype()
    if t == "POINT":
        return (ent.dxf.location.x, ent.dxf.location.y)
    elif t == "LINE":
        if math.hypot(ent.dxf.start.x - ent.dxf.end.x, ent.dxf.start.y - ent.dxf.end.y) < 1e-3:
            return (ent.dxf.start.x, ent.dxf.start.y)
    elif t in ("CIRCLE", "ARC"):
        if ent.dxf.radius < 1e-3:
            return (ent.dxf.center.x, ent.dxf.center.y)
    elif t in ("LWPOLYLINE", "POLYLINE"):
        try:
            pts = list(ent.get_points()) if hasattr(ent, "get_points") else list(ent.points)
            if pts:
                xs = [p[0] for p in pts]
                ys = [p[1] for p in pts]
                if (max(xs) - min(xs)) < 1e-3 and (max(ys) - min(ys)) < 1e-3:
                    return (xs[0], ys[0])
        except Exception:
            pass
    elif t in ("SPLINE", "ELLIPSE"):
        try:
            from ezdxf.path import make_path
            pts = list(make_path(ent).flattening(distance=0.5))
            if pts:
                xs = [p.x for p in pts]
                ys = [p.y for p in pts]
                if (max(xs) - min(xs)) < 1e-3 and (max(ys) - min(ys)) < 1e-3:
                    return (xs[0], ys[0])
        except Exception:
            pass
    return None


def entity_to_shapely(ent):
    """Safely converts a DXF entity to a shapely geometry, approximating curves."""
    t = ent.dxftype()
    if t == "LINE":
        return LineString([(ent.dxf.start.x, ent.dxf.start.y), (ent.dxf.end.x, ent.dxf.end.y)])
    elif t == "CIRCLE":
        c = ent.dxf.center
        r = ent.dxf.radius
        pts = [(c.x + r * math.cos(a), c.y + r * math.sin(a)) for a in [i * 2 * math.pi / 32 for i in range(32)]]
        return LinearRing(pts)
    elif t == "ARC":
        c = ent.dxf.center
        r = ent.dxf.radius
        sa = math.radians(ent.dxf.start_angle)
        ea = math.radians(ent.dxf.end_angle)
        if ea < sa:
            ea += 2 * math.pi
        steps = 16
        pts = [(c.x + r * math.cos(sa + (ea - sa) * i / steps), c.y + r * math.sin(sa + (ea - sa) * i / steps)) for i in range(steps + 1)]
        return LineString(pts)
    elif t in ("LWPOLYLINE", "POLYLINE"):
        try:
            pts = list(ent.get_points()) if hasattr(ent, "get_points") else list(ent.points)
            cleaned_pts = []
            for p in pts:
                if not cleaned_pts or math.hypot(p[0] - cleaned_pts[-1][0], p[1] - cleaned_pts[-1][1]) > 1e-5:
                    cleaned_pts.append((p[0], p[1]))
            if len(cleaned_pts) >= 2:
                is_cl = getattr(ent, "closed", False) or getattr(ent, "is_closed", False)
                if is_cl:
                    if math.hypot(cleaned_pts[0][0] - cleaned_pts[-1][0], cleaned_pts[0][1] - cleaned_pts[-1][1]) > 1e-5:
                        cleaned_pts.append(cleaned_pts[0])
                    try:
                        return LinearRing(cleaned_pts)
                    except Exception:
                        return LineString(cleaned_pts)
                else:
                    return LineString(cleaned_pts)
        except Exception:
            pass
    elif t in ("SPLINE", "ELLIPSE"):
        try:
            path = make_path(ent)
            vertices = [(p.x, p.y) for p in path.flattening(distance=0.1)]
            cleaned_pts = []
            for p in vertices:
                if not cleaned_pts or math.hypot(p[0] - cleaned_pts[-1][0], p[1] - cleaned_pts[-1][1]) > 1e-5:
                    cleaned_pts.append(p)
            if len(cleaned_pts) >= 2:
                is_cl = getattr(ent, "closed", False) or getattr(ent, "is_closed", False)
                if is_cl:
                    if math.hypot(cleaned_pts[0][0] - cleaned_pts[-1][0], cleaned_pts[0][1] - cleaned_pts[-1][1]) > 1e-5:
                        cleaned_pts.append(cleaned_pts[0])
                    try:
                        return LinearRing(cleaned_pts)
                    except Exception:
                        return LineString(cleaned_pts)
                else:
                    return LineString(cleaned_pts)
        except Exception:
            pass
    elif t == "TEXT":
        ins = ent.dxf.insert
        h = ent.dxf.height
        w = max(1, len(str(ent.dxf.text))) * h * 0.6
        return LinearRing([(ins.x, ins.y), (ins.x + w, ins.y), (ins.x + w, ins.y + h), (ins.x, ins.y + h)])
    return None


def robust_shape_bounds(msp) -> Optional[Tuple[float, float, float, float]]:
    """Bounding box of a file's *visible shape* for layout. Ignores invisible
    isolated POINT markers and far-flung stray entities that aren't part of the main shape
    (MAS-13): a lone mark off on its own must not balloon a file's footprint and
    shove its neighbours across the canvas. Outliers are entities whose centre is
    more than 4× the median centre-distance from the cluster."""
    import math
    
    # 1. Identify all normal entities and convert them to shapely geometries
    normal_ents = []
    normal_geoms = []
    point_like_ents = []
    point_coords = []
    
    for ent in msp:
        coords = get_point_coords(ent)
        if coords is not None:
            point_like_ents.append(ent)
            point_coords.append(coords)
        else:
            geom = entity_to_shapely(ent)
            if geom is not None:
                normal_ents.append(ent)
                normal_geoms.append(geom)
            else:
                normal_ents.append(ent)

    # 2. For each point-like entity, determine if it touches any normal geometry
    valid_points = []
    for ent, pt_coord in zip(point_like_ents, point_coords):
        pt_geom = ShapelyPoint(pt_coord)
        touches = False
        for ng in normal_geoms:
            try:
                if ng.distance(pt_geom) <= 0.1: # 0.1 mm tolerance
                    touches = True
                    break
            except Exception:
                pass
        if touches:
            valid_points.append(ent)
    
    # 3. Calculate bounding boxes of kept entities
    kept_ents = normal_ents + valid_points
    
    # Fallback if there are only point-like entities (we don't ignore them all)
    if not kept_ents and point_like_ents:
        kept_ents = point_like_ents
        
    boxes = [bb for bb in (_entity_bbox_with_points(e) for e in kept_ents) if bb is not None]
    if not boxes:
        return None
    if len(boxes) <= 2:
        return (min(b[0] for b in boxes), min(b[1] for b in boxes),
                max(b[2] for b in boxes), max(b[3] for b in boxes))
    centers = [((b[0] + b[2]) / 2.0, (b[1] + b[3]) / 2.0) for b in boxes]
    mcx = sorted(c[0] for c in centers)[len(centers) // 2]
    mcy = sorted(c[1] for c in centers)[len(centers) // 2]
    dists = [math.hypot(c[0] - mcx, c[1] - mcy) for c in centers]
    med = sorted(dists)[len(dists) // 2]
    threshold = max(med * 4.0, 1.0)
    kept = [b for b, d in zip(boxes, dists) if d <= threshold]
    if not kept:
        kept = boxes
    return (min(b[0] for b in kept), min(b[1] for b in kept),
            max(b[2] for b in kept), max(b[3] for b in kept))


def _boxes_overlap(cx, cy, w, h, placed, gap):
    """True if a w×h box centred at (cx,cy) overlaps any placed box by > 0.1 mm
    after honouring `gap`. Touching exactly is allowed."""
    c_xmin = cx - w / 2.0
    c_xmax = cx + w / 2.0
    c_ymin = cy - h / 2.0
    c_ymax = cy + h / 2.0
    for px1, py1, px2, py2 in placed:
        if (c_xmin < px2 + gap - 0.1 and c_xmax > px1 - gap + 0.1 and
                c_ymin < py2 + gap - 0.1 and c_ymax > py1 - gap + 0.1):
            return True
    return False


def _boxes_near(b1, b2, tol):
    """True if two (xmin,ymin,xmax,ymax) boxes touch or sit within `tol`."""
    return (b1[0] <= b2[2] + tol and b1[2] >= b2[0] - tol and
            b1[1] <= b2[3] + tol and b1[3] >= b2[1] - tol)


def _best_mat_placement(w, h, placed, mat_w, mat_h, margin):
    """Find the best centre for a w×h box on a finite cutting mat.

    The mat occupies the (+,+) quadrant: [0,mat_w] × [0,mat_h] with its
    bottom-left corner at the model origin. Pieces are never rotated or scaled.
    Among non-overlapping candidates we strongly prefer ones that fit fully
    inside the mat, filling from the bottom-left (rows bottom-up, then
    left-to-right). Pieces that cannot fit are pushed just outside but kept as
    close to the mat as possible. Returns (cx, cy) or None if no candidate is
    free."""
    cands = []
    # Bottom-left grid fill inside the mat.
    if mat_w > 0 and mat_h > 0:
        step = max(margin, min(w, h) * 0.5, 5.0)
        max_x = max(0.0, mat_w - w)
        max_y = max(0.0, mat_h - h)
        xs, x = [], 0.0
        while x < max_x + step:
            xs.append(min(x, max_x))
            x += step
        ys, y = [], 0.0
        while y < max_y + step:
            ys.append(min(y, max_y))
            y += step
        for yy in ys:
            for xx in xs:
                cands.append((xx + w / 2.0, yy + h / 2.0))
    # Neighbour candidates around placed boxes help tight packing.
    for p_xmin, p_ymin, p_xmax, p_ymax in placed:
        cands.append((p_xmax + w / 2.0 + margin, p_ymin + h / 2.0))   # right, bottom-aligned
        cands.append((p_xmin + w / 2.0, p_ymax + h / 2.0 + margin))   # above, left-aligned
        cands.append((p_xmax + w / 2.0 + margin, p_ymax - h / 2.0))
        cands.append((p_xmin + w / 2.0, p_ymin - h / 2.0 - margin))

    row_weight = mat_w + 10.0   # so row (y) dominates column (x) in the fill order
    best, best_score = None, float('inf')
    for cx, cy in cands:
        if _boxes_overlap(cx, cy, w, h, placed, margin):
            continue
        c_xmin = cx - w / 2.0
        c_xmax = cx + w / 2.0
        c_ymin = cy - h / 2.0
        c_ymax = cy + h / 2.0
        over = (max(0.0, -c_xmin) + max(0.0, c_xmax - mat_w) +
                max(0.0, -c_ymin) + max(0.0, c_ymax - mat_h))
        fill = c_ymin * row_weight + c_xmin
        if over <= 1e-6:
            score = fill                     # fully inside — pure bottom-left fill
        else:
            score = 1e9 + over * 1000.0 + fill   # overflow — hug the mat, stay close
        if score < best_score:
            best_score, best = score, (cx, cy)
    return best


def op_import_distribute(args: Dict[str, Any]) -> Dict[str, Any]:
    """Merges several DXF files into `primary`, arranging them in a compact,
    centred layout fitting viewport aspect ratio (around 1.5) close to the origin,
    using robust bounding box and margin (MAS-13)."""
    import math
    primary_path = args.get("primary")
    output_path = args.get("output")
    secondaries = args.get("secondaries", [])
    layer_names = args.get("layer_names", [])
    margin_override = args.get("gap")
    # Cutting mat: when enabled, pack pieces inside [0,mat_w]×[0,mat_h] (no
    # rotation/scaling); overflow hugs the mat. Off = original origin-centred
    # layout, byte-identical.
    mat_w = float(args.get("mat_w", 0) or 0)
    mat_h = float(args.get("mat_h", 0) or 0)
    mat_enabled = bool(args.get("mat_enabled", False)) and mat_w > 0 and mat_h > 0

    if not primary_path or not os.path.exists(primary_path):
        return {"status": "error", "message": f"Primary file not found: {primary_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    try:
        primary_doc = ezdxf.readfile(primary_path)
        primary_msp = primary_doc.modelspace()

        # Load each secondary and measure its bounds.
        loaded = []  # list of (sec_doc, bbox)
        for sec_path in secondaries:
            if not sec_path or not os.path.exists(sec_path):
                continue
            try:
                sec_doc = ezdxf.readfile(sec_path)
            except Exception:
                continue
            b = robust_shape_bounds(sec_doc.modelspace())
            # Fallback to (0,0,0,0) if bounds is None (degenerate or empty secondary)
            if b is None:
                b = (0.0, 0.0, 0.0, 0.0)
            loaded.append((sec_doc, b))

        n = len(loaded)
        if n == 0:
            primary_doc.saveas(output_path)
            return {"status": "ok", "data": {"merged": 0}}

        # Define the margin
        if margin_override is not None:
            margin = float(margin_override)
        else:
            margin = 20.0  # standard 20mm gap

        # Initialize placed boxes
        P = []
        pbounds = robust_shape_bounds(primary_msp)
        if pbounds is not None:
            P.append(pbounds)

        def check_overlap(cx, cy, w, h, placed_boxes, gap):
            c_xmin = cx - w/2.0
            c_xmax = cx + w/2.0
            c_ymin = cy - h/2.0
            c_ymax = cy + h/2.0
            for px1, py1, px2, py2 in placed_boxes:
                # We subtract a tiny epsilon (0.1) so that touching exactly is allowed,
                # but any overlap of more than 0.1 mm is rejected.
                if (c_xmin < px2 + gap - 0.1 and c_xmax > px1 - gap + 0.1 and
                    c_ymin < py2 + gap - 0.1 and c_ymax > py1 - gap + 0.1):
                    return True
            return False

        merged = 0
        handles_per_file = []   # MAS-76: new handles produced by each secondary
        for idx, (sec_doc, b) in enumerate(loaded):
            w = b[2] - b[0]
            h = b[3] - b[1]
            fcx = (b[0] + b[2]) / 2.0
            fcy = (b[1] + b[3]) / 2.0

            if mat_enabled:
                # Pack into the mat from the bottom-left; existing canvas content
                # (the primary) is treated as an obstacle but never moved.
                best = _best_mat_placement(w, h, P, mat_w, mat_h, margin)
                if best is None:
                    px_max = max((bx[2] for bx in P), default=mat_w)
                    best = (px_max + w/2.0 + margin, h/2.0)
                best_cx, best_cy = best
                translate_doc(sec_doc, best_cx - fcx, best_cy - fcy)
                B = (best_cx - w/2.0, best_cy - h/2.0, best_cx + w/2.0, best_cy + h/2.0)
                P.append(B)
            elif not P:
                # Empty canvas: center first shape at (0, 0)
                cx, cy = 0.0, 0.0
                translate_doc(sec_doc, cx - fcx, cy - fcy)
                B = (-w/2.0, -h/2.0, w/2.0, h/2.0)
                P.append(B)
            else:
                candidates = []
                # Generate candidate positions around all placed boxes
                for p_xmin, p_ymin, p_xmax, p_ymax in P:
                    mid_p_x = (p_xmin + p_xmax) / 2.0
                    mid_p_y = (p_ymin + p_ymax) / 2.0

                    # Right
                    cx_r = p_xmax + w/2.0 + margin
                    candidates.append((cx_r, mid_p_y))
                    candidates.append((cx_r, p_ymax - h/2.0))
                    candidates.append((cx_r, p_ymin + h/2.0))

                    # Left
                    cx_l = p_xmin - w/2.0 - margin
                    candidates.append((cx_l, mid_p_y))
                    candidates.append((cx_l, p_ymax - h/2.0))
                    candidates.append((cx_l, p_ymin + h/2.0))

                    # Top
                    cy_t = p_ymax + h/2.0 + margin
                    candidates.append((mid_p_x, cy_t))
                    candidates.append((p_xmax - w/2.0, cy_t))
                    candidates.append((p_xmin + w/2.0, cy_t))

                    # Bottom
                    cy_b = p_ymin - h/2.0 - margin
                    candidates.append((mid_p_x, cy_b))
                    candidates.append((p_xmax - w/2.0, cy_b))
                    candidates.append((p_xmin + w/2.0, cy_b))

                # Score candidates
                best_cx, best_cy = None, None
                best_score = float('inf')

                for cx_cand, cy_cand in candidates:
                    if not check_overlap(cx_cand, cy_cand, w, h, P, margin):
                        # Evaluate score
                        c_xmin = cx_cand - w/2.0
                        c_xmax = cx_cand + w/2.0
                        c_ymin = cy_cand - h/2.0
                        c_ymax = cy_cand + h/2.0

                        comb_xmin = min(c_xmin, min(bx[0] for bx in P))
                        comb_xmax = max(c_xmax, max(bx[2] for bx in P))
                        comb_ymin = min(c_ymin, min(bx[1] for bx in P))
                        comb_ymax = max(c_ymax, max(bx[3] for bx in P))

                        comb_w = comb_xmax - comb_xmin
                        comb_h = comb_ymax - comb_ymin
                        perimeter = 2.0 * (comb_w + comb_h)

                        aspect_ratio = comb_w / max(1e-5, comb_h)
                        ratio_penalty = abs(aspect_ratio - 1.5)

                        dist_to_origin = math.hypot(cx_cand, cy_cand)

                        # Balance compactness, aspect ratio penalty and distance to origin
                        score = perimeter * (1.0 + 0.5 * ratio_penalty) + 0.1 * dist_to_origin

                        if score < best_score:
                            best_score = score
                            best_cx, best_cy = cx_cand, cy_cand

                # Fallback if no valid candidate found (should be extremely rare)
                if best_cx is None:
                    P_xmin = min(bx[0] for bx in P)
                    P_xmax = max(bx[2] for bx in P)
                    P_ymin = min(bx[1] for bx in P)
                    P_ymax = max(bx[3] for bx in P)
                    best_cx = P_xmax + w/2.0 + margin
                    best_cy = (P_ymin + P_ymax) / 2.0

                # Translate and record
                translate_doc(sec_doc, best_cx - fcx, best_cy - fcy)
                B = (best_cx - w/2.0, best_cy - h/2.0, best_cx + w/2.0, best_cy + h/2.0)
                P.append(B)

            # Merge secondary document entities to the target layer
            target_layer = sanitize_layer_name(layer_names[idx] if idx < len(layer_names) else "IMPORTED")

            if target_layer not in primary_doc.layers:
                primary_doc.layers.new(target_layer)

            sec_msp = sec_doc.modelspace()
            file_handles = []
            for ent in sec_msp:
                try:
                    ent.dxf.layer = target_layer
                    primary_msp.add_foreign_entity(ent)
                    file_handles.append(ent.dxf.handle)
                except Exception:
                    pass
            handles_per_file.append(file_handles)
            merged += 1

        primary_doc.saveas(output_path)
        return {"status": "ok", "data": {"merged": merged, "boxes": len(P), "handles_per_file": handles_per_file}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to distribute import: {str(e)}"}


def op_arrange_to_mat(args: Dict[str, Any]) -> Dict[str, Any]:
    """Re-pack the geometry already on the canvas into the cutting mat.

    Groups modelspace entities into discrete pieces by spatial connectivity
    (touching / near boxes are one piece), then places each piece inside
    [0,mat_w]×[0,mat_h] from the bottom-left without rotating or scaling.
    Pieces that don't fit are pushed just outside but kept close. Triggered by
    the "Arrange to mat" button — never automatically, so it's non-destructive
    until the user asks."""
    input_path = args.get("input")
    output_path = args.get("output") or input_path
    mat_w = float(args.get("mat_w", 0) or 0)
    mat_h = float(args.get("mat_h", 0) or 0)
    margin = float(args.get("gap", 20.0) or 20.0)

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"File not found: {input_path}"}
    if mat_w <= 0 or mat_h <= 0:
        return {"status": "error", "message": "Cutting mat has no size."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        ents = list(msp)
        n = len(ents)
        boxes = [_entity_bbox_with_points(e) for e in ents]

        # Union-find clustering of entities whose boxes touch / sit within tol.
        parent = list(range(n))

        def find(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i

        def union(i, j):
            ri, rj = find(i), find(j)
            if ri != rj:
                parent[ri] = rj

        tol = max(margin * 0.5, 2.0)
        idxs = [i for i in range(n) if boxes[i] is not None]
        for a in range(len(idxs)):
            i = idxs[a]
            for b in range(a + 1, len(idxs)):
                j = idxs[b]
                if _boxes_near(boxes[i], boxes[j], tol):
                    union(i, j)

        clusters: Dict[int, list] = {}
        for i in idxs:
            clusters.setdefault(find(i), []).append(i)

        # Largest pieces first — they're the hardest to place.
        cluster_list = []
        for members in clusters.values():
            xs0 = min(boxes[i][0] for i in members)
            ys0 = min(boxes[i][1] for i in members)
            xs1 = max(boxes[i][2] for i in members)
            ys1 = max(boxes[i][3] for i in members)
            cluster_list.append((members, (xs0, ys0, xs1, ys1)))
        cluster_list.sort(
            key=lambda c: (c[1][2] - c[1][0]) * (c[1][3] - c[1][1]), reverse=True)

        placed = []
        moved = 0
        for members, (xs0, ys0, xs1, ys1) in cluster_list:
            w = xs1 - xs0
            h = ys1 - ys0
            best = _best_mat_placement(w, h, placed, mat_w, mat_h, margin)
            if best is None:
                px_max = max((bx[2] for bx in placed), default=mat_w)
                best = (px_max + w / 2.0 + margin, h / 2.0)
            cx, cy = best
            dx = (cx - w / 2.0) - xs0
            dy = (cy - h / 2.0) - ys0
            if abs(dx) > 1e-9 or abs(dy) > 1e-9:
                for i in members:
                    try:
                        ents[i].translate(dx, dy, 0)
                    except Exception:
                        pass
            placed.append((cx - w / 2.0, cy - h / 2.0, cx + w / 2.0, cy + h / 2.0))
            moved += 1

        doc.saveas(output_path)
        return {"status": "ok", "data": {"pieces": moved}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to arrange to mat: {str(e)}"}


def op_scale_all(args: Dict[str, Any]) -> Dict[str, Any]:
    """Uniformly scales EVERY modelspace entity by `factor` about the origin, then
    re-normalises to the positive quadrant. Used by the import unit-correction
    prompt to rescale a freshly-imported drawing to its true size (MAS-148)."""
    input_path = args.get("input")
    output_path = args.get("output")
    try:
        factor = float(args.get("factor", 1.0))
    except Exception:
        factor = 1.0
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    try:
        doc = ezdxf.readfile(input_path)
        scale_doc(doc, factor)
        translate_to_positive_quadrant(doc)
        doc.saveas(output_path)
        b = robust_shape_bounds(doc.modelspace())
        bbox_mm = [b[2] - b[0], b[3] - b[1]] if b else [0.0, 0.0]
        return {"status": "ok", "data": {"factor": factor, "bbox_mm": bbox_mm}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to scale: {str(e)}"}


def op_normalize_dxf(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    doc = ezdxf.readfile(input_path)
    # Report the declared units + raw size so the app can offer a unit-correction
    # prompt (MAS-148). We do NOT silently rescale (see dxf_units_info).
    unit_code, unit_name, unit_factor = dxf_units_info(doc)
    translate_to_positive_quadrant(doc)
    doc.saveas(output_path)
    b = robust_shape_bounds(doc.modelspace())
    bbox_mm = [b[2] - b[0], b[3] - b[1]] if b else [0.0, 0.0]
    return {"status": "ok", "data": {
        "unit_code": unit_code,
        "declared_unit": unit_name,
        "unit_factor": unit_factor,
        "bbox_mm": bbox_mm,
    }}

def op_append_dxf(args: Dict[str, Any]) -> Dict[str, Any]:
    primary_path = args.get("primary")
    secondary_path = args.get("secondary")
    output_path = args.get("output")
    
    if not primary_path or not os.path.exists(primary_path):
        return {"status": "error", "message": f"Primary file not found: {primary_path}"}
    if not secondary_path or not os.path.exists(secondary_path):
        return {"status": "error", "message": f"Secondary file not found: {secondary_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        primary_doc = ezdxf.readfile(primary_path)
        secondary_doc = ezdxf.readfile(secondary_path)
        
        # Translate secondary document to positive quadrant first (starting at 10,10)
        translate_to_positive_quadrant(secondary_doc)
        
        primary_msp = primary_doc.modelspace()
        secondary_msp = secondary_doc.modelspace()
        
        # Copy layers from secondary to primary. In ezdxf, a Layer's attributes
        # live under `.dxf` (there is no bare `.name`/`.color`) — using the wrong
        # accessor crashed every multi-file merge (MAS-13).
        for layer in secondary_doc.layers:
            layer_name = sanitize_layer_name(layer.dxf.name)
            if layer_name not in primary_doc.layers:
                primary_doc.layers.new(layer_name, dxfattribs={"color": layer.dxf.color})

        # Copy entities
        for ent in secondary_msp:
            try:
                ent.dxf.layer = sanitize_layer_name(ent.dxf.layer)
                primary_msp.add_foreign_entity(ent)
            except Exception:
                pass
                
        # Save output
        primary_doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to merge DXF files: {str(e)}"}

# DXF release name → ezdxf acad version code (MAS-156 export options).
_DXF_VERSION_CODES = {
    "R2018": "AC1032", "R2013": "AC1027", "R2010": "AC1024",
    "R2007": "AC1021", "R2004": "AC1018", "R2000": "AC1015",
}


def _strip_excluded_layers(doc, exclude_layers) -> None:
    """Delete every modelspace entity on an excluded layer (e.g. construction
    layers, which must never reach the final cut export)."""
    if not exclude_layers:
        return
    ex = set(exclude_layers)
    msp = doc.modelspace()
    for ent in list(msp):
        try:
            if ent.dxf.layer in ex:
                msp.delete_entity(ent)
        except Exception:
            pass


def op_export_dxf(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles")
    exclude_layers = args.get("exclude_layers")
    version = args.get("version")  # e.g. "R2018"; None keeps the source version.

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    try:
        doc = ezdxf.readfile(input_path)
        _strip_excluded_layers(doc, exclude_layers)
        if handles is not None:
            msp = doc.modelspace()
            for ent in list(msp):
                if ent.dxf.handle not in handles:
                    msp.delete_entity(ent)
        # Optional target DXF release. Downgrading can fail on some content, so
        # fall back to the source version rather than erroring the whole export.
        code = _DXF_VERSION_CODES.get(str(version).upper()) if version else None
        if code:
            try:
                doc.dxfversion = code
            except Exception:
                pass
        try:
            doc.saveas(output_path)
        except Exception:
            # Retry at the document's original version if the requested one
            # couldn't be written.
            doc2 = ezdxf.readfile(input_path)
            if handles is not None:
                m2 = doc2.modelspace()
                for ent in list(m2):
                    if ent.dxf.handle not in handles:
                        m2.delete_entity(ent)
            doc2.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to export DXF: {str(e)}"}

def op_import_svg(args: Dict[str, Any]) -> Dict[str, Any]:
    import xml.etree.ElementTree as ET
    import re
    input_path = args.get("input")
    output_path = args.get("output")
    consolidate = args.get("consolidate", False)
    # SVG fill mode (MAS-146): "strokes" (default, legacy behaviour — everything
    # becomes a stroke) or "preserve" (a shape whose resolved SVG `fill` is a real
    # colour becomes a solid HATCH; stroke-only shapes stay LWPOLYLINEs).
    svg_fill_mode = str(args.get("svg_fill_mode", "strokes")).lower()
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    try:
        tree = ET.parse(input_path)
        root = tree.getroot()
        doc = ezdxf.new(dxfversion="R2010")
        msp = doc.modelspace()

        def element_is_filled(attrib) -> bool:
            """True when this SVG element should import as a fill — only in
            "preserve" mode, and only when `fill` is explicitly a real colour
            (attribute or inline style). Absent fill is treated as stroke so the
            common CAD/outline SVG isn't silently flooded with fills."""
            if svg_fill_mode != "preserve":
                return False
            val = attrib.get('fill')
            if val is None:
                style = attrib.get('style', '') or ''
                m = re.search(r'fill\s*:\s*([^;]+)', style)
                val = m.group(1).strip() if m else None
            if val is None:
                return False
            return val.strip().lower() not in ('none', 'transparent', '')
        def get_local_tag(element):
            tag = element.tag
            if '}' in tag:
                return tag.split('}', 1)[1]
            return tag
        def process_element(elem, current_layer):
            tag = get_local_tag(elem)
            # Recurse into the root <svg> and <g> groups. Previously only <g> was
            # descended into, so SVGs whose shapes are direct children of <svg>
            # (the common case) imported as 0 entities — a blank canvas.
            if tag == 'g' or tag == 'svg':
                layer_name = elem.get('id') or elem.get('{http://www.inkscape.org/namespaces/inkscape}label')
                if layer_name:
                    layer_name = layer_name.replace("layer_", "").strip()
                    if not layer_name:
                        layer_name = current_layer
                else:
                    layer_name = current_layer
                layer_name = sanitize_layer_name(layer_name)
                if layer_name not in doc.layers:
                    doc.layers.new(layer_name)
                for child in elem:
                    process_element(child, layer_name)
                return
            attrib = elem.attrib
            elem_filled = element_is_filled(attrib)
            def add_poly(coords: List[Tuple[float, float]], is_closed: bool, layer: str, filled: bool = False):
                if len(coords) < 2:
                    return
                # A filled closed shape becomes a solid HATCH (MAS-146); a real
                # fill is never collapsed to a centerline ribbon.
                if filled and is_closed and len(coords) >= 3:
                    try:
                        poly = Polygon(coords)
                        if not poly.is_valid:
                            poly = poly.buffer(0)
                        for p in (poly.geoms if isinstance(poly, MultiPolygon) else [poly]):
                            if not p.is_empty:
                                _add_hatch_from_polygon(msp, p, layer, 7)
                        return
                    except Exception:
                        pass  # fall through to a stroke if the fill can't be built
                if consolidate and is_closed:
                    coords = collapse_ribbon_to_centerline(coords)
                    is_closed = False
                msp.add_lwpolyline(coords, dxfattribs={"layer": layer, "closed": is_closed})
            if tag == 'rect':
                x = parse_svg_val(attrib.get('x', 0))
                y = parse_svg_val(attrib.get('y', 0))
                w = parse_svg_val(attrib.get('width', 0))
                h = parse_svg_val(attrib.get('height', 0))
                pts = [(x, -y), (x + w, -y), (x + w, -(y + h)), (x, -(y + h))]
                add_poly(pts, True, current_layer, elem_filled)
            elif tag == 'circle':
                cx = parse_svg_val(attrib.get('cx', 0))
                cy = parse_svg_val(attrib.get('cy', 0))
                r = parse_svg_val(attrib.get('r', 0))
                if elem_filled and r > 0:
                    pts = [(cx + r * math.cos(t), -(cy + r * math.sin(t)))
                           for t in [i * 2 * math.pi / 48 for i in range(48)]]
                    add_poly(pts, True, current_layer, True)
                else:
                    msp.add_circle(center=(cx, -cy), radius=r, dxfattribs={"layer": current_layer})
            elif tag == 'ellipse':
                cx = parse_svg_val(attrib.get('cx', 0))
                cy = parse_svg_val(attrib.get('cy', 0))
                rx = parse_svg_val(attrib.get('rx', 0))
                ry = parse_svg_val(attrib.get('ry', 0))
                pts = []
                for i in range(36):
                    theta = i * (2 * math.pi / 36)
                    pts.append((cx + rx * math.cos(theta), -(cy + ry * math.sin(theta))))
                add_poly(pts, True, current_layer, elem_filled)
            elif tag == 'line':
                x1 = parse_svg_val(attrib.get('x1', 0))
                y1 = parse_svg_val(attrib.get('y1', 0))
                x2 = parse_svg_val(attrib.get('x2', 0))
                y2 = parse_svg_val(attrib.get('y2', 0))
                msp.add_line(start=(x1, -y1), end=(x2, -y2), dxfattribs={"layer": current_layer})
            elif tag == 'polyline':
                pts_str = attrib.get('points', '')
                pts = []
                pts_vals = re.split(r'[ ,]+', pts_str.strip())
                for i in range(0, len(pts_vals) - 1, 2):
                    if pts_vals[i] and pts_vals[i+1]:
                        pts.append((parse_svg_val(pts_vals[i]), -parse_svg_val(pts_vals[i+1])))
                add_poly(pts, False, current_layer)
            elif tag == 'polygon':
                pts_str = attrib.get('points', '')
                pts = []
                pts_vals = re.split(r'[ ,]+', pts_str.strip())
                for i in range(0, len(pts_vals) - 1, 2):
                    if pts_vals[i] and pts_vals[i+1]:
                        pts.append((parse_svg_val(pts_vals[i]), -parse_svg_val(pts_vals[i+1])))
                add_poly(pts, True, current_layer, elem_filled)
            elif tag == 'path':
                d_str = attrib.get('d', '')
                paths_data = parse_svg_d(d_str)
                for subpath in paths_data:
                    inverted_path = [(p[0], -p[1]) for p in subpath]
                    if len(inverted_path) >= 2:
                        is_cl = math.hypot(inverted_path[0][0] - inverted_path[-1][0], inverted_path[0][1] - inverted_path[-1][1]) < 1e-4
                        if is_cl:
                            inverted_path = inverted_path[:-1]
                        add_poly(inverted_path, is_cl, current_layer, elem_filled and is_cl)
        if "ORIGINAL" not in doc.layers:
            doc.layers.new("ORIGINAL")
        process_element(root, "ORIGINAL")

        # Preserve the SVG's real-world dimensions (MAS-148). When the root
        # carries a physical width (mm/cm/in/pt/pc) AND a viewBox, the path
        # coordinates are in viewBox user-units, so scale everything by
        # (physical width in mm) / (viewBox width) to land in true millimetres.
        # Guarded to the well-defined case so unit-less SVGs are unchanged.
        try:
            width_attr = root.get('width')
            vb_attr = root.get('viewBox') or root.get('{http://www.w3.org/2000/svg}viewBox')
            if width_attr and vb_attr and re.search(r'(mm|cm|in|pt|pc)\s*$', str(width_attr).strip(), re.I):
                vb_parts = re.split(r'[ ,]+', str(vb_attr).strip())
                if len(vb_parts) == 4:
                    vb_w = float(vb_parts[2])
                    phys_w_mm = parse_svg_val(width_attr)
                    if vb_w > 1e-6 and phys_w_mm > 1e-6:
                        gscale = phys_w_mm / vb_w
                        if abs(gscale - 1.0) > 1e-4:
                            scale_doc(doc, gscale)
        except Exception:
            pass

        # Import SVGs WITH thickness: every imported stroke is a zero-width
        # centerline, so buffer each into a closed, cuttable outline of the given
        # width. This runs AFTER consolidation, so the pipeline is coherent — a
        # ribbon SVG is first collapsed to its centerline, then re-thickened to a
        # uniform width. Skipped only when thickness is 0/unset (internal callers
        # like distribute/batch pass nothing). Outlines keep each source layer.
        thickness = float(args.get("thickness", 0.0) or 0.0)
        thickened_count = 0
        if thickness > 0:
            imported = list(msp)
            new_handles, consumed, _skipped = _thicken_entities(msp, doc, imported, thickness, None)
            for ent in consumed:
                try:
                    msp.delete_entity(ent)
                except Exception:
                    pass
            thickened_count = len(consumed)

        translate_to_positive_quadrant(doc)
        doc.saveas(output_path)
        return {"status": "ok", "data": {"thickened_count": thickened_count}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to import SVG: {str(e)}"}

def op_add_holes(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    offset_distance = float(args.get("offset_distance", 2.0))
    role_diameter = float(args.get("hole_diameter", 1.0)) # keep compatibility with args key
    hole_diameter = float(args.get("hole_diameter", 1.0))
    hole_spacing = float(args.get("hole_spacing", 4.0))
    pattern = args.get("pattern", "single")
    corner_behavior = args.get("corner_behavior", "skip")
    side = args.get("side", "left")
    row_spacing = float(args.get("row_spacing", 3.0))
    
    enable_variable_spacing = args.get("enable_variable_spacing", True)
    enable_proximity_filter = args.get("enable_proximity_filter", True)
    # Accepted for backward compatibility but no longer used: corner handling is
    # now governed by the real offset curve (join style) and the Keep/Step corner
    # behaviour, which replaced the old per-step normal-interpolation hack.
    _ = args.get("enable_corner_interpolation", True)

    # Distribution mode (MAS-59): "spacing" fills the contour at a fixed pitch;
    # "count" places a fixed number of evenly-spaced holes per contour (the pitch
    # is derived from the contour length, and variable spacing is disabled).
    distribution = args.get("distribution", "spacing")
    hole_count = int(args.get("hole_count", 0) or 0)
    if distribution == "count" and hole_count > 0:
        enable_variable_spacing = False

    # Chisel-step snapping (opt-in): round each contour's interval count to a whole
    # multiple of the iron's prong count so a multi-prong chisel lands cleanly with
    # uniform pitch. Ignored in count mode (exact count wins) and for 1-prong irons.
    snap_to_chisel = bool(args.get("snap_to_chisel", False))
    chisel_prongs = int(args.get("chisel_prongs", 1) or 1)
    snap_to_chisel = snap_to_chisel and chisel_prongs > 1 and not (
        distribution == "count" and hole_count > 0)
    
    # New customizable proximity and variable spacing parameters
    enable_line_proximity_filter = args.get("enable_line_proximity_filter", True)
    line_proximity_threshold = float(args.get("line_proximity_threshold", 1.0))
    proximity_filter_distance = float(args.get("proximity_filter_distance", 3.0))
    variable_spacing_min = float(args.get("variable_spacing_min", 4.0))
    variable_spacing_max = float(args.get("variable_spacing_max", 5.0))

    # MAS-120 Phase 1 — Proximity Avoidance (Keep-Out). Entities tagged as keep-out
    # (hardware, rivets, etc.) create a clearance zone of `avoidance_radius` (C);
    # any stitch hole inside that zone is suppressed (Gap Mode), leaving a clean gap
    # in the stitch line around the obstruction.
    keepout_handles = args.get("keepout_handles", []) or []
    enable_avoidance = bool(args.get("enable_avoidance", False))
    avoidance_radius = float(args.get("avoidance_radius", 3.0))

    # Offset corner treatment: sharp (mitre, the default) keeps crisp corners on
    # the offset stitch line; filleted (round) rounds them. Maps straight to the
    # buffer/offset_curve join style.
    offset_corner_fillet = bool(args.get("offset_corner_fillet", False))
    join_style = "round" if offset_corner_fillet else "mitre"

    # Saddle row distance: the gap between the two staggered rows of a saddle
    # stitch (falls back to the legacy row_spacing when not supplied).
    saddle_spacing = float(args.get("saddle_spacing", row_spacing))

    # Corner holes (on by default): drop a stitch on — or as near as possible to —
    # every corner that turns by more than `corner_angle_threshold` degrees, and
    # flex the pitch between corners (variable distance) so a hole lands on each
    # one. When off, lay a single continuous even-spaced run around the contour.
    # (The old `corner_behavior` Keep/Step arg is now vestigial.)
    corner_holes = bool(args.get("corner_holes", True))
    corner_angle_threshold = float(args.get("corner_angle_threshold", 45.0))
    spacing_target = max(1e-3, hole_spacing)

    # Chain selection (default on): on = merge the selected connected lines into one
    # continuous perimeter chain (holes run across the joints). Off = each selected
    # line is its own open path, so holes land only on the line(s) the user picked.
    chain_selection = bool(args.get("chain_selection", True))
    # Per-end insets (mm): on an OPEN path the first/last hole are held this far in
    # from the start / end. Ignored on closed loops (no endpoints).
    start_inset = max(0.0, float(args.get("start_inset", 0.0) or 0.0))
    end_inset = max(0.0, float(args.get("end_inset", 0.0) or 0.0))
    # End-placement mode: how the run is anchored inside the [start_inset, L-end_inset]
    # window on an OPEN path (ignored on closed loops). "fill" = legacy: first hole at
    # the start inset, march at the target pitch, any remainder falls at the far end.
    # "even" = split the remainder so both end margins are equal (balanced look).
    # "ends" = land a hole exactly on both window ends, flexing the pitch to fit a
    # whole number of gaps between them.
    end_mode = str(args.get("end_mode", "fill")).lower()
    if end_mode not in ("fill", "even", "ends"):
        end_mode = "fill"
    # Edge override(s): when the user clicks one or more edges of a shape with the
    # sewing tool, the app passes each clicked edge's endpoints here. Holes are then
    # placed on just those edges (all the single-line spacing / inset / end_mode /
    # side controls still apply), instead of the whole selected outline. Adjacent
    # selected edges are merged so the stitch lines miter at their shared corner.
    #   segment_overrides : [[[x,y],[x,y]], ...]   (preferred, multi-edge)
    #   segment_override  : [[x,y],[x,y]]          (legacy single edge)
    segment_overrides = args.get("segment_overrides")
    if not segment_overrides and args.get("segment_override"):
        segment_overrides = [args.get("segment_override")]

    # Pricking-iron shape (Pricking Iron Toolbox). Each stitch is emitted as a real,
    # closed cut-path oriented to the local stitch-line tangent + the iron's own
    # angle, so diamond / French / flat slits export to DXF/SVG/laser exactly as the
    # iron would punch them. "round" keeps the legacy drilled circle.
    #   hole_shape : diamond | french | flat | oval | round
    #   slit_length: long axis (mm), along the tangent before the iron angle is added
    #   slit_width : short axis (mm)
    #   slit_angle : iron rotation (deg) relative to the local tangent
    #   inverted   : mirror the slant (flips the sign of slit_angle) — left vs right iron
    hole_shape = str(args.get("hole_shape", "round")).lower()
    if hole_shape not in ("diamond", "french", "flat", "oval", "round"):
        hole_shape = "round"
    slit_length = float(args.get("slit_length", hole_diameter * 1.8))
    slit_width = float(args.get("slit_width", hole_diameter * 0.7))
    slit_angle = float(args.get("slit_angle", 0.0))
    slant_sign = -1.0 if bool(args.get("inverted", False)) else 1.0

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    if "SEWING_HOLES" not in doc.layers:
        doc.layers.new("SEWING_HOLES", dxfattribs={"color": 3})

    targets = []
    if handles:
        for h in handles:
            try:
                targets.append(doc.entitydb[h])
            except KeyError:
                pass
    else:
        targets = [e for e in msp if e.dxftype() in ("LINE", "ARC", "CIRCLE", "LWPOLYLINE", "SPLINE", "ELLIPSE")]

    other_geoms = []
    existing_circles = []
    for ent in msp:
        if ent.dxftype() not in ("LINE", "ARC", "CIRCLE", "LWPOLYLINE", "POLYLINE", "SPLINE", "ELLIPSE"):
            continue
        if ent.dxftype() == "CIRCLE":
            existing_circles.append((ent.dxf.center.x, ent.dxf.center.y, ent.dxf.radius))
        if handles and ent.dxf.handle in handles:
            continue
        try:
            path = make_path(ent)
            vertices = [(p.x, p.y) for p in path.flattening(distance=0.05)]
            if len(vertices) >= 2:
                is_cl = ent.dxftype() == "CIRCLE" or getattr(ent, "closed", False) or getattr(ent, "is_closed", False)
                other_geoms.append(LinearRing(vertices) if is_cl else LineString(vertices))
        except Exception:
            pass

    # Keep-out geometry (MAS-120 Phase 1): build shapely geoms for the tagged
    # handles so holes inside the clearance zone can be removed.
    keepout_geoms = []
    if enable_avoidance and keepout_handles:
        for h in keepout_handles:
            try:
                ent = doc.entitydb[h]
                path_k = make_path(ent)
                verts = [(p.x, p.y) for p in path_k.flattening(distance=0.05)]
                if len(verts) >= 2:
                    is_cl = ent.dxftype() == "CIRCLE" or getattr(ent, "closed", False) or getattr(ent, "is_closed", False)
                    keepout_geoms.append(LinearRing(verts) if is_cl else LineString(verts))
            except Exception:
                pass

    geoms: List[LineString] = []
    for ent in targets:
        try:
            path = make_path(ent)
            # 0.05 mm chord error is well below stitch resolution; the previous
            # 0.01 mm produced tens of thousands of near-collinear vertices for
            # imported curves, and every one of them made the per-step
            # interpolate/distance/project calls below O(N) slower — the root of
            # the multi-minute hang and worker timeout on dense curves (MAS-152).
            vertices = [(p.x, p.y) for p in path.flattening(distance=0.05)]
            if len(vertices) < 2:
                continue
            is_cl = ent.dxftype() == "CIRCLE" or getattr(ent, "closed", False) or getattr(ent, "is_closed", False)
            geoms.append(LinearRing(vertices) if is_cl else LineString(vertices))
        except Exception:
            pass

    if not geoms:
        return {"status": "error", "message": "No valid geometry found to apply sewing holes."}

    paths: List[LineString] = []
    if chain_selection:
        snapped = snap_endpoints(geoms)
        merged = linemerge(snapped)
        if isinstance(merged, MultiLineString):
            paths.extend(merged.geoms)
        elif isinstance(merged, LineString):
            paths.append(merged)
    else:
        # Single-line mode: each selected line is its own path, holes only on it (no
        # snap/merge across joints), so per-end insets apply to the picked line's ends.
        paths.extend(geoms)

    # Clicked edge(s) override the path entirely: place holes on just those edges. The
    # selected entity is still loaded above (so `other_geoms` knows the surrounding
    # shape), but the stitch line is only the picked edge(s). Connected edges are
    # snapped + merged so adjacent ones share a corner — the offset stitch lines then
    # miter to meet at that corner (with a corner hole) instead of overshooting.
    if segment_overrides:
        seg_lines: List[LineString] = []
        for seg in segment_overrides:
            try:
                pts = [(float(p[0]), float(p[1])) for p in seg]
            except (TypeError, ValueError, IndexError):
                continue
            if len(pts) >= 2 and math.hypot(pts[-1][0] - pts[0][0],
                                            pts[-1][1] - pts[0][1]) > 1e-6:
                seg_lines.append(LineString(pts))
        if seg_lines:
            merged = linemerge(snap_endpoints(seg_lines))
            if isinstance(merged, MultiLineString):
                paths = list(merged.geoms)
            elif isinstance(merged, LineString):
                paths = [merged]
            else:
                paths = seg_lines

            # The selected shape's OTHER edges are not in `other_geoms` (its handle is
            # excluded there). Add back only the edges that are FAR from the stitched
            # path so holes near a far side of a narrow shape get filtered out — while
            # skipping edges that touch the stitch path (the adjacent ones that share a
            # corner), so the corner holes survive.
            for g in geoms:
                try:
                    coords = list(g.coords)
                except Exception:
                    continue
                for i in range(len(coords) - 1):
                    edge = LineString([coords[i], coords[i + 1]])
                    if edge.length < 1e-6:
                        continue
                    if min((edge.distance(p) for p in paths), default=1.0) > 0.05:
                        other_geoms.append(edge)

    # Drop redundant near-collinear vertices before the hot loop. Arc length is
    # preserved within 0.03 mm, so hole placement is unchanged, but interpolate /
    # project / distance on the path become far cheaper for dense imported curves.
    simplified_paths: List[LineString] = []
    for p in paths:
        try:
            sp = p.simplify(0.03, preserve_topology=False)
            simplified_paths.append(sp if (sp is not None and not sp.is_empty and len(sp.coords) >= 2) else p)
        except Exception:
            simplified_paths.append(p)
    paths = simplified_paths

    # Prepared polygons for the obstacle ("other") rings, built once. The old code
    # reconstructed Polygon(og) inside the per-candidate collision check — an
    # O(candidates × rings) cost that dominated on busy drawings.
    og_prepared: Dict[int, Any] = {}
    for og in other_geoms:
        if isinstance(og, LinearRing):
            try:
                poly = Polygon(og)
                if not poly.is_valid:
                    poly = poly.buffer(0)
                if not poly.is_empty:
                    og_prepared[id(og)] = prep(poly)
            except Exception:
                pass

    hole_centers: List[Tuple[float, float, float]] = []  # (x, y, tangent_deg)
    hole_radius = hole_diameter / 2.0

    # ---- Obstacle filter -----------------------------------------------------
    # A hole is dropped when it sits on a crossing line (line-proximity filter),
    # within its own radius of any other edge, or inside a closed "other" entity
    # such as a piece of hardware. Geometry that runs *along* the contour is not
    # an obstacle — that is classified per-contour via `og_is_contour` (MAS-106).
    def blocked_by_obstacle(p_pt, og_is_contour) -> bool:
        for og in other_geoms:
            if og_is_contour.get(id(og), False):
                continue
            try:
                d = og.distance(p_pt)
            except Exception:
                continue
            if enable_line_proximity_filter and d < line_proximity_threshold:
                return True
            if d < hole_radius:
                return True
            pp = og_prepared.get(id(og))
            if pp is not None:
                try:
                    if pp.contains(p_pt):
                        return True
                except Exception:
                    pass
        return False

    def _iter_offset_lines(geo) -> List[LineString]:
        """Flatten an offset result (ring / line / multi / polygon) into a list of
        non-empty LineStrings to walk."""
        if geo is None:
            return []
        out: List[LineString] = []
        if isinstance(geo, LinearRing):
            out.append(LineString(geo.coords))
        elif isinstance(geo, LineString):
            out.append(geo)
        elif isinstance(geo, MultiLineString):
            for g in geo.geoms:
                out.append(LineString(g.coords) if isinstance(g, LinearRing) else g)
        else:
            try:
                out.append(LineString(geo.exterior.coords))
            except Exception:
                pass
        return [ln for ln in out if (ln is not None and not ln.is_empty and ln.length > 1e-6)]

    def _even_count(length: float) -> int:
        """Number of stitch intervals along `length` for the active spacing / count
        / variable-spacing settings. Always >= 1 so a short run still gets a hole."""
        if distribution == "count" and hole_count > 0:
            return max(1, hole_count)
        N = max(1, int(round(length / spacing_target)))
        if enable_variable_spacing and N >= 1:
            pitch = length / N
            if pitch < variable_spacing_min and N > 1:
                N = max(1, int(length / variable_spacing_min))
            elif pitch > variable_spacing_max:
                N = int(math.ceil(length / variable_spacing_max))
        if snap_to_chisel:
            # Round the interval count to the nearest whole multiple of the prong
            # count (at least one full chisel). step = length/N then stays uniform.
            N = max(chisel_prongs, int(round(N / chisel_prongs)) * chisel_prongs)
        return max(1, N)

    def sample_offset_line(line: LineString, is_loop: bool, phase: float,
                           corner_pts) -> List[Tuple[float, float]]:
        """Place holes at even arc length along one offset polyline. `phase` (0..1)
        staggers the start by a fraction of the pitch (the second saddle row).

        With corner holes on, a stitch lands on (or as near as possible to) every
        corner: each run between corners is split into the whole number of steps
        whose pitch is nearest the target, so the distance between holes flexes a
        little to put a hole on each corner."""
        L = line.length
        if L < 1e-6:
            return []
        out: List[Tuple[float, float, float]] = []
        # Working window: open paths honour the per-end insets; loops use the whole
        # length (no endpoints). lo/hi/WL are the placement range.
        lo = 0.0 if is_loop else min(max(0.0, start_inset), L)
        hi = L if is_loop else max(lo, L - end_inset)
        WL = hi - lo

        def emit(d: float) -> None:
            """Append one hole at arc-distance `d`, carrying the local tangent angle
            (deg) so shaped slits can be oriented to the stitch line."""
            dd = (d % L) if is_loop else min(L, max(0.0, d))
            pt = line.interpolate(dd)
            eps = min(0.5, max(1e-3, L * 1e-3))
            a_pt = line.interpolate((dd - eps) % L if is_loop else max(0.0, dd - eps))
            b_pt = line.interpolate((dd + eps) % L if is_loop else min(L, dd + eps))
            ang = math.degrees(math.atan2(b_pt.y - a_pt.y, b_pt.x - a_pt.x))
            out.append((pt.x, pt.y, ang))

        # Count mode places EXACTLY hole_count evenly-spaced holes along the whole
        # contour. It deliberately ignores corner snapping (which subdivides the
        # path and would otherwise place hole_count holes *per* corner run — the
        # "Count does nothing / behaves like Fill" bug). The contract is an exact
        # count, so corners don't get a forced stitch here.
        if distribution == "count" and hole_count > 0:
            n = max(1, hole_count)
            if is_loop:
                step = L / n
                for i in range(n):
                    emit((i + phase) * step)
            elif n == 1:
                emit((lo + hi) / 2.0)
            else:
                # Open run: spread n holes end to end within the inset window.
                step = WL / (n - 1)
                for i in range(n):
                    emit(lo + i * step)
            return out

        stops: List[float] = []
        if corner_holes and corner_pts:
            for cx, cy in corner_pts:
                try:
                    s = line.project(ShapelyPoint(cx, cy))
                except Exception:
                    continue
                # On open paths keep only corners inside the inset window.
                if (is_loop and -1e-9 <= s <= L + 1e-9) or (lo - 1e-9 <= s <= hi + 1e-9):
                    stops.append(min(hi, max(lo, s)) if not is_loop else min(L, max(0.0, s)))
            stops = sorted(set(round(s, 5) for s in stops))

        if corner_holes and stops:
            if is_loop:
                runs = [(s, ((stops[(i + 1) % len(stops)] - s) % L) or L)
                        for i, s in enumerate(stops)]
            else:
                edges = sorted(set([lo] + stops + [hi]))
                runs = [(edges[i], edges[i + 1] - edges[i]) for i in range(len(edges) - 1)]
            for a, run in runs:
                if run < 1e-6:
                    continue
                # Variable pitch: nearest whole number of steps to the target so a
                # hole sits on the run's start corner and the rest stay near target.
                # (Count mode never reaches here — it returns an exact count above.)
                n = max(1, int(round(run / spacing_target)))
                for k in range(n):
                    emit(a + run * (k / n))
            if not is_loop:
                emit(hi)
        elif is_loop:
            N = _even_count(L)
            step = L / N
            for i in range(N):
                emit(i * step + phase * step)
        elif end_mode == "ends":
            # Default. Flex the pitch to WL/N so a hole lands exactly on both ends of
            # the window (= legacy behaviour: evenly spread, anchored at each tip).
            N = _even_count(WL)
            step = WL / N
            d = lo + phase * step
            while d <= hi + 1e-6:
                emit(d)
                d += step
        else:
            # Hold the EXACT target pitch (no flex / chisel snap) and lay the run out
            # inside the window. "fill" anchors the first hole at the start inset and
            # lets the remainder fall at the far end; "even" centres the run so both
            # end margins are equal. The saddle second row is staggered by phase*pitch.
            p = spacing_target
            k = max(1, int(math.floor(WL / p + 1e-9)) + 1)   # holes that fit at pitch p
            used = (k - 1) * p
            base = lo + ((WL - used) / 2.0 if end_mode == "even" else 0.0) + phase * p
            for i in range(k):
                d = base + i * p
                if lo - 1e-6 <= d <= hi + 1e-6:
                    emit(d)
        return out

    for path in paths:
        is_closed = path.is_closed or math.hypot(
            path.coords[0][0] - path.coords[-1][0],
            path.coords[0][1] - path.coords[-1][1]) < 0.05

        # Classify each "other" geom for this contour: one that overlaps the
        # contour for a length *is* the contour (skip), one that merely crosses is
        # a real obstacle that filters nearby holes (MAS-106).
        og_is_contour: Dict[int, bool] = {}
        for og in other_geoms:
            try:
                inter = og.intersection(path)
                og_is_contour[id(og)] = bool(getattr(inter, "length", 0.0) > 0.5)
            except Exception:
                try:
                    og_is_contour[id(og)] = og.distance(path) < 0.05
                except Exception:
                    og_is_contour[id(og)] = False

        corner_pts: List[Tuple[float, float]] = []
        if corner_holes:
            try:
                corner_pts = find_corners(list(path.coords), corner_angle_threshold)
            except Exception:
                corner_pts = []

        # Map the panel's side to the offset side. Closed contours: left = inner
        # (inside the shape), right = outer. Open paths keep left / right normals.
        if is_closed:
            side_map = {"left": ["inner"], "inner": ["inner"], "right": ["outer"],
                        "outer": ["outer"], "both": ["inner", "outer"]}.get(side, ["inner"])
        else:
            side_map = {"left": ["left"], "inner": ["left"], "right": ["right"],
                        "outer": ["right"], "both": ["left", "right"]}.get(side, ["left"])

        # Saddle = two staggered rows straddling the offset by saddle_spacing.
        if pattern == "saddle":
            rows = [(offset_distance - saddle_spacing / 2.0, 0.0),
                    (offset_distance + saddle_spacing / 2.0, 0.5)]
        else:
            rows = [(offset_distance, 0.0)]

        for s in side_map:
            for row_off, phase in rows:
                eff_off = max(0.25, abs(row_off))   # never sit on the contour
                geo = get_offset_geometry(path, eff_off, s, join_style=join_style)
                for line in _iter_offset_lines(geo):
                    is_loop = bool(getattr(line, "is_closed", False)) or is_closed
                    for (px, py, pang) in sample_offset_line(line, is_loop, phase, corner_pts):
                        p_pt = ShapelyPoint(px, py)
                        if blocked_by_obstacle(p_pt, og_is_contour):
                            continue
                        if not any(math.hypot(px - hc[0], py - hc[1]) < 0.05
                                   for hc in hole_centers):
                            hole_centers.append((px, py, pang))

    # ---- Proximity merge -----------------------------------------------------
    # Remove holes closer than the proximity distance. A saddle stitch's two rows
    # are deliberately close, so cap the merge distance just under the nearest
    # legitimate neighbour there to avoid eating the pattern.
    # Skip in Count mode: the user asked for an exact number, so merging close
    # neighbours (which would silently drop holes and make a higher Count look
    # identical to a lower one) must not override that.
    count_mode = (distribution == "count" and hole_count > 0)
    if enable_proximity_filter and hole_centers and not count_mode:
        eff_prox = proximity_filter_distance
        if pattern == "saddle":
            nearest_legit = min(spacing_target,
                                math.hypot(saddle_spacing, spacing_target / 2.0))
            eff_prox = min(eff_prox, 0.9 * nearest_legit)
        to_remove = set()
        for i in range(len(hole_centers)):
            if i in to_remove:
                continue
            for j in range(i + 1, len(hole_centers)):
                if j in to_remove:
                    continue
                dd = math.hypot(hole_centers[i][0] - hole_centers[j][0],
                                hole_centers[i][1] - hole_centers[j][1])
                if dd < eff_prox:
                    to_remove.add(j)
        hole_centers = [hole_centers[idx] for idx in range(len(hole_centers))
                        if idx not in to_remove]

    # Drop holes that collide with circles already in the drawing (e.g. rivets).
    if existing_circles:
        filtered_centers = []
        for hc in hole_centers:
            too_close = any(math.hypot(hc[0] - cx, hc[1] - cy) < proximity_filter_distance
                            for cx, cy, r in existing_circles)
            if not too_close:
                filtered_centers.append(hc)
        hole_centers = filtered_centers

    # Keep-out clearance (MAS-120 Phase 1, Gap Mode): drop any hole whose center is
    # within `avoidance_radius` (C) of a keep-out element, or inside a closed one.
    suppressed_by_keepout = 0
    if keepout_geoms:
        kept = []
        for hc in hole_centers:
            p_pt = ShapelyPoint(hc[0], hc[1])
            blocked = False
            for kg in keepout_geoms:
                if kg.distance(p_pt) < avoidance_radius:
                    blocked = True
                    break
                if isinstance(kg, LinearRing):
                    from shapely.geometry import Polygon
                    try:
                        if Polygon(kg).contains(p_pt):
                            blocked = True
                            break
                    except Exception:
                        pass
            if blocked:
                suppressed_by_keepout += 1
            else:
                kept.append(hc)
        hole_centers = kept

    _emit_iron_slits(msp, hole_centers, hole_shape, hole_radius,
                     slit_length, slit_width, slit_angle, slant_sign)

    doc.saveas(output_path)
    return {"status": "ok", "data": {"hole_count": len(hole_centers), "suppressed_by_keepout": suppressed_by_keepout}}


def _slit_local_points(shape: str, slit_length: float, slit_width: float) -> List[Tuple[float, float]]:
    """Vertices of one iron slit in its local frame (u = long axis, v = short axis),
    centred on the origin. Returns a closed ring of (u, v) points. `oval`/`round`
    are emitted as native curve entities elsewhere and never reach here."""
    half_l = max(1e-4, slit_length / 2.0)
    half_w = max(1e-4, slit_width / 2.0)
    if shape == "diamond":
        return [(half_l, 0.0), (0.0, half_w), (-half_l, 0.0), (0.0, -half_w)]
    if shape == "flat":
        return [(half_l, half_w), (-half_l, half_w), (-half_l, -half_w), (half_l, -half_w)]
    if shape == "french":
        # Capsule / stadium: straight flanks + semicircular caps of radius half_w.
        cap = max(0.0, half_l - half_w)
        pts: List[Tuple[float, float]] = []
        steps = 8
        # right cap, sweeping -90°..+90°
        for i in range(steps + 1):
            a = math.radians(-90.0 + 180.0 * i / steps)
            pts.append((cap + half_w * math.cos(a), half_w * math.sin(a)))
        # left cap, sweeping +90°..+270°
        for i in range(steps + 1):
            a = math.radians(90.0 + 180.0 * i / steps)
            pts.append((-cap + half_w * math.cos(a), half_w * math.sin(a)))
        return pts
    # default rectangle
    return [(half_l, half_w), (-half_l, half_w), (-half_l, -half_w), (half_l, -half_w)]


def _emit_iron_slits(msp, hole_centers, shape: str, hole_radius: float,
                     slit_length: float, slit_width: float, slit_angle: float,
                     slant_sign: float) -> None:
    """Stamp every hole as a real, closed cut-path on the SEWING_HOLES layer,
    oriented to the stored local tangent plus the iron's own angle. `round` keeps
    the legacy circle; `oval` is a native ellipse; the rest are closed polylines."""
    attribs = {"layer": "SEWING_HOLES"}
    if shape == "round":
        for cx, cy, _ang in hole_centers:
            msp.add_circle(center=(cx, cy), radius=hole_radius, dxfattribs=attribs)
        return
    if shape == "oval":
        half_l = max(1e-4, slit_length / 2.0)
        ratio = min(1.0, max(1e-3, slit_width / max(1e-4, slit_length)))
        for cx, cy, ang in hole_centers:
            th = math.radians(ang + slit_angle * slant_sign)
            major = (half_l * math.cos(th), half_l * math.sin(th))
            try:
                msp.add_ellipse(center=(cx, cy), major_axis=major, ratio=ratio,
                                dxfattribs=attribs)
            except Exception:
                msp.add_circle(center=(cx, cy), radius=half_l, dxfattribs=attribs)
        return
    local = _slit_local_points(shape, slit_length, slit_width)
    for cx, cy, ang in hole_centers:
        th = math.radians(ang + slit_angle * slant_sign)
        ct, st = math.cos(th), math.sin(th)
        ring = [(cx + u * ct - v * st, cy + u * st + v * ct) for (u, v) in local]
        msp.add_lwpolyline(ring, close=True, dxfattribs=attribs)


_FOLD_LINE_LAYERS = {"FOLD", "FOLDS", "CREASE", "CREASES", "FOLD_LINES"}


def op_edit_fold_line(args: Dict[str, Any]) -> Dict[str, Any]:
    """Repositions or deletes the FOLD-layer LINE that matches `old_seg` (its two
    endpoints, either orientation, within `tol`). With `new_seg` it rewrites the
    endpoints (drag-to-reposition a crease in 3D); without it the line is deleted.
    Matched by geometry so no handle plumbing is needed between 3D and 2D."""
    input_path = args.get("input"); output_path = args.get("output")
    old_seg = args.get("old_seg"); new_seg = args.get("new_seg")
    tol = float(args.get("tol", 1.5))
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not old_seg or len(old_seg) != 2:
        return {"status": "error", "message": "old_seg must be two points."}
    ox0, oy0 = float(old_seg[0][0]), float(old_seg[0][1])
    ox1, oy1 = float(old_seg[1][0]), float(old_seg[1][1])

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    def near(ax, ay, bx, by):
        return math.hypot(ax - bx, ay - by) <= tol

    target = None
    for e in msp.query("LINE"):
        if str(e.dxf.layer).upper() not in _FOLD_LINE_LAYERS:
            continue
        sx, sy = e.dxf.start.x, e.dxf.start.y
        ex, ey = e.dxf.end.x, e.dxf.end.y
        if (near(sx, sy, ox0, oy0) and near(ex, ey, ox1, oy1)) or \
           (near(sx, sy, ox1, oy1) and near(ex, ey, ox0, oy0)):
            target = e
            break
    if target is None:
        return {"status": "error", "message": "No matching fold line found."}

    if new_seg and len(new_seg) == 2:
        target.dxf.start = (float(new_seg[0][0]), float(new_seg[0][1]), 0.0)
        target.dxf.end = (float(new_seg[1][0]), float(new_seg[1][1]), 0.0)
        deleted = False
    else:
        msp.delete_entity(target)
        deleted = True

    doc.saveas(output_path)
    return {"status": "ok", "data": {"edited": True, "deleted": deleted}}


def op_cleanup(args: Dict[str, Any]) -> Dict[str, Any]:
    """Join/cleanup — bridge hanging endpoints with straight lines (MAS-130).

    The previous implementation deleted every line/arc/spline, snapped + linemerged
    them and re-emitted polylines — which destroyed the very geometry the user was
    trying to repair. This rewrite is non-destructive: it leaves all existing
    geometry untouched and simply draws a straight line between pairs of *hanging*
    endpoints that sit within ``tolerance`` of each other (a real gap, not already
    coincident). The bridge line inherits the layer/color of the entity owning one
    of the endpoints, so the join lands on the same layer.
    """
    import math
    input_path = args.get("input")
    output_path = args.get("output")
    tolerance = float(args.get("tolerance", 0.1))
    # Endpoints closer than this are already joined — nothing to bridge.
    eps = max(1e-7, tolerance * 1e-3)

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()
    before_count = len(list(msp))

    # Collect the two terminal endpoints of every open entity. Closed shapes have
    # no hanging endpoints, so they're skipped.
    endpoints = []  # list of (x, y, layer, color)
    for ent in list(msp):
        if ent.dxftype() not in ("LINE", "ARC", "LWPOLYLINE", "POLYLINE", "SPLINE"):
            continue
        try:
            path = make_path(ent)
            verts = [(p.x, p.y) for p in path.flattening(distance=0.05)]
        except Exception:
            continue
        if len(verts) < 2:
            continue
        first, last = verts[0], verts[-1]
        # Closed entity (or one that loops back on itself) — no hanging ends.
        if math.hypot(first[0] - last[0], first[1] - last[1]) <= eps:
            continue
        layer = ent.dxf.layer
        color = getattr(ent.dxf, "color", 256)
        endpoints.append((first[0], first[1], layer, color))
        endpoints.append((last[0], last[1], layer, color))

    # An endpoint is "hanging" if no *other* endpoint is already coincident with
    # it (i.e. it isn't an interior junction of two segments meeting cleanly).
    n = len(endpoints)
    hanging = []
    for i in range(n):
        xi, yi = endpoints[i][0], endpoints[i][1]
        coincident = False
        for j in range(n):
            if j == i:
                continue
            if math.hypot(xi - endpoints[j][0], yi - endpoints[j][1]) <= eps:
                coincident = True
                break
        if not coincident:
            hanging.append(i)

    # Candidate bridges: pairs of hanging endpoints within (eps, tolerance].
    candidates = []
    for a_idx in range(len(hanging)):
        for b_idx in range(a_idx + 1, len(hanging)):
            i, j = hanging[a_idx], hanging[b_idx]
            d = math.hypot(endpoints[i][0] - endpoints[j][0],
                           endpoints[i][1] - endpoints[j][1])
            if eps < d <= tolerance:
                candidates.append((d, i, j))

    # Greedy nearest matching so each hanging endpoint is bridged at most once.
    candidates.sort(key=lambda c: c[0])
    used = set()
    joins_count = 0
    for d, i, j in candidates:
        if i in used or j in used:
            continue
        used.add(i)
        used.add(j)
        a = endpoints[i]
        msp.add_line((a[0], a[1]), (endpoints[j][0], endpoints[j][1]),
                     dxfattribs={"layer": a[2], "color": a[3]})
        joins_count += 1

    doc.saveas(output_path)
    after_count = len(list(msp))

    return {
        "status": "ok",
        "data": {
            "before_count": before_count,
            "after_count": after_count,
            "joins_count": joins_count
        }
    }

def op_export_svg(args: Dict[str, Any]) -> Dict[str, Any]:
    """Converts a DXF layout to SVG format, keeping layer hierarchy and color definitions."""
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles")
    # Export options (MAS-156): coordinate decimal precision and stroke width.
    precision = args.get("precision")
    try:
        precision = int(precision) if precision is not None else None
    except Exception:
        precision = None
    stroke_width = float(args.get("stroke_width", 0.5) or 0.5)

    def _r(v):
        return round(v, precision) if precision is not None else v

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    doc = ezdxf.readfile(input_path)
    _strip_excluded_layers(doc, args.get("exclude_layers"))
    msp = doc.modelspace()

    all_points = []
    layers_data: Dict[str, List[Dict[str, Any]]] = {}

    for ent in msp:
        if ent.dxftype() not in ("LINE", "ARC", "CIRCLE", "LWPOLYLINE", "SPLINE", "ELLIPSE"):
            continue
        if handles is not None and ent.dxf.handle not in handles:
            continue
        try:
            path = make_path(ent)
            pts = [(p.x, p.y) for p in path.flattening(distance=0.05)]
            if not pts:
                continue
            all_points.extend(pts)

            layer_name = ent.dxf.layer
            if layer_name not in layers_data:
                layers_data[layer_name] = []

            is_closed = ent.dxftype() == "CIRCLE" or getattr(ent, "closed", False) or getattr(ent, "is_closed", False)
            layers_data[layer_name].append({
                "type": ent.dxftype(),
                "color": ent.dxf.color,
                "vertices": pts,
                "is_closed": is_closed,
                "center": (ent.dxf.center.x, ent.dxf.center.y) if ent.dxftype() == "CIRCLE" else None,
                "radius": ent.dxf.radius if ent.dxftype() == "CIRCLE" else None
            })
        except Exception:
            pass

    if not all_points:
        # An empty document is a valid state (e.g. a blank canvas or after
        # deleting every entity). Emit a small, valid, empty SVG rather than
        # erroring out so the canvas can render nothing without "freaking out".
        import svgwrite
        empty = svgwrite.Drawing(output_path, size=(100, 100), viewBox="0 0 100 100")
        empty.save()
        return {"status": "ok", "data": {"svg_path": output_path, "empty": True}}

    xs = [p[0] for p in all_points]
    ys = [p[1] for p in all_points]
    minx, maxx = min(xs), max(xs)
    miny, maxy = min(ys), max(ys)

    width = maxx - minx
    height = maxy - miny
    if width <= 0: width = 1.0
    if height <= 0: height = 1.0

    # Padding (5%)
    padding = max(width, height) * 0.05
    minx -= padding
    maxx += padding
    miny -= padding
    maxy += padding
    width = maxx - minx
    height = maxy - miny

    # SVG mapping parameters
    svg_min_x = minx
    svg_min_y = -maxy

    import svgwrite
    dwg = svgwrite.Drawing(output_path, size=(_r(width), _r(height)),
                           viewBox=f"{_r(svg_min_x)} {_r(svg_min_y)} {_r(width)} {_r(height)}")

    used_ids = set()
    for layer_name, entities in layers_data.items():
        try:
            dxf_layer = doc.layers.get(layer_name)
            color_hex = aci_to_hex(dxf_layer.color)
        except Exception:
            color_hex = "#ffffff"

        # Create SVG Group representing the DXF Layer
        # XML ID validation in svgwrite throws ValueError on invalid NCNames (like containing spaces, colons, etc.).
        # Sanitize layer_name to be a valid XML NCName.
        import re
        safe_base = "layer_" + re.sub(r'[^a-zA-Z0-9\-_.]', '_', layer_name)
        # Ensure uniqueness of IDs within the SVG document
        safe_id = safe_base
        counter = 1
        while safe_id in used_ids:
            safe_id = f"{safe_base}_{counter}"
            counter += 1
        used_ids.add(safe_id)

        g = dwg.g(id=safe_id, stroke=color_hex, fill="none", stroke_width=stroke_width)

        for ent in entities:
            if ent["type"] == "CIRCLE":
                cx, cy = ent["center"]
                r = ent["radius"]
                g.add(dwg.circle(center=(_r(cx), _r(-cy)), r=_r(r), stroke=color_hex))
            else:
                pts = ent["vertices"]
                svg_pts = [(_r(p[0]), _r(-p[1])) for p in pts]
                if ent["is_closed"]:
                    g.add(dwg.polygon(points=svg_pts, stroke=color_hex))
                else:
                    g.add(dwg.polyline(points=svg_pts, stroke=color_hex))
        dwg.add(g)

    dwg.save()
    return {"status": "ok", "data": {"svg_path": output_path}}

def op_chain_select(args: Dict[str, Any]) -> Dict[str, Any]:
    """Finds all entity handles geometrically connected to the seed entity (within tolerance)."""
    input_path = args.get("input")
    seed_handle = args.get("seed_handle")
    tolerance = float(args.get("tolerance", 0.1))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not seed_handle:
        return {"status": "error", "message": "Seed handle must be specified."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    # Build segment endpoints/vertices lookup
    entity_points = {}
    for ent in msp:
        if ent.dxftype() not in ("LINE", "ARC", "LWPOLYLINE", "SPLINE", "ELLIPSE"):
            continue
        try:
            if ent.dxftype() in ("LWPOLYLINE", "POLYLINE"):
                pts = [(p[0], p[1]) for p in (ent.get_points() if hasattr(ent, "get_points") else ent.points)]
            else:
                path = make_path(ent)
                pts = [(path.start.x, path.start.y), (path.end.x, path.end.y)]
            entity_points[ent.dxf.handle] = pts
        except Exception:
            try:
                # Fallback for simple line
                if ent.dxftype() == "LINE":
                    entity_points[ent.dxf.handle] = [
                        (ent.dxf.start.x, ent.dxf.start.y),
                        (ent.dxf.end.x, ent.dxf.end.y)
                    ]
            except Exception:
                pass

    if seed_handle not in entity_points:
        return {"status": "ok", "data": {"handles": [seed_handle]}}

    # BFS search to find connected paths
    chain = {seed_handle}
    queue = [seed_handle]

    while queue:
        curr = queue.pop(0)
        curr_pts = entity_points[curr]

        for h, pts in entity_points.items():
            if h in chain:
                continue

            # Check if any point in curr_pts is close to any point in pts
            connected = False
            for cp in curr_pts:
                for p in pts:
                    if math.hypot(cp[0] - p[0], cp[1] - p[1]) < tolerance:
                        connected = True
                        break
                if connected:
                    break

            if connected:
                chain.add(h)
                queue.append(h)

    return {"status": "ok", "data": {"handles": list(chain)}}

def op_export_pdf(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles")
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        import matplotlib.pyplot as plt
        from ezdxf.addons.drawing import RenderContext, Frontend
        from ezdxf.addons.drawing.matplotlib import MatplotlibBackend
        
        doc = ezdxf.readfile(input_path)
        _strip_excluded_layers(doc, args.get("exclude_layers"))
        msp = doc.modelspace()

        if handles is not None:
            for ent in list(msp):
                if ent.dxf.handle not in handles:
                    msp.delete_entity(ent)
        
        fig = plt.figure()
        ax = fig.add_axes([0, 0, 1, 1])
        ax.set_axis_off()
        
        ctx = RenderContext(doc)
        out = MatplotlibBackend(ax)
        Frontend(ctx, out).draw_layout(msp)
        
        fig.savefig(output_path, format="pdf", bbox_inches='tight', pad_inches=0, dpi=300)
        plt.close(fig)
        return {"status": "ok", "data": {"pdf_path": output_path}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to export PDF: {str(e)}"}

def op_import_pdf(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        import pdfplumber
        doc = ezdxf.new(dxfversion="R2010")
        msp = doc.modelspace()
        
        if "ORIGINAL" not in doc.layers:
            doc.layers.new("ORIGINAL")
            
        with pdfplumber.open(input_path) as pdf:
            x_offset = 0.0
            for page in pdf.pages:
                h = page.height
                for line in page.lines:
                    x1 = float(line["x0"]) + x_offset
                    y1 = h - float(line["top"])
                    x2 = float(line["x1"]) + x_offset
                    y2 = h - float(line["bottom"])
                    msp.add_line(start=(x1, y1), end=(x2, y2), dxfattribs={"layer": "ORIGINAL"})
                for rect in page.rects:
                    x0 = float(rect["x0"]) + x_offset
                    y0 = h - float(rect["top"])
                    x1 = float(rect["x1"]) + x_offset
                    y1 = h - float(rect["bottom"])
                    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
                    msp.add_lwpolyline(pts, dxfattribs={"layer": "ORIGINAL", "closed": True})
                for curve in page.curves:
                    if "pts" in curve and curve["pts"]:
                        pts = []
                        for pt in curve["pts"]:
                            pts.append((float(pt[0]) + x_offset, h - float(pt[1])))
                        if len(pts) >= 2:
                            msp.add_lwpolyline(pts, dxfattribs={"layer": "ORIGINAL"})
                    else:
                        x0 = float(curve["x0"]) + x_offset
                        y0 = h - float(curve["top"])
                        x1 = float(curve["x1"]) + x_offset
                        y1 = h - float(curve["bottom"])
                        msp.add_line(start=(x0, y0), end=(x1, y1), dxfattribs={"layer": "ORIGINAL"})
                x_offset += float(page.width) + 50.0
                
        translate_to_positive_quadrant(doc)
        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to import PDF: {str(e)}"}

def op_trace_raster(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    threshold = int(args.get("threshold", 127))
    tolerance = float(args.get("tolerance", 50.0))
    corner_smoothness = float(args.get("corner_smoothness", 50.0))
    path_optimization = float(args.get("path_optimization", 50.0))
    
    turdsize = int(args.get("turdsize", max(0, int((100.0 - tolerance) * 0.25))))
    alphamax = float(args.get("alphamax", (corner_smoothness / 100.0) * 1.3))
    opttolerance = float(args.get("opttolerance", (path_optimization / 100.0) * 1.0))
    
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        from PIL import Image, ImageOps
        import potrace
        import numpy as np
        
        img = Image.open(input_path)
        
        # 1. AI Background removal using rembg if requested
        remove_bg = args.get("remove_background", False)
        if remove_bg:
            try:
                import rembg
                # rembg.remove takes PIL Image and returns RGBA PIL Image
                img = rembg.remove(img)
            except Exception as e:
                import sys
                sys.stderr.write(f"Warning: rembg background removal failed: {str(e)}\n")
        
        # 2. Check if we need to trace in backgroundless/silhouette mode
        is_bgless = args.get("backgroundless", False) or remove_bg
        
        # 3. Process transparency / alpha channel
        if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
            rgba = img.convert("RGBA")
            alpha = rgba.split()[-1]
            
            if is_bgless:
                # Backgroundless mode: non-transparent pixels (alpha > 10) become perfect black (0),
                # transparent pixels become white (255)
                alpha_np = np.array(alpha)
                mask = alpha_np > 10
                img_np = np.where(mask, 0, 255).astype(np.uint8)
                img = Image.fromarray(img_np)
            else:
                # Standard mode: composite onto a white background
                bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
                bg.paste(rgba, mask=alpha)
                img = bg.convert("L")
        else:
            img = img.convert("L")
            
        # 4. Add padding (4 pixels) so that pixels touching the border are fully traced by potrace
        padding = 4
        W_orig = img.width
        H_orig = img.height
        img = ImageOps.expand(img, border=padding, fill=255)
            
        img_np = np.array(img)
        bmp = img_np < threshold
        
        bmp_obj = potrace.Bitmap(bmp)
        path = bmp_obj.trace(turdsize=turdsize, alphamax=alphamax, opttolerance=opttolerance)
        
        doc = ezdxf.new(dxfversion="R2010")
        msp = doc.modelspace()
        if "ORIGINAL" not in doc.layers:
            doc.layers.new("ORIGINAL")
            
        h = H_orig
        for curve in path:
            start_point = curve.start_point
            pts = [(float(start_point.x) - padding, h + padding - float(start_point.y))]
            
            for segment in curve:
                if segment.is_corner:
                    c = segment.c
                    p = segment.end_point
                    pts.append((float(c.x) - padding, h + padding - float(c.y)))
                    pts.append((float(p.x) - padding, h + padding - float(p.y)))
                else:
                    p0 = pts[-1]
                    p1 = (float(segment.c1.x) - padding, h + padding - float(segment.c1.y))
                    p2 = (float(segment.c2.x) - padding, h + padding - float(segment.c2.y))
                    p3 = (float(segment.end_point.x) - padding, h + padding - float(segment.end_point.y))
                    for t in np.linspace(0.1, 1.0, 10):
                        x = (1-t)**3 * p0[0] + 3*(1-t)**2*t * p1[0] + 3*(1-t)*t**2 * p2[0] + t**3 * p3[0]
                        y = (1-t)**3 * p0[1] + 3*(1-t)**2*t * p1[1] + 3*(1-t)*t**2 * p2[1] + t**3 * p3[1]
                        pts.append((x, y))
            
            if len(pts) >= 2:
                # Filter out curves that represent the outer rectangular border frame of the image
                def is_outer_frame(points, width, height, tolerance=5.0):
                    has_bl = any(abs(x) <= tolerance and abs(y) <= tolerance for x, y in points)
                    has_tl = any(abs(x) <= tolerance and abs(y - height) <= tolerance for x, y in points)
                    has_br = any(abs(x - width) <= tolerance and abs(y) <= tolerance for x, y in points)
                    has_tr = any(abs(x - width) <= tolerance and abs(y - height) <= tolerance for x, y in points)
                    return has_bl and has_tl and has_br and has_tr
                
                if is_outer_frame(pts, W_orig, H_orig):
                    continue
                    
                msp.add_lwpolyline(pts, dxfattribs={"layer": "ORIGINAL", "closed": True})
                
        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to trace image: {str(e)}"}

def op_remove_bg_image(args: Dict[str, Any]) -> Dict[str, Any]:
    """Produce a background-removed copy of a raster image (RGBA PNG with a
    transparent background) so the UI can show the user what the removal looks
    like. Uses rembg when available; falls back to a white/near-white chroma key
    so the feature still does something useful without the model (MAS-157)."""
    input_path = args.get("input")
    output_path = args.get("output")
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    try:
        from PIL import Image
        import numpy as np
        img = Image.open(input_path).convert("RGBA")
        used_rembg = False
        try:
            import rembg
            img = rembg.remove(img).convert("RGBA")
            used_rembg = True
        except Exception as e:
            import sys
            sys.stderr.write(f"Warning: rembg unavailable, using chroma fallback: {str(e)}\n")
            # Fallback: knock out near-white border-connected background.
            arr = np.array(img)
            rgb = arr[:, :, :3].astype(np.int32)
            near_white = (rgb[:, :, 0] > 240) & (rgb[:, :, 1] > 240) & (rgb[:, :, 2] > 240)
            arr[near_white, 3] = 0
            img = Image.fromarray(arr, "RGBA")
        img.save(output_path, "PNG")
        return {"status": "ok", "used_rembg": used_rembg}
    except Exception as e:
        return {"status": "error", "message": f"Failed to remove background: {str(e)}"}


def op_commit_trace(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    layer = args.get("layer", "Traced_Vectors")
    entities_data = args.get("entities", [])
    
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        
        # Ensure layer exists
        if layer not in doc.layers:
            doc.layers.new(layer)
            
        for ent in entities_data:
            ent_type = ent.get("type", "LWPOLYLINE")
            if ent_type == "LWPOLYLINE":
                vertices = ent.get("vertices", [])
                closed = ent.get("closed", True)
                if len(vertices) >= 2:
                    msp.add_lwpolyline(vertices, dxfattribs={"layer": layer, "closed": closed})
            
        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to commit trace: {str(e)}"}

def op_translate_entities(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    dx = float(args.get("dx", 0.0))
    dy = float(args.get("dy", 0.0))
    
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        
        for h in handles:
            try:
                ent = doc.entitydb[h]
                if ent.dxftype() == "LINE":
                    ent.dxf.start = (ent.dxf.start.x + dx, ent.dxf.start.y + dy)
                    ent.dxf.end = (ent.dxf.end.x + dx, ent.dxf.end.y + dy)
                elif ent.dxftype() in ("CIRCLE", "ARC"):
                    ent.dxf.center = (ent.dxf.center.x + dx, ent.dxf.center.y + dy)
                elif ent.dxftype() in ("LWPOLYLINE", "POLYLINE"):
                    points = []
                    for p in ent.get_points() if hasattr(ent, 'get_points') else ent.points:
                        pts_list = list(p)
                        pts_list[0] += dx
                        pts_list[1] += dy
                        points.append(tuple(pts_list))
                    if hasattr(ent, 'set_points'):
                        ent.set_points(points)
                    else:
                        ent.points = points
                elif ent.dxftype() in ("SPLINE", "ELLIPSE"):
                    if hasattr(ent, "control_points"):
                        ent.control_points = [(p[0]+dx, p[1]+dy, p[2]) for p in ent.control_points]
                    if hasattr(ent, "fit_points"):
                        ent.fit_points = [(p[0]+dx, p[1]+dy, p[2]) for p in ent.fit_points]
                elif ent.dxftype() == "TEXT":
                    ent.dxf.insert = (ent.dxf.insert.x + dx, ent.dxf.insert.y + dy)
            except KeyError:
                pass
                
        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to translate entities: {str(e)}"}

def op_edit_vertices(args: Dict[str, Any]) -> Dict[str, Any]:
    """Replaces one entity's vertex geometry in place, preserving its handle,
    layer, and (for polylines) closed flag. Used by free endpoint/vertex editing
    of lines and polylines (MAS-62). `vertices` is a list of [x, y]."""
    input_path = args.get("input")
    output_path = args.get("output")
    handle = args.get("handle")
    vertices = args.get("vertices", [])

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handle or len(vertices) < 2:
        return {"status": "error", "message": "A handle and at least two vertices are required."}

    try:
        doc = ezdxf.readfile(input_path)
        ent = doc.entitydb.get(handle)
        if ent is None:
            return {"status": "error", "message": f"Entity {handle} not found."}

        t = ent.dxftype()
        if t == "LINE":
            ent.dxf.start = (float(vertices[0][0]), float(vertices[0][1]))
            ent.dxf.end = (float(vertices[-1][0]), float(vertices[-1][1]))
        elif t in ("LWPOLYLINE", "POLYLINE"):
            pts = [(float(v[0]), float(v[1])) for v in vertices]
            if hasattr(ent, "set_points"):
                ent.set_points(pts, format="xy")  # straight segments (bulges cleared)
            else:
                ent.points = pts
        else:
            return {"status": "error", "message": f"Vertex editing not supported for {t}."}

        doc.saveas(output_path)
        return {"status": "ok", "data": {"handle": handle}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to edit vertices: {str(e)}"}

def _v_unit(v):
    L = math.hypot(v[0], v[1])
    return (v[0] / L, v[1] / L) if L > 1e-9 else (0.0, 0.0)

def _arc_bulge_3pt(A, B, C):
    """Bulge for an LWPOLYLINE arc from A to C passing through B (0 if collinear)."""
    ax, ay = A; bx, by = B; cx, cy = C
    d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if abs(d) < 1e-12:
        return 0.0
    ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / d
    uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / d
    a1 = math.atan2(ay - uy, ax - ux)
    a2 = math.atan2(cy - uy, cx - ux)
    da = a2 - a1
    cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    if cross > 0:
        while da < 0: da += 2 * math.pi
    else:
        while da > 0: da -= 2 * math.pi
    return math.tan(da / 4.0)

def _corner_tangent(P, V, N, kind, value):
    """The tangent setback `t` one corner *wants* along each of its edges, before
    any neighbour clamping: `value/tan(half)` for a fillet, `value` for a chamfer.
    Capped at the mathematical limit — the shorter adjacent edge (the setback
    point can't pass the nearer vertex). Returns (t, half) or (0, 0)."""
    u1 = _v_unit((P[0] - V[0], P[1] - V[1]))
    u2 = _v_unit((N[0] - V[0], N[1] - V[1]))
    dot = max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1]))
    phi = math.acos(dot)
    if phi < 1e-3 or phi > math.pi - 1e-3 or value <= 1e-9:
        return 0.0, 0.0
    half = phi / 2.0
    len1 = math.hypot(P[0] - V[0], P[1] - V[1])
    len2 = math.hypot(N[0] - V[0], N[1] - V[1])
    raw = value if kind == "chamfer" else value / math.tan(half)
    return max(0.0, min(raw, len1, len2)), half


def _corner_blend(P, V, N, kind, t, continuity):
    """Geometry for one corner V between neighbors P and N, given the final
    tangent setback `t` (already resolved against the mathematical limit and any
    adjacent blend — see op_apply_corners). Returns (vertices_with_bulge, snaps).
    (MAS-62, parametric true-arc fillet / biarc G2 / chamfer.)"""
    u1 = _v_unit((P[0] - V[0], P[1] - V[1]))
    u2 = _v_unit((N[0] - V[0], N[1] - V[1]))
    dot = max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1]))
    phi = math.acos(dot)
    if phi < 1e-3 or phi > math.pi - 1e-3 or t <= 1e-9:
        return [], []
    half = phi / 2.0

    if kind == "chamfer":
        T1 = (V[0] + u1[0] * t, V[1] + u1[1] * t)
        T2 = (V[0] + u2[0] * t, V[1] + u2[1] * t)
        mid = ((T1[0] + T2[0]) / 2.0, (T1[1] + T2[1]) / 2.0)
        return [(T1[0], T1[1], 0.0), (T2[0], T2[1], 0.0)], [("tangent", T1), ("center", mid), ("tangent", T2)]

    # Fillet — true circular arc with tangent setback `t`.
    r = t * math.tan(half)
    T1 = (V[0] + u1[0] * t, V[1] + u1[1] * t)
    T2 = (V[0] + u2[0] * t, V[1] + u2[1] * t)
    bis = _v_unit((u1[0] + u2[0], u1[1] + u2[1]))
    cen = (V[0] + bis[0] * (r / math.sin(half)), V[1] + bis[1] * (r / math.sin(half)))
    a1 = math.atan2(T1[1] - cen[1], T1[0] - cen[0])
    a2 = math.atan2(T2[1] - cen[1], T2[0] - cen[0])
    da = a2 - a1
    while da <= -math.pi: da += 2 * math.pi
    while da > math.pi: da -= 2 * math.pi
    midang = a1 + da / 2.0
    mid = (cen[0] + r * math.cos(midang), cen[1] + r * math.sin(midang))
    snaps = [("tangent", T1), ("center", mid), ("tangent", T2)]

    if continuity == "G2":
        # Curvature-eased cubic Bézier, emitted as a short chain of true arcs
        # (biarc) so the outline stays one clean polyline of real curves.
        k = 0.62
        C1 = (T1[0] + (V[0] - T1[0]) * k, T1[1] + (V[1] - T1[1]) * k)
        C2 = (T2[0] + (V[0] - T2[0]) * k, T2[1] + (V[1] - T2[1]) * k)
        seg = 8
        bez = []
        for i in range(seg + 1):
            s = i / seg; mt = 1.0 - s
            bez.append((mt**3 * T1[0] + 3 * mt * mt * s * C1[0] + 3 * mt * s * s * C2[0] + s**3 * T2[0],
                        mt**3 * T1[1] + 3 * mt * mt * s * C1[1] + 3 * mt * s * s * C2[1] + s**3 * T2[1]))
        verts = []
        for j in range(0, seg, 2):
            verts.append((bez[j][0], bez[j][1], _arc_bulge_3pt(bez[j], bez[j + 1], bez[j + 2])))
        verts.append((bez[seg][0], bez[seg][1], 0.0))
        return verts, snaps

    # G1 — single true circular arc.
    return [(T1[0], T1[1], math.tan(da / 4.0)), (T2[0], T2[1], 0.0)], snaps

def op_apply_corners(args: Dict[str, Any]) -> Dict[str, Any]:
    """Regenerates a polyline from a parametric corner spec (MAS-62). The shape
    is defined by a sharp `base` polygon plus per-corner modifiers, so fillets
    and chamfers stay editable and convertible. Emits TRUE arcs (LWPOLYLINE
    bulges) — G1 one arc, G2 a biarc chain, chamfer a straight cut — and returns
    the snap points (each blend: two tangent ends + one center).
    args: handle, base [[x,y]], closed (bool), corners [{index,kind,value,continuity}]."""
    input_path = args.get("input")
    output_path = args.get("output")
    handle = args.get("handle")
    base = args.get("base", [])
    closed = bool(args.get("closed", False))
    corners = args.get("corners", [])

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handle or len(base) < 2:
        return {"status": "error", "message": "A handle and a base polygon are required."}

    try:
        doc = ezdxf.readfile(input_path)
        ent = doc.entitydb.get(handle)
        if ent is None or ent.dxftype() not in ("LWPOLYLINE", "POLYLINE"):
            return {"status": "error", "message": "Parametric corners require a polyline."}

        base = [(float(p[0]), float(p[1])) for p in base]
        n = len(base)
        cmap = {int(c["index"]): c for c in corners if "index" in c}

        def neighbors(i):
            if closed and n > 2:
                return base[(i - 1) % n], base[(i + 1) % n]
            if 0 < i < n - 1:
                return base[i - 1], base[i + 1]
            return None

        # Desired tangent each corner wants (capped at its own mathematical limit).
        dt = [0.0] * n
        kinds = [None] * n
        for i in range(n):
            spec = cmap.get(i)
            if spec is None or float(spec.get("value", 0.0)) <= 1e-9:
                continue
            nb = neighbors(i)
            if nb is None:
                continue
            t, _ = _corner_tangent(nb[0], base[i], nb[1],
                                   spec.get("kind", "fillet"), float(spec["value"]))
            dt[i] = t
            kinds[i] = spec.get("kind", "fillet")

        # Resolve adjacent fillets sharing an edge. A lone fillet (its neighbour
        # on that edge is sharp) keeps the full mathematical maximum — it can run
        # right up to the far vertex. But two fillets that would *touch* on a
        # shared edge each stop at the edge midpoint, so they meet halfway rather
        # than the larger one swallowing the edge. The min() accumulates across a
        # corner's two edges, so the tighter neighbour wins.
        edges = [(i, (i + 1) % n) for i in range(n)] if (closed and n > 2) else [(i, i + 1) for i in range(n - 1)]
        for _ in range(2):
            for a, b in edges:
                if dt[a] <= 1e-9 or dt[b] <= 1e-9:
                    continue  # only one fillet on this edge → mathematical max stands
                L = math.hypot(base[a][0] - base[b][0], base[a][1] - base[b][1])
                if dt[a] + dt[b] > L + 1e-9:
                    half = L / 2.0
                    dt[a] = min(dt[a], half)
                    dt[b] = min(dt[b], half)

        out = []           # (x, y, bulge)
        snaps = []         # {x, y, role}
        for i in range(n):
            if dt[i] > 1e-9:
                nb = neighbors(i)
                spec = cmap.get(i, {})
                verts, csnaps = _corner_blend(nb[0], base[i], nb[1],
                                              kinds[i] or "fillet", dt[i],
                                              spec.get("continuity", "G1"))
                if verts:
                    out.extend(verts)
                    for role, pt in csnaps:
                        snaps.append({"x": pt[0], "y": pt[1], "role": role})
                    continue
            out.append((base[i][0], base[i][1], 0.0))
            snaps.append({"x": base[i][0], "y": base[i][1], "role": "corner"})

        ent.set_points([(p[0], p[1], p[2]) for p in out], format="xyb")
        if hasattr(ent, "closed"):
            ent.closed = closed
        doc.saveas(output_path)
        return {"status": "ok", "data": {"handle": handle, "snaps": snaps, "vertex_count": len(out)}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to apply corners: {str(e)}"}

def op_add_dashed_creases(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    p1 = args.get("p1")
    p2 = args.get("p2")
    layer = args.get("layer", "CREASES")
    
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        
        if "DASHED" not in doc.linetypes:
            doc.linetypes.new("DASHED", dxfattribs={
                "description": "Dashed crease line",
                "pattern": [2.0, -1.0]
            })
            
        if layer not in doc.layers:
            doc.layers.new(layer, dxfattribs={"color": 5})
            
        new_handles = []
        if p1 and p2:
            line = msp.add_line(start=(float(p1[0]), float(p1[1])), end=(float(p2[0]), float(p2[1])), dxfattribs={"layer": layer, "linetype": "DASHED"})
            new_handles.append(line.dxf.handle)
            
        for h in handles:
            try:
                ent = doc.entitydb[h]
                ent.dxf.layer = layer
                ent.dxf.linetype = "DASHED"
                new_handles.append(h)
            except KeyError:
                pass
                
        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_entities": new_handles}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to add dashed creases: {str(e)}"}

def op_add_glue_tabs(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    height = float(args.get("height", 8.0))
    tab_type = args.get("type", "trapezoid")
    side = args.get("side", "left")
    start_offset = float(args.get("start_offset", 0.0))
    end_offset = float(args.get("end_offset", 0.0))
    layer = args.get("layer", "GLUE_TABS")
    
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handles:
        return {"status": "error", "message": "Please select line segments to add glue tabs to."}
        
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        
        if layer not in doc.layers:
            doc.layers.new(layer, dxfattribs={"color": 4})
            
        new_handles = []
        for h in handles:
            try:
                ent = doc.entitydb[h]
                if ent.dxftype() != "LINE":
                    continue
                    
                p1 = (ent.dxf.start.x, ent.dxf.start.y)
                p2 = (ent.dxf.end.x, ent.dxf.end.y)
                
                dx = p2[0] - p1[0]
                dy = p2[1] - p1[1]
                L = math.hypot(dx, dy)
                if L < 1e-3:
                    continue
                    
                ux = dx / L
                uy = dy / L
                
                # Swap side to correct left/right flipping
                if side == "left":
                    nx = uy
                    ny = -ux
                else:
                    nx = -uy
                    ny = ux
                    
                if start_offset + end_offset >= L:
                    continue
                    
                p1_tab = (p1[0] + start_offset * ux, p1[1] + start_offset * uy)
                p2_tab = (p2[0] - end_offset * ux, p2[1] - end_offset * uy)
                L_tab = L - start_offset - end_offset
                
                tab_pts = [p1_tab]
                
                if tab_type == "triangle":
                    mid_x = (p1_tab[0] + p2_tab[0]) / 2.0
                    mid_y = (p1_tab[1] + p2_tab[1]) / 2.0
                    peak = (mid_x + height * nx, mid_y + height * ny)
                    tab_pts.append(peak)
                else:
                    h_offset = min(height, L_tab / 2.1)
                    t1 = (p1_tab[0] + h_offset * ux + height * nx, p1_tab[1] + h_offset * uy + height * ny)
                    t2 = (p2_tab[0] - h_offset * ux + height * nx, p2_tab[1] - h_offset * uy + height * ny)
                    tab_pts.append(t1)
                    tab_pts.append(t2)
                    
                tab_pts.append(p2_tab)
                
                new_ent = msp.add_lwpolyline(tab_pts, dxfattribs={"layer": layer})
                new_handles.append(new_ent.dxf.handle)
            except KeyError:
                pass
                
        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_entities": new_handles}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to add glue tabs: {str(e)}"}

def op_pattern_grid(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    cols = int(args.get("columns", 2))
    rows = int(args.get("rows", 2))
    dx = float(args.get("col_spacing", 20.0))
    dy = float(args.get("row_spacing", 20.0))
    layer = args.get("layer", "PATTERN")
    
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handles:
        return {"status": "error", "message": "Please select entities to pattern."}
        
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        
        if layer not in doc.layers:
            doc.layers.new(layer, dxfattribs={"color": 2})
            
        new_handles = []
        for c in range(cols):
            for r in range(rows):
                if c == 0 and r == 0:
                    continue
                    
                shift_x = c * dx
                shift_y = r * dy
                
                for h in handles:
                    try:
                        ent = doc.entitydb[h]
                        new_ent = ent.copy()
                        if new_ent.dxftype() == "LINE":
                            new_ent.dxf.start = (new_ent.dxf.start.x + shift_x, new_ent.dxf.start.y + shift_y)
                            new_ent.dxf.end = (new_ent.dxf.end.x + shift_x, new_ent.dxf.end.y + shift_y)
                        elif new_ent.dxftype() in ("CIRCLE", "ARC"):
                            new_ent.dxf.center = (new_ent.dxf.center.x + shift_x, new_ent.dxf.center.y + shift_y)
                        elif new_ent.dxftype() in ("LWPOLYLINE", "POLYLINE"):
                            points = []
                            for p in new_ent.get_points() if hasattr(new_ent, 'get_points') else new_ent.points:
                                pts_list = list(p)
                                pts_list[0] += shift_x
                                pts_list[1] += shift_y
                                points.append(tuple(pts_list))
                            if hasattr(new_ent, 'set_points'):
                                new_ent.set_points(points)
                            else:
                                new_ent.points = points
                        elif new_ent.dxftype() in ("SPLINE", "ELLIPSE"):
                            if hasattr(new_ent, "control_points"):
                                new_ent.control_points = [(p[0]+shift_x, p[1]+shift_y, p[2]) for p in new_ent.control_points]
                            if hasattr(new_ent, "fit_points"):
                                new_ent.fit_points = [(p[0]+shift_x, p[1]+shift_y, p[2]) for p in new_ent.fit_points]
                                
                        new_ent.dxf.layer = layer
                        msp.add_entity(new_ent)
                        new_handles.append(new_ent.dxf.handle)
                    except KeyError:
                        pass
                        
        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_entities": new_handles}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to pattern grid: {str(e)}"}


def op_pattern_circular(args: Dict[str, Any]) -> Dict[str, Any]:
    """Circular pattern (MAS-113): copy the selection `count` times around a pivot
    (cx, cy), evenly spread over `total_angle` degrees. Copies inherit each source
    entity's own layer so they're first-class geometry. `suppress` is a list of
    instance indices (1-based, excluding the original) to skip."""
    import math
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    count = max(2, int(args.get("count", 6)))
    cx = float(args.get("cx", 0.0))
    cy = float(args.get("cy", 0.0))
    total_angle = float(args.get("total_angle", 360.0))
    suppress = set(int(i) for i in args.get("suppress", []))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handles:
        return {"status": "error", "message": "Please select entities to pattern."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        # A full 360° sweep shouldn't duplicate the start/end instance.
        full = abs(total_angle % 360.0) < 1e-6 and abs(total_angle) >= 1e-6
        denom = count if full else max(1, count - 1)
        step = math.radians(total_angle / denom)

        new_handles = []
        for i in range(1, count):
            if i in suppress:
                continue
            ang = step * i
            m = (Matrix44.translate(-cx, -cy, 0.0)
                 @ Matrix44.z_rotate(ang)
                 @ Matrix44.translate(cx, cy, 0.0))
            for h in handles:
                try:
                    ent = doc.entitydb[h]
                    new_ent = ent.copy()
                    new_ent.transform(m)
                    msp.add_entity(new_ent)
                    new_handles.append(new_ent.dxf.handle)
                except KeyError:
                    pass
        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_entities": new_handles}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to pattern circular: {str(e)}"}

def op_pattern_path(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    path_handle = args.get("path_handle")
    spacing = float(args.get("spacing", 10.0))
    layer = args.get("layer", "PATTERN")
    
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handles:
        return {"status": "error", "message": "Please select entities to duplicate."}
    if not path_handle:
        return {"status": "error", "message": "Please select a path entity."}
        
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        
        try:
            path_ent = doc.entitydb[path_handle]
        except KeyError:
            return {"status": "error", "message": f"Path entity {path_handle} not found."}
            
        path_dxf = make_path(path_ent)
        path_vertices = [(p.x, p.y) for p in path_dxf.flattening(distance=0.05)]
        if len(path_vertices) < 2:
            return {"status": "error", "message": "Guide path is too short or invalid."}
            
        guide_line = LineString(path_vertices)
        total_length = guide_line.length
        
        all_pts = []
        for h in handles:
            try:
                ent = doc.entitydb[h]
                ent_path = make_path(ent)
                all_pts.extend([(p.x, p.y) for p in ent_path.flattening(distance=0.1)])
            except Exception:
                pass
                
        if not all_pts:
            return {"status": "error", "message": "No points found in target shapes."}
            
        cx = sum(p[0] for p in all_pts) / len(all_pts)
        cy = sum(p[1] for p in all_pts) / len(all_pts)
        
        num_instances = max(1, int(total_length // spacing))
        offsets = [i * spacing for i in range(num_instances + 1)]
        if guide_line.is_closed:
            offsets = offsets[:-1]
            
        if not offsets:
            offsets = [total_length / 2.0]
            
        new_handles = []
        for offset in offsets:
            pt = guide_line.interpolate(offset)
            eps = 0.01
            if offset + eps <= total_length:
                pt_f = guide_line.interpolate(offset + eps)
                theta = math.atan2(pt_f.y - pt.y, pt_f.x - pt.x)
            else:
                pt_b = guide_line.interpolate(offset - eps)
                theta = math.atan2(pt.y - pt_b.y, pt.x - pt_b.x)
                
            for h in handles:
                try:
                    ent = doc.entitydb[h]
                    new_ent = ent.copy()
                    
                    def transform_point(x: float, y: float) -> Tuple[float, float]:
                        tx = x - cx
                        ty = y - cy
                        rx = tx * math.cos(theta) - ty * math.sin(theta)
                        ry = tx * math.sin(theta) + ty * math.cos(theta)
                        return (rx + pt.x, ry + pt.y)
                        
                    if new_ent.dxftype() == "LINE":
                        new_ent.dxf.start = transform_point(new_ent.dxf.start.x, new_ent.dxf.start.y)
                        new_ent.dxf.end = transform_point(new_ent.dxf.end.x, new_ent.dxf.end.y)
                    elif new_ent.dxftype() in ("CIRCLE", "ARC"):
                        new_ent.dxf.center = transform_point(new_ent.dxf.center.x, new_ent.dxf.center.y)
                    elif new_ent.dxftype() in ("LWPOLYLINE", "POLYLINE"):
                        points = []
                        for p in new_ent.get_points() if hasattr(new_ent, 'get_points') else new_ent.points:
                            pts_list = list(p)
                            trans_xy = transform_point(pts_list[0], pts_list[1])
                            pts_list[0] = trans_xy[0]
                            pts_list[1] = trans_xy[1]
                            points.append(tuple(pts_list))
                        if hasattr(new_ent, 'set_points'):
                            new_ent.set_points(points)
                        else:
                            new_ent.points = points
                    elif new_ent.dxftype() in ("SPLINE", "ELLIPSE"):
                        if hasattr(new_ent, "control_points"):
                            new_ent.control_points = [transform_point(p[0], p[1]) + (p[2],) for p in new_ent.control_points]
                        if hasattr(new_ent, "fit_points"):
                            new_ent.fit_points = [transform_point(p[0], p[1]) + (p[2],) for p in new_ent.fit_points]
                            
                    new_ent.dxf.layer = layer
                    msp.add_entity(new_ent)
                    new_handles.append(new_ent.dxf.handle)
                except KeyError:
                    pass
                    
        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_entities": new_handles}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to pattern along path: {str(e)}"}

def op_add_text(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    text = args.get("text", "Sample Text")
    insert = args.get("insert", [0.0, 0.0])
    height = float(args.get("height", 5.0))
    layer = args.get("layer", "TEXT")
    handle = args.get("handle")
    font = args.get("font", "") or ""
    bold = bool(args.get("bold", False))
    italic = bool(args.get("italic", False))
    underline = bool(args.get("underline", False))
    char_spacing = float(args.get("char_spacing", 0.0) or 0.0)
    width_factor = float(args.get("width_factor", 1.0) or 1.0)
    has_style = bool(font or bold or italic or underline or char_spacing or ("\n" in text))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()

        if layer not in doc.layers:
            doc.layers.new(layer, dxfattribs={"color": 7})

        # DXF TEXT is single-line; flatten newlines for the native value while the
        # true multi-line content is preserved in XDATA (read back on load).
        flat = text.replace("\n", " ")
        txt_ent = msp.add_text(flat, dxfattribs={"height": height, "layer": layer})
        txt_ent.dxf.insert = (float(insert[0]), float(insert[1]))
        if abs(width_factor - 1.0) > 1e-6:
            txt_ent.dxf.width = width_factor
        if has_style:
            _set_text_xdata(txt_ent, doc, font=font, bold=bold, italic=italic,
                            underline=underline, char_spacing=char_spacing, text=text)

        if handle:
            old_handle = txt_ent.dxf.handle
            if old_handle in doc.entitydb:
                del doc.entitydb[old_handle]
            txt_ent.dxf.handle = handle
            doc.entitydb[handle] = txt_ent
        
        doc.saveas(output_path)
        return {"status": "ok", "data": {"handle": txt_ent.dxf.handle}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to add text: {str(e)}"}

def op_update_text(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handle = args.get("handle")
    text = args.get("text", "")
    height = args.get("height")
    font = args.get("font", "") or ""
    bold = bool(args.get("bold", False))
    italic = bool(args.get("italic", False))
    underline = bool(args.get("underline", False))
    char_spacing = float(args.get("char_spacing", 0.0) or 0.0)
    has_style = bool(font or bold or italic or underline or char_spacing or ("\n" in text))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handle:
        return {"status": "error", "message": "Handle must be specified."}

    try:
        doc = ezdxf.readfile(input_path)
        ent = doc.entitydb.get(handle)
        if ent and ent.dxftype() == "TEXT":
            ent.dxf.text = text.replace("\n", " ")
            if height is not None:
                ent.dxf.height = float(height)
            if args.get("width_factor") is not None:
                ent.dxf.width = float(args.get("width_factor") or 1.0)
            if has_style:
                _set_text_xdata(ent, doc, font=font, bold=bold, italic=italic,
                                underline=underline, char_spacing=char_spacing, text=text)
            elif _get_text_xdata(ent):
                # Styling was cleared back to plain — drop the stale XDATA.
                try:
                    ent.discard_xdata(PATHSTITCH_APPID)
                except Exception:
                    pass
            doc.saveas(output_path)
            return {"status": "ok", "data": {"handle": handle}}
        else:
            return {"status": "error", "message": f"Text entity with handle {handle} not found."}
    except Exception as e:
        return {"status": "error", "message": f"Failed to update text: {str(e)}"}

def op_delete_entities(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        for h in handles:
            try:
                ent = doc.entitydb[h]
                msp.delete_entity(ent)
            except KeyError:
                pass
        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to delete entities: {str(e)}"}

def op_new_dxf(args: Dict[str, Any]) -> Dict[str, Any]:
    """Creates a fresh, empty DXF document.

    Used to materialise a valid blank working buffer so that a new/cleared
    canvas is a first-class state every downstream op can read without error.
    """
    output_path = args.get("output")
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    try:
        doc = ezdxf.new(dxfversion="R2010")
        # Pre-create the default working layer so the very first sketch lands
        # somewhere predictable even before any edit op runs.
        if "ORIGINAL" not in doc.layers:
            doc.layers.new("ORIGINAL", dxfattribs={"color": 7})
        doc.saveas(output_path)
        return {"status": "ok", "data": {"output": output_path}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to create new DXF: {str(e)}"}


def op_rotate_entities(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    angle = float(args.get("angle", 0.0))
    center = args.get("center", [0.0, 0.0])
    
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        
        cx, cy = float(center[0]), float(center[1])
        angle_rad = math.radians(angle)
        
        m = Matrix44.translate(-cx, -cy, 0.0) @ Matrix44.z_rotate(angle_rad) @ Matrix44.translate(cx, cy, 0.0)
        
        db = doc.entitydb
        for h in handles:
            if h in db:
                entity = db[h]
                entity.transform(m)
                
        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to rotate entities: {str(e)}"}


def op_reflect_entities(args: Dict[str, Any]) -> Dict[str, Any]:
    """Flips the selected entities about their own bounding-box center.

    axis="horizontal" mirrors left/right (negates X about the center);
    axis="vertical" mirrors top/bottom (negates Y about the center).
    """
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    axis = str(args.get("axis", "horizontal")).lower()

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handles:
        return {"status": "error", "message": "No entities selected to reflect."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        db = doc.entitydb

        # Combined bounding box of the selected entities (in WCS) so the flip
        # happens about the selection's own center, in place.
        min_x = min_y = float("inf")
        max_x = max_y = float("-inf")
        targets = []
        for h in handles:
            if h not in db:
                continue
            entity = db[h]
            targets.append(entity)
            try:
                p = make_path(entity)
                for v in p.flattening(distance=0.1):
                    min_x = min(min_x, v.x); max_x = max(max_x, v.x)
                    min_y = min(min_y, v.y); max_y = max(max_y, v.y)
            except Exception:
                # Fall back to any explicit start/end points the entity exposes.
                for attr in ("start", "end", "center"):
                    pt = getattr(entity.dxf, attr, None)
                    if pt is not None:
                        min_x = min(min_x, pt.x); max_x = max(max_x, pt.x)
                        min_y = min(min_y, pt.y); max_y = max(max_y, pt.y)

        if not targets:
            return {"status": "error", "message": "Selected handles were not found in the document."}
        if min_x == float("inf"):
            return {"status": "error", "message": "Could not determine geometry bounds for the selection."}

        cx = (min_x + max_x) / 2.0
        cy = (min_y + max_y) / 2.0
        horizontal = axis == "horizontal"

        def reflect_pt(x: float, y: float) -> Tuple[float, float]:
            return (2.0 * cx - x, y) if horizontal else (x, 2.0 * cy - y)

        def wcs_center(entity):
            # CIRCLE/ARC store the center in OCS; only convert when the
            # extrusion isn't the default +Z (Pathstitch geometry normally is).
            c = entity.dxf.center
            ext = tuple(round(v, 9) for v in entity.dxf.extrusion)
            if ext != (0.0, 0.0, 1.0):
                c = entity.ocs().to_wcs(c)
            return c

        sx, sy = (-1.0, 1.0) if horizontal else (1.0, -1.0)
        m = (Matrix44.translate(-cx, -cy, 0.0)
             @ Matrix44.scale(sx, sy, 1.0)
             @ Matrix44.translate(cx, cy, 0.0))

        for entity in targets:
            et = entity.dxftype()
            # A reflection is an improper transform, so ezdxf's entity.transform
            # flips the OCS extrusion to -Z for CIRCLE/ARC. The canvas parser
            # reads their raw center/angles and ignores the extrusion, which
            # would place a flipped circle/arc at the mirrored-OCS position.
            # Reflect those explicitly in WCS and keep a canonical +Z extrusion.
            if et == "CIRCLE":
                c = wcs_center(entity)
                nx, ny = reflect_pt(c.x, c.y)
                entity.dxf.extrusion = (0.0, 0.0, 1.0)
                entity.dxf.center = (nx, ny, 0.0)
            elif et == "ARC":
                c = wcs_center(entity)
                ncx, ncy = reflect_pt(c.x, c.y)
                # Reflecting reverses the CCW sweep, so the new arc runs CCW
                # from the reflected old end-point to the reflected old start.
                rs = reflect_pt(entity.start_point.x, entity.start_point.y)
                re = reflect_pt(entity.end_point.x, entity.end_point.y)
                new_start = math.degrees(math.atan2(re[1] - ncy, re[0] - ncx)) % 360.0
                new_end = math.degrees(math.atan2(rs[1] - ncy, rs[0] - ncx)) % 360.0
                entity.dxf.extrusion = (0.0, 0.0, 1.0)
                entity.dxf.center = (ncx, ncy, 0.0)
                entity.dxf.start_angle = new_start
                entity.dxf.end_angle = new_end
            else:
                entity.transform(m)

        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to reflect entities: {str(e)}"}


# Module-level dispatch table so both the CLI (`main`) and the persistent
# worker (`pathstitch_core.worker`) share one source of truth for op routing.
def op_add_construction_lines(args: Dict[str, Any]) -> Dict[str, Any]:
    """Adds the app's measurement/ruler segments as dashed lines on a dedicated
    CONSTRUCTION layer, with no dimension text — for opt-in export (§6)."""
    input_path = args.get("input")
    output_path = args.get("output")
    segments = args.get("segments", [])
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        if "CONSTRUCTION" not in doc.layers:
            doc.layers.new("CONSTRUCTION", dxfattribs={"color": 8})
        if "DASHED" not in doc.linetypes:
            try:
                doc.linetypes.add("DASHED", pattern=[0.6, 0.4, -0.2], description="Dashed _ _ _")
            except Exception:
                pass
        added = 0
        for seg in segments:
            if len(seg) >= 4:
                msp.add_line(
                    (float(seg[0]), float(seg[1])),
                    (float(seg[2]), float(seg[3])),
                    dxfattribs={"layer": "CONSTRUCTION", "linetype": "DASHED"},
                )
                added += 1
        doc.saveas(output_path)
        return {"status": "ok", "data": {"added": added}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to add construction lines: {str(e)}"}


def op_convert_lines(args: Dict[str, Any]) -> Dict[str, Any]:
    """Replaces straight segments with real styled geometry (MAS-58).

    `segments` is a list of polylines (each a list of [x, y] points). The source
    entities named in `delete_handles` are removed and the generated geometry is
    added on `layer`. Styles: dashed, dotted, zigzag, wave, striped, square,
    triangle. `settings` holds per-style parameters (sensible defaults applied).
    Generating real geometry guarantees the style survives DXF/SVG/PDF export.
    """
    import math
    input_path = args.get("input")
    output_path = args.get("output")
    delete_handles = args.get("delete_handles", [])
    segments = args.get("segments", [])
    style = args.get("style", "dashed")
    settings = args.get("settings", {}) or {}
    layer = args.get("layer", "0")

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    def f(key, default):
        try:
            return float(settings.get(key, default))
        except (TypeError, ValueError):
            return default

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        if layer and layer not in doc.layers:
            try:
                doc.layers.new(layer)
            except Exception:
                pass
        attribs = {"layer": layer}
        new_handles = []

        def add_line(a, b):
            e = msp.add_line(a, b, dxfattribs=attribs)
            new_handles.append(e.dxf.handle)

        def add_circle(c, r):
            e = msp.add_circle(c, r, dxfattribs=attribs)
            new_handles.append(e.dxf.handle)

        def add_poly(pts, closed=False):
            e = msp.add_lwpolyline(pts, close=closed, dxfattribs=attribs)
            new_handles.append(e.dxf.handle)

        # Iterate each consecutive point pair of each input polyline.
        for poly in segments:
            for i in range(len(poly) - 1):
                x1, y1 = poly[i][0], poly[i][1]
                x2, y2 = poly[i + 1][0], poly[i + 1][1]
                dx, dy = x2 - x1, y2 - y1
                L = math.hypot(dx, dy)
                if L < 1e-9:
                    continue
                ux, uy = dx / L, dy / L          # unit direction
                px, py = -uy, ux                 # unit perpendicular

                def at(t):
                    return (x1 + ux * t, y1 + uy * t)

                if style == "dashed":
                    dash = max(0.1, f("dash_length", 4.0))
                    gap = max(0.1, f("gap", 3.0))
                    t = 0.0
                    while t < L:
                        add_line(at(t), at(min(t + dash, L)))
                        t += dash + gap

                elif style == "dotted":
                    spacing = max(0.2, f("spacing", 3.0))
                    r = max(0.05, f("dot_radius", 0.5))
                    n = max(1, int(round(L / spacing)))
                    for k in range(n + 1):
                        add_circle(at(L * k / n), r)

                elif style == "square":
                    spacing = max(0.3, f("spacing", 4.0))
                    s = max(0.1, f("size", 1.5)) / 2.0
                    n = max(1, int(round(L / spacing)))
                    for k in range(n + 1):
                        cx, cy = at(L * k / n)
                        corners = [
                            (cx + ux * s + px * s, cy + uy * s + py * s),
                            (cx + ux * s - px * s, cy + uy * s - py * s),
                            (cx - ux * s - px * s, cy - uy * s - py * s),
                            (cx - ux * s + px * s, cy - uy * s + py * s),
                        ]
                        add_poly([(p[0], p[1]) for p in corners], closed=True)

                elif style == "triangle":
                    spacing = max(0.3, f("spacing", 5.0))
                    s = max(0.1, f("size", 2.0))
                    n = max(1, int(round(L / spacing)))
                    for k in range(n + 1):
                        bx, by = at(L * k / n)
                        tip = (bx + px * s, by + py * s)
                        left = (bx - ux * (s / 2), by - uy * (s / 2))
                        right = (bx + ux * (s / 2), by + uy * (s / 2))
                        add_poly([left, right, tip], closed=True)

                elif style == "zigzag":
                    wl = max(0.5, f("wavelength", 6.0))
                    amp = f("amplitude", 2.0)
                    n = max(2, int(round(L / (wl / 2.0))))
                    pts = []
                    for k in range(n + 1):
                        t = L * k / n
                        cx, cy = at(t)
                        off = amp if (k % 2 == 1) else -amp
                        # endpoints stay on the line for clean joins
                        if k == 0 or k == n:
                            off = 0.0
                        pts.append((cx + px * off, cy + py * off))
                    add_poly(pts, closed=False)

                elif style == "wave":
                    wl = max(0.5, f("wavelength", 6.0))
                    amp = f("amplitude", 2.0)
                    spw = max(4, int(f("samples_per_wave", 12)))
                    n = max(spw, int(round(L / wl * spw)))
                    pts = []
                    for k in range(n + 1):
                        t = L * k / n
                        cx, cy = at(t)
                        off = amp * math.sin(2.0 * math.pi * t / wl)
                        pts.append((cx + px * off, cy + py * off))
                    add_poly(pts, closed=False)

                elif style == "striped":
                    dash = max(0.1, f("dash_length", 3.0))
                    gap = max(0.1, f("gap", 3.0))
                    tilt = math.radians(f("tilt", 45.0))
                    # direction of each stripe = segment direction rotated by tilt
                    sdx = ux * math.cos(tilt) - uy * math.sin(tilt)
                    sdy = ux * math.sin(tilt) + uy * math.cos(tilt)
                    t = 0.0
                    while t < L:
                        mx, my = at(t)
                        half = dash / 2.0
                        add_line((mx - sdx * half, my - sdy * half),
                                 (mx + sdx * half, my + sdy * half))
                        t += gap

                else:
                    # Unknown style: keep the original segment as a plain line.
                    add_line((x1, y1), (x2, y2))

        for h in delete_handles:
            try:
                msp.delete_entity(doc.entitydb[h])
            except KeyError:
                pass

        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_handles": new_handles}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to convert lines: {str(e)}"}


def op_scale_entities(args: Dict[str, Any]) -> Dict[str, Any]:
    """Uniformly scales the given handles about a pivot (cx, cy) by `factor`
    (MAS-80). Edits in place, preserving handles."""
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    factor = float(args.get("factor", 1.0))
    cx = float(args.get("cx", 0.0))
    cy = float(args.get("cy", 0.0))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if factor <= 0:
        return {"status": "error", "message": "Scale factor must be positive."}

    def sc(x, y):
        return (cx + (x - cx) * factor, cy + (y - cy) * factor)

    try:
        doc = ezdxf.readfile(input_path)
        for h in handles:
            try:
                ent = doc.entitydb[h]
            except KeyError:
                continue
            t = ent.dxftype()
            if t == "LINE":
                ent.dxf.start = sc(ent.dxf.start.x, ent.dxf.start.y)
                ent.dxf.end = sc(ent.dxf.end.x, ent.dxf.end.y)
            elif t in ("CIRCLE", "ARC"):
                ent.dxf.center = sc(ent.dxf.center.x, ent.dxf.center.y)
                ent.dxf.radius = ent.dxf.radius * factor
            elif t in ("LWPOLYLINE", "POLYLINE"):
                pts = []
                src = ent.get_points() if hasattr(ent, "get_points") else list(ent.points)
                for p in src:
                    pl = list(p)
                    nx, ny = sc(pl[0], pl[1])
                    pl[0], pl[1] = nx, ny
                    pts.append(tuple(pl))
                if hasattr(ent, "set_points"):
                    ent.set_points(pts)
                else:
                    ent.points = pts
            elif t == "TEXT":
                ent.dxf.insert = sc(ent.dxf.insert.x, ent.dxf.insert.y)
                try:
                    ent.dxf.height = ent.dxf.height * factor
                except Exception:
                    pass
            else:
                try:
                    from ezdxf.math import Matrix44
                    m = (Matrix44.translate(-cx, -cy, 0)
                         @ Matrix44.scale(factor, factor, 1)
                         @ Matrix44.translate(cx, cy, 0))
                    ent.transform(m)
                except Exception:
                    pass
        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to scale entities: {str(e)}"}


def op_mirror_entities(args: Dict[str, Any]) -> Dict[str, Any]:
    """Mirrors the given handles across an arbitrary axis and adds the copies on
    `layer` (MAS-55). Pure-coordinate reflection (no Matrix44) keeps CIRCLE/ARC
    centers/angles canonical with +Z extrusion so the raw-reading 2D parser stays
    correct. When `flip` is false the copy is translated to the mirrored position
    but not reflected. Returns a [old_handle, new_handle] pair list."""
    import math
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    axis_start = args.get("axis_start", [0.0, 0.0])
    axis_end = args.get("axis_end", [1.0, 0.0])
    layer = args.get("layer")
    flip = bool(args.get("flip", True))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    px, py = float(axis_start[0]), float(axis_start[1])
    ex, ey = float(axis_end[0]), float(axis_end[1])
    theta = math.atan2(ey - py, ex - px)
    c2, s2 = math.cos(2 * theta), math.sin(2 * theta)

    def reflect(x, y):
        ox, oy = x - px, y - py
        rx = c2 * ox + s2 * oy
        ry = s2 * ox - c2 * oy
        return (rx + px, ry + py)

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        if layer and layer not in doc.layers:
            try:
                doc.layers.new(layer)
            except Exception:
                pass

        pairs = []
        for h in handles:
            try:
                ent = doc.entitydb[h]
            except KeyError:
                continue
            new = ent.copy()
            msp.add_entity(new)
            if layer:
                new.dxf.layer = layer

            t = new.dxftype()

            # No-mirror mode: translate the copy to the mirrored centroid only.
            if not flip:
                b = _entity_bbox(ent)
                if b is not None:
                    cx, cy = (b[0] + b[2]) / 2.0, (b[1] + b[3]) / 2.0
                    tx, ty = reflect(cx, cy)
                    try:
                        new.translate(tx - cx, ty - cy, 0)
                    except Exception:
                        pass
                pairs.append([h, new.dxf.handle])
                continue

            if t == "LINE":
                s = reflect(new.dxf.start.x, new.dxf.start.y)
                e = reflect(new.dxf.end.x, new.dxf.end.y)
                new.dxf.start = (s[0], s[1])
                new.dxf.end = (e[0], e[1])
            elif t == "CIRCLE":
                cc = reflect(new.dxf.center.x, new.dxf.center.y)
                new.dxf.center = (cc[0], cc[1])
                new.dxf.extrusion = (0, 0, 1)
            elif t == "ARC":
                # Reflection reverses orientation: the new CCW arc runs from the
                # reflected old end point to the reflected old start point.
                old_start = ent.start_point
                old_end = ent.end_point
                cc = reflect(new.dxf.center.x, new.dxf.center.y)
                rs = reflect(old_start.x, old_start.y)
                re_ = reflect(old_end.x, old_end.y)
                new.dxf.center = (cc[0], cc[1])
                new.dxf.extrusion = (0, 0, 1)
                new.dxf.start_angle = math.degrees(math.atan2(re_[1] - cc[1], re_[0] - cc[0]))
                new.dxf.end_angle = math.degrees(math.atan2(rs[1] - cc[1], rs[0] - cc[0]))
            elif t in ("LWPOLYLINE", "POLYLINE"):
                pts = []
                src = ent.get_points() if hasattr(ent, "get_points") else list(ent.points)
                for p in src:
                    pl = list(p)
                    rx, ry = reflect(pl[0], pl[1])
                    pl[0], pl[1] = rx, ry
                    # Negate the bulge so polyline arcs reflect correctly.
                    if len(pl) >= 5:
                        pl[4] = -pl[4]
                    pts.append(tuple(pl))
                if hasattr(new, "set_points"):
                    new.set_points(pts)
                else:
                    new.points = pts
            elif t == "TEXT":
                ins = reflect(new.dxf.insert.x, new.dxf.insert.y)
                new.dxf.insert = (ins[0], ins[1])
                try:
                    new.dxf.rotation = math.degrees(2 * theta) - (new.dxf.rotation or 0.0)
                except Exception:
                    pass
            else:
                # Fallback: best-effort matrix reflection.
                try:
                    from ezdxf.math import Matrix44
                    m = (Matrix44.translate(-px, -py, 0)
                         @ Matrix44((c2, s2, 0, 0), (s2, -c2, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1))
                         @ Matrix44.translate(px, py, 0))
                    new.transform(m)
                except Exception:
                    pass

            pairs.append([h, new.dxf.handle])

        doc.saveas(output_path)
        return {"status": "ok", "data": {"pairs": pairs}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to mirror entities: {str(e)}"}


def op_replace_import(args: Dict[str, Any]) -> Dict[str, Any]:
    """Reloads an imported file from disk in place (MAS-76). Deletes the old
    handles, re-reads `secondary`, positions it so its bounding-box center matches
    the old geometry's center (preserving where the user placed it), merges it on
    `layer`, and returns the new handles."""
    input_path = args.get("input")
    output_path = args.get("output")
    delete_handles = args.get("delete_handles", [])
    secondary = args.get("secondary")
    layer = args.get("layer", "0")

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not secondary or not os.path.exists(secondary):
        return {"status": "error", "message": f"Source file not found: {secondary}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()

        # Combined bbox center of the geometry being replaced.
        old_box = None
        for h in delete_handles:
            try:
                b = _entity_bbox(doc.entitydb[h])
            except KeyError:
                b = None
            if b is None:
                continue
            if old_box is None:
                old_box = list(b)
            else:
                old_box[0] = min(old_box[0], b[0]); old_box[1] = min(old_box[1], b[1])
                old_box[2] = max(old_box[2], b[2]); old_box[3] = max(old_box[3], b[3])
        target_cx = (old_box[0] + old_box[2]) / 2.0 if old_box else 0.0
        target_cy = (old_box[1] + old_box[3]) / 2.0 if old_box else 0.0

        for h in delete_handles:
            try:
                msp.delete_entity(doc.entitydb[h])
            except KeyError:
                pass

        sec = ezdxf.readfile(secondary)
        sec_box = robust_shape_bounds(sec.modelspace())
        if sec_box is not None:
            sec_cx = (sec_box[0] + sec_box[2]) / 2.0
            sec_cy = (sec_box[1] + sec_box[3]) / 2.0
            translate_doc(sec, target_cx - sec_cx, target_cy - sec_cy)

        layer = sanitize_layer_name(layer)
        if layer not in doc.layers:
            doc.layers.new(layer)

        new_handles = []
        for ent in sec.modelspace():
            try:
                ent.dxf.layer = layer
                msp.add_foreign_entity(ent)
                new_handles.append(ent.dxf.handle)
            except Exception:
                pass

        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_handles": new_handles}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to reload import: {str(e)}"}


def op_duplicate_entities(args: Dict[str, Any]) -> Dict[str, Any]:
    """Duplicates the given entity handles, offsetting each copy by (dx, dy).
    Returns the new handles so the UI can select the copies (MAS-77)."""
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    dx = float(args.get("dx", 0.0))
    dy = float(args.get("dy", 0.0))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        new_handles = []
        for h in handles:
            try:
                ent = doc.entitydb[h]
            except KeyError:
                continue
            new = ent.copy()
            msp.add_entity(new)
            try:
                new.translate(dx, dy, 0)
            except Exception:
                # Fallback for entity types without a generic translate().
                try:
                    if new.dxftype() == "LINE":
                        new.dxf.start = (new.dxf.start.x + dx, new.dxf.start.y + dy)
                        new.dxf.end = (new.dxf.end.x + dx, new.dxf.end.y + dy)
                    elif new.dxftype() in ("CIRCLE", "ARC"):
                        new.dxf.center = (new.dxf.center.x + dx, new.dxf.center.y + dy)
                    elif new.dxftype() == "TEXT":
                        new.dxf.insert = (new.dxf.insert.x + dx, new.dxf.insert.y + dy)
                except Exception:
                    pass
            new_handles.append(new.dxf.handle)
        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_handles": new_handles}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to duplicate entities: {str(e)}"}


def op_join_lines(args: Dict[str, Any]) -> Dict[str, Any]:
    """Joins two straight LINE entities that share a near-coincident endpoint into
    one open editable LWPOLYLINE [far_A, corner, far_B]. Used so the Fillet/Chamfer
    tools work on a corner built from two separate lines (imported geometry, two
    sketched lines, etc.). The corner becomes index 1 of the returned base polygon
    so the existing parametric corner machinery can blend it.
    args: input, output, point [x, y], tol (model units, optional)."""
    input_path = args.get("input")
    output_path = args.get("output")
    point = args.get("point")
    tol = float(args.get("tol", 5.0))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not point or len(point) < 2:
        return {"status": "error", "message": "A click point is required."}

    px, py = float(point[0]), float(point[1])
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()

        # Each candidate: (dist_to_click, handle, near_point, far_point, layer)
        cands = []
        for ent in msp.query("LINE"):
            s = (float(ent.dxf.start.x), float(ent.dxf.start.y))
            e = (float(ent.dxf.end.x), float(ent.dxf.end.y))
            ds = math.hypot(s[0] - px, s[1] - py)
            de = math.hypot(e[0] - px, e[1] - py)
            if ds <= de:
                near, far, d = s, e, ds
            else:
                near, far, d = e, s, de
            if d <= tol:
                cands.append((d, ent.dxf.handle, near, far, ent.dxf.layer))

        if len(cands) < 2:
            return {"status": "error",
                    "message": "Click nearer the corner where two lines meet."}

        cands.sort(key=lambda c: c[0])
        a, b = cands[0], cands[1]
        # The shared corner is the average of the two near endpoints (snapped).
        corner = ((a[2][0] + b[2][0]) / 2.0, (a[2][1] + b[2][1]) / 2.0)
        far_a, far_b = a[3], b[3]
        layer = a[4]

        # Replace the two lines with one open polyline through the corner.
        for h in (a[1], b[1]):
            try:
                msp.delete_entity(doc.entitydb[h])
            except KeyError:
                pass
        new_ent = msp.add_lwpolyline([far_a, corner, far_b],
                                     dxfattribs={"layer": layer, "closed": False})
        base = [[far_a[0], far_a[1]], [corner[0], corner[1]], [far_b[0], far_b[1]]]
        doc.saveas(output_path)
        return {"status": "ok",
                "data": {"handle": new_ent.dxf.handle, "base": base, "closed": False}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to join lines: {str(e)}"}


def _trim_intersection_params(p0, p1, msp, target_handle):
    """All intersection parameters t in (0,1) of segment p0->p1 with every other
    LINE / LWPOLYLINE / POLYLINE edge and CIRCLE in the modelspace. Used by the
    Trim tool to cut a line at its crossings (MAS-98)."""
    rx, ry = p1[0] - p0[0], p1[1] - p0[1]
    rr = rx * rx + ry * ry
    if rr < 1e-12:
        return []
    ts = []

    def seg_t(q0, q1):
        sx, sy = q1[0] - q0[0], q1[1] - q0[1]
        denom = rx * sy - ry * sx
        if abs(denom) < 1e-12:
            return None
        qpx, qpy = q0[0] - p0[0], q0[1] - p0[1]
        t = (qpx * sy - qpy * sx) / denom
        u = (qpx * ry - qpy * rx) / denom
        if -1e-9 <= t <= 1 + 1e-9 and -1e-9 <= u <= 1 + 1e-9:
            return t
        return None

    def poly_points(ent):
        if ent.dxftype() == "LWPOLYLINE":
            pts = [(p[0], p[1]) for p in ent.get_points("xy")]
            closed = bool(ent.closed)
        else:
            pts = [(v.dxf.location.x, v.dxf.location.y) for v in ent.vertices]
            closed = bool(ent.is_closed)
        return pts, closed

    for ent in msp:
        if ent.dxf.handle == target_handle:
            continue
        et = ent.dxftype()
        if et == "LINE":
            t = seg_t((ent.dxf.start.x, ent.dxf.start.y),
                      (ent.dxf.end.x, ent.dxf.end.y))
            if t is not None:
                ts.append(t)
        elif et in ("LWPOLYLINE", "POLYLINE"):
            try:
                pts, closed = poly_points(ent)
            except Exception:
                continue
            edges = list(zip(pts, pts[1:]))
            if closed and len(pts) > 2:
                edges.append((pts[-1], pts[0]))
            for q0, q1 in edges:
                t = seg_t(q0, q1)
                if t is not None:
                    ts.append(t)
        elif et == "CIRCLE":
            cx, cy = ent.dxf.center.x, ent.dxf.center.y
            R = ent.dxf.radius
            fx, fy = p0[0] - cx, p0[1] - cy
            a = rr
            b = 2.0 * (fx * rx + fy * ry)
            c = fx * fx + fy * fy - R * R
            disc = b * b - 4 * a * c
            if disc >= 0:
                sq = math.sqrt(disc)
                for t in ((-b - sq) / (2 * a), (-b + sq) / (2 * a)):
                    if 1e-9 < t < 1 - 1e-9:
                        ts.append(t)
        elif et == "ARC":
            cx, cy = ent.dxf.center.x, ent.dxf.center.y
            R = ent.dxf.radius
            fx, fy = p0[0] - cx, p0[1] - cy
            a = rr
            b = 2.0 * (fx * rx + fy * ry)
            c = fx * fx + fy * fy - R * R
            disc = b * b - 4 * a * c
            if disc >= 0:
                sq = math.sqrt(disc)
                for t in ((-b - sq) / (2 * a), (-b + sq) / (2 * a)):
                    if 1e-9 < t < 1 - 1e-9:
                        ix, iy = p0[0] + rx * t, p0[1] + ry * t
                        if _angle_in_arc(math.atan2(iy - cy, ix - cx), ent.dxf.start_angle, ent.dxf.end_angle):
                            ts.append(t)
    # Keep only strictly-interior, de-duplicated parameters.
    ts = sorted(t for t in ts if 1e-6 < t < 1 - 1e-6)
    dedup = []
    for t in ts:
        if not dedup or abs(t - dedup[-1]) > 1e-6:
            dedup.append(t)
    return dedup


def _host_points(ent):
    """(points, closed) for a trimmable host entity, or None."""
    et = ent.dxftype()
    if et == "LINE":
        return [(float(ent.dxf.start.x), float(ent.dxf.start.y)),
                (float(ent.dxf.end.x), float(ent.dxf.end.y))], False
    if et == "LWPOLYLINE":
        return [(float(p[0]), float(p[1])) for p in ent.get_points("xy")], bool(ent.closed)
    if et == "POLYLINE":
        return [(float(v.dxf.location.x), float(v.dxf.location.y)) for v in ent.vertices], bool(ent.is_closed)
    return None


def _emit_path(msp, pts, layer):
    """Adds a surviving trim fragment as a LINE (2 pts) or open LWPOLYLINE (>2),
    skipping degenerate <2-point fragments. Returns the new handle or None."""
    pts = [p for p in pts]
    if len(pts) < 2:
        return None
    if len(pts) == 2:
        return msp.add_line(pts[0], pts[1], dxfattribs={"layer": layer}).dxf.handle
    return msp.add_lwpolyline(pts, dxfattribs={"layer": layer, "closed": False}).dxf.handle


def _poly_edges(pts, closed):
    edges = list(zip(pts, pts[1:]))
    if closed and len(pts) > 2:
        edges.append((pts[-1], pts[0]))
    return edges


def _seg_circle_angles(q0, q1, cx, cy, R):
    """Angles (rad) on circle (cx,cy,R) where the segment q0->q1 actually crosses
    it. A tangent (grazing) contact is ignored — it doesn't divide the circle."""
    dx, dy = q1[0] - q0[0], q1[1] - q0[1]
    a = dx * dx + dy * dy
    if a < 1e-12:
        return []
    fx, fy = q0[0] - cx, q0[1] - cy
    b = 2.0 * (fx * dx + fy * dy)
    c = fx * fx + fy * fy - R * R
    disc = b * b - 4 * a * c
    if disc < 1e-9:                      # miss or tangent → no real cut
        return []
    sq = math.sqrt(disc)
    out = []
    for u in ((-b - sq) / (2 * a), (-b + sq) / (2 * a)):
        if -1e-9 <= u <= 1 + 1e-9:
            px, py = q0[0] + dx * u, q0[1] + dy * u
            out.append(math.atan2(py - cy, px - cx))
    return out


def _circle_circle_points(cx, cy, R, ox, oy, oR):
    """Intersection points of circle (cx,cy,R) with circle (ox,oy,oR). Empty on a
    miss, containment, or tangency (a tangent point doesn't divide the host)."""
    d = math.hypot(ox - cx, oy - cy)
    if d < 1e-9 or d > R + oR - 1e-7 or d < abs(R - oR) + 1e-7:
        return []
    a = (R * R - oR * oR + d * d) / (2 * d)
    h2 = R * R - a * a
    if h2 <= 1e-12:
        return []
    h = math.sqrt(h2)
    bx, by = cx + a * (ox - cx) / d, cy + a * (oy - cy) / d
    px, py = -(oy - cy) / d, (ox - cx) / d
    return [(bx + h * px, by + h * py), (bx - h * px, by - h * py)]


def _angle_in_arc(theta, start_deg, end_deg):
    """True if angle `theta` (rad) lies on the CCW arc start_deg→end_deg."""
    s = math.radians(start_deg) % (2 * math.pi)
    e = math.radians(end_deg) % (2 * math.pi)
    sweep = (e - s) % (2 * math.pi)
    if sweep < 1e-9:
        sweep = 2 * math.pi
    off = (theta % (2 * math.pi) - s) % (2 * math.pi)
    return off <= sweep + 1e-9


def _host_cut_angles(cx, cy, R, msp, target_handle):
    """Sorted, de-duplicated angles (rad, [0,2π)) where the host circle/arc of
    radius R about (cx,cy) is crossed by every other entity (MAS, circle trim)."""
    angs = []
    for ent in msp:
        if ent.dxf.handle == target_handle:
            continue
        et = ent.dxftype()
        if et == "LINE":
            angs += _seg_circle_angles((ent.dxf.start.x, ent.dxf.start.y),
                                       (ent.dxf.end.x, ent.dxf.end.y), cx, cy, R)
        elif et in ("LWPOLYLINE", "POLYLINE"):
            hp = _host_points(ent)
            if hp is None:
                continue
            for q0, q1 in _poly_edges(hp[0], hp[1]):
                angs += _seg_circle_angles(q0, q1, cx, cy, R)
        elif et == "CIRCLE":
            for ix, iy in _circle_circle_points(cx, cy, R, ent.dxf.center.x, ent.dxf.center.y, ent.dxf.radius):
                angs.append(math.atan2(iy - cy, ix - cx))
        elif et == "ARC":
            ocx, ocy, oR = ent.dxf.center.x, ent.dxf.center.y, ent.dxf.radius
            for ix, iy in _circle_circle_points(cx, cy, R, ocx, ocy, oR):
                if _angle_in_arc(math.atan2(iy - ocy, ix - ocx), ent.dxf.start_angle, ent.dxf.end_angle):
                    angs.append(math.atan2(iy - cy, ix - cx))
    norm = sorted(a % (2 * math.pi) for a in angs)
    dedup = []
    for a in norm:
        if not dedup or abs(a - dedup[-1]) > 1e-6:
            dedup.append(a)
    if len(dedup) >= 2 and (dedup[0] + 2 * math.pi - dedup[-1]) < 1e-6:
        dedup.pop()
    return dedup


def _trim_circular(msp, ent, point):
    """Trim a CIRCLE or ARC at its crossings, removing only the span under the
    cursor and leaving real ARC(s). A circle with no crossings deletes whole,
    mirroring how an unbounded line fragment is removed (MAS, circle trim)."""
    et = ent.dxftype()
    cx, cy = ent.dxf.center.x, ent.dxf.center.y
    R = ent.dxf.radius
    attribs = {"layer": ent.dxf.layer}
    if ent.dxf.hasattr("color"):
        attribs["color"] = ent.dxf.color
    angs = _host_cut_angles(cx, cy, R, msp, ent.dxf.handle)
    click_ang = math.atan2(float(point[1]) - cy, float(point[0]) - cx) % (2 * math.pi)
    new_handles = []

    if et == "CIRCLE":
        if not angs:
            msp.delete_entity(ent)
            return []
        k = len(angs)
        lo, hi = angs[-1], angs[0]
        for i in range(k):
            a0, a1 = angs[i], angs[(i + 1) % k]
            span = (a1 - a0) % (2 * math.pi)
            if (click_ang - a0) % (2 * math.pi) <= span + 1e-12:
                lo, hi = a0, a1
                break
        msp.delete_entity(ent)
        arc = msp.add_arc(center=(cx, cy), radius=R,
                          start_angle=math.degrees(hi), end_angle=math.degrees(lo),
                          dxfattribs=attribs)
        return [arc.dxf.handle]

    # ARC host: walk the sweep, drop the clicked sub-span, keep the rest.
    s_r = math.radians(ent.dxf.start_angle) % (2 * math.pi)
    sweep = (math.radians(ent.dxf.end_angle) - math.radians(ent.dxf.start_angle)) % (2 * math.pi)
    if sweep < 1e-9:
        sweep = 2 * math.pi
    cuts = sorted(o for o in ((a - s_r) % (2 * math.pi) for a in angs) if 1e-9 < o < sweep - 1e-9)
    click_off = max(0.0, min(sweep, (click_ang - s_r) % (2 * math.pi)))
    bounds = [0.0] + cuts + [sweep]
    lo, hi = 0.0, sweep
    for i in range(len(bounds) - 1):
        if bounds[i] <= click_off <= bounds[i + 1]:
            lo, hi = bounds[i], bounds[i + 1]
            break
    msp.delete_entity(ent)
    for a0, a1 in ((0.0, lo), (hi, sweep)):
        if a1 - a0 > 1e-6:
            arc = msp.add_arc(center=(cx, cy), radius=R,
                              start_angle=math.degrees(s_r + a0),
                              end_angle=math.degrees(s_r + a1),
                              dxfattribs=attribs)
            new_handles.append(arc.dxf.handle)
    return new_handles


def _project_t(p, a, b):
    """Clamped projection of point p onto segment a→b: (t in [0,1], distance)."""
    rx, ry = b[0] - a[0], b[1] - a[1]
    rr = rx * rx + ry * ry
    if rr < 1e-12:
        return 0.0, math.hypot(p[0] - a[0], p[1] - a[1])
    t = max(0.0, min(1.0, ((p[0] - a[0]) * rx + (p[1] - a[1]) * ry) / rr))
    return t, math.hypot(p[0] - (a[0] + rx * t), p[1] - (a[1] + ry * t))


def _whole_trim_polyline(msp, ent, pts, closed, point):
    """Trim a whole polyline as one curve (curves-as-curves): remove the entire
    portion under the cursor bounded by where *other* geometry crosses it — not
    just the clicked flattened edge. Used for pen curves so a cut removes the
    whole part separated by a line. Returns the surviving fragment handles."""
    layer = ent.dxf.layer
    m = len(pts)
    edges = list(zip(pts, pts[1:]))
    if closed and m > 2:
        edges.append((pts[-1], pts[0]))
    E = len(edges)
    if E == 0:
        return None

    # Click position along the whole polyline, as edge_index + t.
    ci, ct, bestd = 0, 0.0, None
    for i, (a, b) in enumerate(edges):
        t, d = _project_t(point, a, b)
        if bestd is None or d < bestd:
            ci, ct, bestd = i, t, d
    click_pos = ci + ct

    # Every crossing with other geometry, as a position along the polyline.
    cuts = []
    for i, (a, b) in enumerate(edges):
        for t in _trim_intersection_params(a, b, msp, ent.dxf.handle):
            cuts.append(round(i + t, 9))
    cuts = sorted(set(cuts))

    def at(pos):
        e = int(math.floor(pos)) % E if closed else max(0, min(E - 1, int(math.floor(pos))))
        a, b = edges[e]
        t = pos - math.floor(pos)
        if not closed and pos >= E:
            return (pts[-1][0], pts[-1][1])
        return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)

    def subpath(lo, hi):
        out = [at(lo)]
        k = int(math.floor(lo)) + 1
        while k < hi - 1e-9:
            if k > lo + 1e-9:
                out.append((pts[k % m][0], pts[k % m][1]))
            k += 1
        out.append(at(hi))
        return out

    msp.delete_entity(ent)
    if not cuts:
        return []   # a free curve with no crossings is removed whole

    new_handles = []
    if closed and m > 2:
        below = [c for c in cuts if c <= click_pos]
        above = [c for c in cuts if c > click_pos]
        lower = below[-1] if below else cuts[-1]
        upper = above[0] if above else cuts[0]
        # Survivor: from `upper` forward around the loop to `lower` (one open path).
        end = lower if lower > upper else lower + E
        h = _emit_path(msp, subpath(upper, end), layer)
        if h:
            new_handles.append(h)
    else:
        below = [c for c in cuts if c <= click_pos]
        above = [c for c in cuts if c >= click_pos]
        lower = below[-1] if below else 0.0
        upper = above[0] if above else float(E)
        for lo, hi in ((0.0, lower), (upper, float(E))):
            if hi - lo > 1e-9:
                h = _emit_path(msp, subpath(lo, hi), layer)
                if h:
                    new_handles.append(h)
    return new_handles


def op_trim_segment(args: Dict[str, Any]) -> Dict[str, Any]:
    """Fusion-style trim (MAS-98). Cuts the target entity's clicked edge at every
    intersection with other geometry and removes only the sub-segment under the
    cursor. Works on a LINE or any polyline edge: an end piece shortens, an interior
    piece splits, a closed shape opens, and a fully-bounded-free piece deletes that
    span. With `whole` set (a pen curve), the entire portion bounded by crossings
    is removed instead. args: input, output, handle, seg_index, point [x, y],
    whole (bool)."""
    input_path = args.get("input")
    output_path = args.get("output")
    handle = args.get("handle")
    point = args.get("point")
    seg_index = int(args.get("seg_index", 0))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handle or not point or len(point) < 2:
        return {"status": "error", "message": "A handle and click point are required."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        ent = doc.entitydb.get(handle)
        if ent is None:
            return {"status": "error", "message": f"Entity {handle} not found."}
        # Circles and arcs trim by angle, not by edge parameter (MAS, circle trim).
        if ent.dxftype() in ("CIRCLE", "ARC"):
            new_handles = _trim_circular(msp, ent, point)
            doc.saveas(output_path)
            return {"status": "ok", "data": {"new_handles": new_handles}}
        host = _host_points(ent)
        if host is None:
            return {"status": "error", "message": "Trim works on lines, arcs, circles and polylines."}
        pts, closed = host
        # Pen curves trim as one whole curve: drop the entire portion bounded by
        # crossings, not just the clicked flattened edge (curves-as-curves).
        if bool(args.get("whole", False)) and len(pts) >= 2:
            new_handles = _whole_trim_polyline(msp, ent, pts, closed, point)
            if new_handles is not None:
                doc.saveas(output_path)
                return {"status": "ok", "data": {"new_handles": new_handles}}
        m = len(pts)
        if m < 2:
            return {"status": "error", "message": "Nothing to trim."}

        edge_count = m if (closed and m > 2) else m - 1
        seg_index = max(0, min(seg_index, edge_count - 1))
        layer = ent.dxf.layer
        A = pts[seg_index]
        B = pts[(seg_index + 1) % m]
        rx, ry = B[0] - A[0], B[1] - A[1]
        rr = rx * rx + ry * ry
        if rr < 1e-12:
            return {"status": "error", "message": "Degenerate edge."}

        # Click parameter along the clicked edge, and the cut interval around it.
        t_click = max(0.0, min(1.0, ((float(point[0]) - A[0]) * rx + (float(point[1]) - A[1]) * ry) / rr))
        cuts = _trim_intersection_params(A, B, msp, handle)
        bounds = [0.0] + cuts + [1.0]
        lo, hi = 0.0, 1.0
        for i in range(len(bounds) - 1):
            if bounds[i] <= t_click <= bounds[i + 1]:
                lo, hi = bounds[i], bounds[i + 1]
                break

        def at(t):
            return (A[0] + rx * t, A[1] + ry * t)

        msp.delete_entity(ent)
        new_handles = []

        if closed and m > 2:
            # Removing one piece opens the loop: walk from the vertex after the cut
            # edge all the way around to the cut edge's start vertex.
            seq = [pts[(seg_index + 1 + k) % m] for k in range(m)]
            path = []
            if hi < 1 - 1e-6:
                path.append(at(hi))
            path += seq
            if lo > 1e-6:
                path.append(at(lo))
            h = _emit_path(msp, path, layer)
            if h:
                new_handles.append(h)
        else:
            # Open host (line or open polyline): keep the path before and after.
            left = list(pts[:seg_index + 1])
            if lo > 1e-6:
                left.append(at(lo))
            right = []
            if hi < 1 - 1e-6:
                right.append(at(hi))
            right += list(pts[seg_index + 1:])
            for frag in (left, right):
                h = _emit_path(msp, frag, layer)
                if h:
                    new_handles.append(h)

        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_handles": new_handles}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to trim: {str(e)}"}


# --- PSD import (MAS-141) --------------------------------------------------
# Adobe Photoshop (.psd) files are parsed with the open-source `psd-tools`
# library. Each PSD layer becomes a Pathstitch layer: pixel/fill layers are
# rendered to full-resolution PNGs (loaded as reference-image layers), while
# vector content — Photoshop stores placed vector art as smart objects that
# embed the original SVG — is extracted as true vector polylines.
#
# All placements are reported in a single, viewport-independent coordinate
# frame: PSD pixels with the origin at the canvas centre and +Y pointing up
# (matching Pathstitch model space). The Swift side then applies one uniform
# "fit canvas to viewport" scale so every layer stays in register, exactly as
# it was composed in Photoshop.

def _uniqueish_id() -> str:
    import uuid
    return uuid.uuid4().hex


def _psd_svg_to_entities(svg_bytes: bytes, out_dir: str,
                         left: float, top: float, right: float, bottom: float,
                         cw: float, ch: float) -> List[Dict[str, Any]]:
    """Convert an embedded smart-object SVG into LWPOLYLINE entity dicts placed
    to exactly fill the smart object's bounding box on the PSD canvas, returned
    in canvas-centred, +Y-up pixel coordinates.

    Reuses the battle-tested `op_import_svg` path flattener: the SVG is written
    out, imported into a temp DXF, then every entity is flattened to a polyline
    and affine-fitted (independent X/Y scale) into the placement box — the same
    way the rendered raster layer fills its own box, so vector and raster layers
    line up.
    """
    svg_path = os.path.join(out_dir, f"psdvec_{_uniqueish_id()}.svg")
    dxf_path = svg_path[:-4] + ".dxf"
    try:
        with open(svg_path, "wb") as f:
            f.write(svg_bytes)
        res = op_import_svg({"input": svg_path, "output": dxf_path, "consolidate": False})
        if res.get("status") != "ok" or not os.path.exists(dxf_path):
            return []

        doc = ezdxf.readfile(dxf_path)
        msp = doc.modelspace()
        raw: List[Tuple[List[Tuple[float, float]], bool]] = []
        for e in msp:
            t = e.dxftype()
            try:
                if t == "LWPOLYLINE":
                    pts = [(float(p[0]), float(p[1])) for p in e.get_points()]
                    raw.append((pts, bool(e.closed)))
                elif t == "LINE":
                    raw.append(([(float(e.dxf.start.x), float(e.dxf.start.y)),
                                 (float(e.dxf.end.x), float(e.dxf.end.y))], False))
                elif t == "CIRCLE":
                    c = e.dxf.center
                    r = float(e.dxf.radius)
                    pts = [(c.x + r * math.cos(a), c.y + r * math.sin(a))
                           for a in (i * 2.0 * math.pi / 64.0 for i in range(64))]
                    raw.append((pts, True))
                else:
                    # ARC / ELLIPSE / SPLINE / POLYLINE — flatten to a polyline.
                    pts = [(float(p.x), float(p.y)) for p in e.flattening(0.25)]
                    if len(pts) >= 2:
                        raw.append((pts, False))
            except Exception:
                continue

        if not raw:
            return []

        xs = [p[0] for verts, _ in raw for p in verts]
        ys = [p[1] for verts, _ in raw for p in verts]
        ex0, ex1 = min(xs), max(xs)
        ey0, ey1 = min(ys), max(ys)
        ew = (ex1 - ex0) or 1.0
        eh = (ey1 - ey0) or 1.0

        # Target placement box in canvas-centred, +Y-up pixel space.
        tx0 = left - cw / 2.0
        tx1 = right - cw / 2.0
        ty0 = ch / 2.0 - bottom   # smaller Y (lower on screen)
        ty1 = ch / 2.0 - top      # larger Y (higher on screen)
        sx = (tx1 - tx0) / ew
        sy = (ty1 - ty0) / eh

        out: List[Dict[str, Any]] = []
        for verts, closed in raw:
            nv = [[tx0 + (x - ex0) * sx, ty0 + (y - ey0) * sy] for (x, y) in verts]
            if len(nv) >= 2:
                out.append({"type": "LWPOLYLINE", "vertices": nv, "closed": closed})
        return out
    except Exception:
        return []
    finally:
        for p in (svg_path, dxf_path):
            try:
                os.remove(p)
            except OSError:
                pass


def op_parse_psd(args: Dict[str, Any]) -> Dict[str, Any]:
    """Parse a .psd file into per-layer raster/vector data (MAS-141).

    args: { input: <psd path>, out_dir: <temp dir for rendered PNGs> }
    Returns layers top-to-bottom. Raster layers reference a rendered PNG and
    carry their placement centre + natural pixel size; vector layers carry
    ready-to-commit LWPOLYLINE entities. A full flattened composite PNG is also
    rendered for the "load as one image" import option.
    """
    input_path = args.get("input")
    out_dir = args.get("out_dir")
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not out_dir:
        return {"status": "error", "message": "out_dir must be specified."}

    try:
        from psd_tools import PSDImage
    except Exception as e:
        return {"status": "error", "message": f"psd-tools is not installed: {str(e)}"}

    try:
        os.makedirs(out_dir, exist_ok=True)
        psd = PSDImage.open(input_path)
        cw = float(psd.width)
        ch = float(psd.height)
        uid = _uniqueish_id()

        # Flatten the group hierarchy into leaf layers, preserving the visual
        # top-to-bottom stacking order that psd-tools yields.
        leaves: List[Any] = []

        def collect(group) -> None:
            for layer in group:
                if layer.is_group():
                    collect(layer)
                else:
                    leaves.append(layer)

        collect(psd)

        used_names = set()

        def unique_name(base: str) -> str:
            base = (base or "Layer").strip() or "Layer"
            name = base
            i = 2
            while name in used_names:
                name = f"{base} {i}"
                i += 1
            used_names.add(name)
            return name

        layers_out: List[Dict[str, Any]] = []
        idx = 0
        for layer in leaves:
            idx += 1
            bbox = layer.bbox  # (left, top, right, bottom)
            left, top, right, bottom = (float(bbox[0]), float(bbox[1]),
                                        float(bbox[2]), float(bbox[3]))
            if right <= left or bottom <= top:
                continue  # empty layer

            name = unique_name(layer.name if layer.name else f"Layer {idx}")

            # Detect a vector smart object that embeds SVG art.
            svg_bytes = None
            try:
                so = getattr(layer, "smart_object", None)
                if so is not None and so.filetype is not None \
                        and str(so.filetype).lower() == "svg":
                    svg_bytes = so.data
            except Exception:
                svg_bytes = None

            if svg_bytes:
                ents = _psd_svg_to_entities(svg_bytes, out_dir,
                                            left, top, right, bottom, cw, ch)
                if ents:
                    layers_out.append({
                        "name": name,
                        "kind": "vector",
                        "entities": ents,
                        "visible": bool(layer.visible),
                    })
                    continue
                # Embedded SVG yielded no geometry — fall back to raster render.

            # Raster: render this layer's own pixels (cropped to its bbox) at
            # full resolution.
            try:
                pil = layer.composite()
            except Exception:
                pil = None
            if pil is None:
                continue
            if pil.mode != "RGBA":
                pil = pil.convert("RGBA")

            png_path = os.path.join(out_dir, f"psdlayer_{uid}_{idx}.png")
            pil.save(png_path)

            layers_out.append({
                "name": name,
                "kind": "raster",
                "png_path": png_path,
                # Placement centre in canvas-centred, +Y-up pixel space.
                "center_x": (left + right) / 2.0 - cw / 2.0,
                "center_y": ch / 2.0 - (top + bottom) / 2.0,
                "width_px": float(pil.width),
                "height_px": float(pil.height),
                "visible": bool(layer.visible),
            })

        # Full flattened composite for the "load as one image" / merge options.
        comp = psd.composite()
        if comp.mode != "RGBA":
            comp = comp.convert("RGBA")
        comp_path = os.path.join(out_dir, f"psdcomposite_{uid}.png")
        comp.save(comp_path)

        # Fully-flattened PSDs (no explicit layer records) still import as a
        # single reference image rather than "nothing".
        if not layers_out:
            layers_out.append({
                "name": unique_name("Layer 1"),
                "kind": "raster",
                "png_path": comp_path,
                "center_x": 0.0,
                "center_y": 0.0,
                "width_px": float(comp.width),
                "height_px": float(comp.height),
                "visible": True,
            })

        return {"status": "ok", "data": {
            "canvas_width": cw,
            "canvas_height": ch,
            "layers": layers_out,
            "composite_png_path": comp_path,
            "composite_width": float(comp.width),
            "composite_height": float(comp.height),
        }}
    except Exception as e:
        return {"status": "error", "message": f"Failed to parse PSD: {str(e)}"}


def _entity_to_region(ent) -> Optional["Polygon"]:
    """Convert a watertight closed entity to a shapely ``Polygon`` (a filled
    region) for boolean ops (MAS-144). Returns ``None`` for anything that is not
    a closed region — open polylines, lines, arcs, text — so the caller can
    reject the whole operation with a clear error. Curves are flattened the same
    way the rest of the pipeline flattens them (`entity_to_shapely`)."""
    if ent.dxftype() == "TEXT":
        return None
    geom = entity_to_shapely(ent)
    if geom is None or not isinstance(geom, LinearRing):
        return None
    try:
        poly = Polygon(geom)
        if not poly.is_valid:
            poly = poly.buffer(0)
        if poly.is_empty or not isinstance(poly, (Polygon, MultiPolygon)):
            return None
        return poly
    except Exception:
        return None


def _polys_from_result(result) -> List["Polygon"]:
    """Flatten a shapely boolean result into a list of non-empty Polygons."""
    if result is None or result.is_empty:
        return []
    if isinstance(result, Polygon):
        return [result]
    if isinstance(result, MultiPolygon):
        return [p for p in result.geoms if not p.is_empty]
    # GeometryCollection (mixed): keep only the polygonal parts.
    out: List[Polygon] = []
    for g in getattr(result, "geoms", []):
        if isinstance(g, Polygon) and not g.is_empty:
            out.append(g)
        elif isinstance(g, MultiPolygon):
            out.extend(p for p in g.geoms if not p.is_empty)
    return out


def op_boolean(args: Dict[str, Any]) -> Dict[str, Any]:
    """Boolean combine of watertight closed paths (MAS-144): Union, Subtract,
    Intersect. Each operand (closed LWPOLYLINE/POLYLINE/SPLINE, CIRCLE, ELLIPSE)
    becomes a shapely Polygon; the result is written back as closed
    LWPOLYLINE(s) — one per exterior ring plus one per hole — on the target
    layer, and the originals are deleted.

    * ``operation``: "union" | "subtract" | "intersect".
    * Subtract is ``base − (everything else)``. The base is the explicitly
      provided ``base`` handle, else the largest-area operand — the least
      surprising default for cutting notches/holes out of a big shape.
    * ``layer`` (optional): the active layer the result should land on. When
      omitted the base operand's own layer is used.
    """
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", []) or []
    operation = str(args.get("operation") or "union").lower()
    layer_arg = args.get("layer")
    base_handle = args.get("base")

    if operation not in ("union", "subtract", "intersect"):
        return {"status": "error", "message": f"Unknown boolean operation: {operation}"}
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if len(handles) < 2:
        return {"status": "error", "message": "Select at least two closed paths to combine."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        ents = []
        regions = []
        for h in handles:
            try:
                ent = doc.entitydb[h]
            except KeyError:
                continue
            poly = _entity_to_region(ent)
            if poly is None:
                return {"status": "error", "message": "Boolean operations need watertight closed paths (closed polylines, circles, ellipses). One or more selected paths are open or not a closed region."}
            ents.append(ent)
            regions.append(poly)
        if len(regions) < 2:
            return {"status": "error", "message": "Select at least two closed paths to combine."}

        # Pick the base operand (subtract & default layer): explicit handle wins,
        # else the largest-area shape.
        if base_handle is not None:
            base_idx = next((i for i, e in enumerate(ents) if e.dxf.handle == base_handle), 0)
        else:
            base_idx = max(range(len(regions)), key=lambda i: regions[i].area)

        out_layer = sanitize_layer_name(layer_arg) if layer_arg else ents[base_idx].dxf.layer
        if out_layer not in doc.layers:
            doc.layers.new(out_layer)

        if operation == "union":
            result = unary_union(regions)
        elif operation == "intersect":
            result = regions[0]
            for r in regions[1:]:
                result = result.intersection(r)
        else:  # subtract
            others = unary_union([r for i, r in enumerate(regions) if i != base_idx])
            result = regions[base_idx].difference(others)

        polys = _polys_from_result(result)
        if not polys:
            if operation == "intersect":
                return {"status": "error", "message": "The selected shapes do not overlap; the intersection is empty."}
            return {"status": "error", "message": "The boolean result is empty (the shape was fully consumed)."}

        # Only mutate the document once we know we have a valid result.
        for e in ents:
            try:
                msp.delete_entity(e)
            except Exception:
                pass

        new_handles: List[str] = []
        for poly in polys:
            ext = list(poly.exterior.coords)
            if len(ext) >= 4:
                ne = msp.add_lwpolyline([(c[0], c[1]) for c in ext][:-1],
                                        dxfattribs={"layer": out_layer, "closed": True})
                new_handles.append(ne.dxf.handle)
            for interior in poly.interiors:
                ic = list(interior.coords)
                if len(ic) >= 4:
                    ne = msp.add_lwpolyline([(c[0], c[1]) for c in ic][:-1],
                                            dxfattribs={"layer": out_layer, "closed": True})
                    new_handles.append(ne.dxf.handle)

        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_handles": new_handles, "operation": operation}}
    except Exception as e:
        return {"status": "error", "message": f"Boolean operation failed: {str(e)}"}


def op_explode_compound(args: Dict[str, Any]) -> Dict[str, Any]:
    """Explode compound paths into individual closed loops (MAS-145) — the
    inverse of Union. A single closed path whose region resolves to multiple
    rings (a self-intersecting figure-eight, or a self-touching shape-with-hole)
    is split into one closed LWPOLYLINE per ring: every exterior shell plus every
    hole becomes its own independent loop on the same layer. Simple single-loop
    paths are left untouched and reported as kept.
    """
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", []) or []

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handles:
        return {"status": "error", "message": "Select a compound path to explode."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        new_handles: List[str] = []
        kept_handles: List[str] = []
        exploded = 0

        for h in handles:
            try:
                ent = doc.entitydb[h]
            except KeyError:
                continue
            is_closed = bool(getattr(ent, "closed", False) or getattr(ent, "is_closed", False))
            if ent.dxftype() not in ("LWPOLYLINE", "POLYLINE") or not is_closed:
                kept_handles.append(h)
                continue

            geom = entity_to_shapely(ent)
            if not isinstance(geom, LinearRing):
                kept_handles.append(h)
                continue

            # Node the ring at its self-intersections and rebuild the distinct
            # faces. `buffer(0)` is unsuitable here — it silently drops one lobe
            # of a self-crossing (figure-eight) ring. polygonize over the noded
            # linework recovers every closed face instead.
            faces = list(polygonize(unary_union(LineString(geom.coords))))
            if not faces:
                kept_handles.append(h)
                continue

            rings: List[List[Tuple[float, float]]] = []
            seen: List[Polygon] = []

            def _add_ring(coords: List[Tuple[float, float]]) -> None:
                if len(coords) < 4:
                    return
                try:
                    rp = Polygon(coords)
                except Exception:
                    return
                if rp.is_empty:
                    return
                for s in seen:
                    if rp.equals(s):  # shared boundary appears in two faces
                        return
                seen.append(rp)
                rings.append(coords)

            for f in faces:
                _add_ring(list(f.exterior.coords))
                for it in f.interiors:
                    _add_ring(list(it.coords))

            # Only a genuine compound (2+ distinct loops) is worth exploding.
            if len(rings) <= 1:
                kept_handles.append(h)
                continue

            layer = ent.dxf.layer
            for ring in rings:
                if len(ring) >= 4:
                    ne = msp.add_lwpolyline([(c[0], c[1]) for c in ring][:-1],
                                            dxfattribs={"layer": layer, "closed": True})
                    new_handles.append(ne.dxf.handle)
            try:
                msp.delete_entity(ent)
            except Exception:
                pass
            exploded += 1

        if exploded == 0:
            return {"status": "error", "message": "Nothing to explode — the selection is a single loop, not a compound path."}

        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_handles": new_handles, "kept_handles": kept_handles, "exploded": exploded}}
    except Exception as e:
        return {"status": "error", "message": f"Explode failed: {str(e)}"}


# --- Fill primitive: HATCH support (MAS-146) ---------------------------------

def _hatch_boundary_loops(hatch) -> List[List[Tuple[float, float]]]:
    """Every boundary loop of a HATCH as a list of (x, y) vertices (exterior(s)
    plus holes). Uses ezdxf's path conversion so both polyline and edge boundary
    paths (arcs, splines) flatten consistently."""
    loops: List[List[Tuple[float, float]]] = []
    try:
        from ezdxf.path import from_hatch
        for path_obj in from_hatch(hatch):
            pts = [(p.x, p.y) for p in path_obj.flattening(0.1)]
            if len(pts) >= 3:
                loops.append(pts)
    except Exception:
        for p in getattr(hatch, "paths", []):
            verts = getattr(p, "vertices", None)
            if verts:
                pts = [(v[0], v[1]) for v in verts]
                if len(pts) >= 3:
                    loops.append(pts)
    return loops


def _add_hatch_from_polygon(msp, poly: "Polygon", layer: str, color: int):
    """Create a solid-filled HATCH for a shapely Polygon (exterior + any holes)."""
    attribs = {"layer": layer}
    if color and color not in (0, 256):
        attribs["color"] = color
    hatch = msp.add_hatch(dxfattribs=attribs)
    ext = [(c[0], c[1]) for c in poly.exterior.coords]
    hatch.paths.add_polyline_path(ext, is_closed=True, flags=1)  # 1 = external
    for interior in poly.interiors:
        ic = [(c[0], c[1]) for c in interior.coords]
        hatch.paths.add_polyline_path(ic, is_closed=True, flags=0)
    hatch.set_solid_fill(color=color if (color and color not in (0, 256)) else 7)
    return hatch


def op_convert_to_fill(args: Dict[str, Any]) -> Dict[str, Any]:
    """Stroke → Fill (MAS-146 Phase 2). Each selected watertight closed path
    becomes a solid HATCH. Self-intersections collapse under the non-zero winding
    rule (shapely buffer(0)) — an inward jut that encloses no area is swallowed,
    not turned into a hole. Open paths are skipped with a clear message."""
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", []) or []
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handles:
        return {"status": "error", "message": "Select a closed path to fill."}
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        new_handles: List[str] = []
        converted = 0
        skipped_open = 0
        for h in handles:
            try:
                ent = doc.entitydb[h]
            except KeyError:
                continue
            if ent.dxftype() == "HATCH":
                continue  # already a fill
            poly = _entity_to_region(ent)
            if poly is None:
                skipped_open += 1
                continue
            layer = ent.dxf.layer
            color = ent.dxf.color
            for p in (poly.geoms if isinstance(poly, MultiPolygon) else [poly]):
                if p.is_empty:
                    continue
                hatch = _add_hatch_from_polygon(msp, p, layer, color)
                new_handles.append(hatch.dxf.handle)
            try:
                msp.delete_entity(ent)
            except Exception:
                pass
            converted += 1
        if converted == 0:
            msg = "Convert to Fill needs a closed path — the selection is open." if skipped_open else "Nothing to fill."
            return {"status": "error", "message": msg}
        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_handles": new_handles, "converted": converted}}
    except Exception as e:
        return {"status": "error", "message": f"Convert to fill failed: {str(e)}"}


def op_convert_to_stroke(args: Dict[str, Any]) -> Dict[str, Any]:
    """Fill → Stroke (MAS-146 Phase 3). Each selected HATCH becomes its boundary
    loops as closed LWPOLYLINEs — the outer boundary plus one loop per hole."""
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", []) or []
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handles:
        return {"status": "error", "message": "Select a filled region to outline."}
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        new_handles: List[str] = []
        converted = 0
        for h in handles:
            try:
                ent = doc.entitydb[h]
            except KeyError:
                continue
            if ent.dxftype() != "HATCH":
                continue
            layer = ent.dxf.layer
            color = ent.dxf.color
            for loop in _hatch_boundary_loops(ent):
                pts = loop[:-1] if (len(loop) > 3 and abs(loop[0][0] - loop[-1][0]) < 1e-6 and abs(loop[0][1] - loop[-1][1]) < 1e-6) else loop
                if len(pts) >= 3:
                    attribs = {"layer": layer, "closed": True}
                    if color and color not in (0, 256):
                        attribs["color"] = color
                    ne = msp.add_lwpolyline(pts, dxfattribs=attribs)
                    new_handles.append(ne.dxf.handle)
            try:
                msp.delete_entity(ent)
            except Exception:
                pass
            converted += 1
        if converted == 0:
            return {"status": "error", "message": "Select a filled region (HATCH) to convert to a stroke."}
        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_handles": new_handles, "converted": converted}}
    except Exception as e:
        return {"status": "error", "message": f"Convert to stroke failed: {str(e)}"}


def _entity_length(ent) -> float:
    """Flattened arc-length of any drawable entity, in mm."""
    try:
        p = make_path(ent)
        verts = [(v.x, v.y) for v in p.flattening(distance=0.05)]
        return sum(math.hypot(verts[i + 1][0] - verts[i][0],
                              verts[i + 1][1] - verts[i][1])
                   for i in range(len(verts) - 1))
    except Exception:
        return 0.0


def op_box_stitch(args: Dict[str, Any]) -> Dict[str, Any]:
    """Box Stitch Helper: re-prick two mating panels (handle_a, handle_b) with an
    EQUAL number of stitch holes so their seams line up. The pitch on each panel is
    flexed slightly to land the agreed count. All iron / offset / shape args are
    forwarded to op_add_holes, so the shaped slits are identical on both panels.

    strategy: 'average' (default) | 'a' | 'b' | 'custom' (uses `count`)."""
    input_path = args.get("input")
    output_path = args.get("output")
    handle_a = args.get("handle_a")
    handle_b = args.get("handle_b")
    strategy = str(args.get("strategy", "average")).lower()
    pitch = float(args.get("hole_spacing", 4.0))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handle_a or not handle_b:
        return {"status": "error", "message": "Select both panels (A and B) to box-stitch."}

    try:
        doc = ezdxf.readfile(input_path)
        ent_a = doc.entitydb[handle_a]
        ent_b = doc.entitydb[handle_b]
    except KeyError:
        return {"status": "error", "message": "One of the selected panels was not found."}

    len_a = _entity_length(ent_a)
    len_b = _entity_length(ent_b)
    if len_a <= 0 or len_b <= 0:
        return {"status": "error", "message": "Could not measure one of the panels."}

    pitch = max(1e-3, pitch)
    na = max(2, int(round(len_a / pitch)))
    nb = max(2, int(round(len_b / pitch)))
    if strategy == "a":
        count = na
    elif strategy == "b":
        count = nb
    elif strategy == "custom":
        count = max(2, int(args.get("count", max(na, nb))))
    else:  # average
        count = max(2, int(round((na + nb) / 2.0)))

    # Forward every shaped-slit / offset arg to op_add_holes, overriding only the
    # distribution so both panels get exactly `count` holes. Chain input→output so
    # the second pricking sees the first panel's holes.
    base = dict(args)
    base.pop("handle_a", None)
    base.pop("handle_b", None)
    base.pop("strategy", None)
    base["distribution"] = "count"
    base["hole_count"] = count

    a_args = dict(base, input=input_path, output=output_path, handles=[handle_a])
    r1 = op_add_holes(a_args)
    if r1.get("status") != "ok":
        return r1
    b_args = dict(base, input=output_path, output=output_path, handles=[handle_b])
    r2 = op_add_holes(b_args)
    if r2.get("status") != "ok":
        return r2

    return {"status": "ok", "data": {
        "count": count, "len_a": len_a, "len_b": len_b,
        "pitch_a": len_a / count, "pitch_b": len_b / count}}


def op_mandala(args: Dict[str, Any]) -> Dict[str, Any]:
    """Mandala / radial symmetry: replicate the selected seed geometry `segments`
    times around a centre (cx, cy). With `mirror` on, each wedge also gets a
    reflected copy → full dihedral (kaleidoscope) symmetry."""
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    segments = max(2, int(args.get("segments", 8)))
    cx = float(args.get("cx", 0.0))
    cy = float(args.get("cy", 0.0))
    mirror = bool(args.get("mirror", False))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not handles:
        return {"status": "error", "message": "Draw something in one wedge first, then Mandala it."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        step = 2.0 * math.pi / segments
        new_handles: List[str] = []

        # Optional reflected seed (across the horizontal line through the centre).
        reflect_m = (Matrix44.translate(-cx, -cy, 0.0)
                     @ Matrix44.scale(1.0, -1.0, 1.0)
                     @ Matrix44.translate(cx, cy, 0.0))
        mirror_handles: List[str] = []
        if mirror:
            for h in handles:
                try:
                    ne = doc.entitydb[h].copy()
                    ne.transform(reflect_m)
                    msp.add_entity(ne)
                    mirror_handles.append(ne.dxf.handle)
                    new_handles.append(ne.dxf.handle)
                except KeyError:
                    pass

        sources = list(handles) + mirror_handles
        for i in range(1, segments):
            rot = (Matrix44.translate(-cx, -cy, 0.0)
                   @ Matrix44.z_rotate(step * i)
                   @ Matrix44.translate(cx, cy, 0.0))
            for h in sources:
                try:
                    ne = doc.entitydb[h].copy()
                    ne.transform(rot)
                    msp.add_entity(ne)
                    new_handles.append(ne.dxf.handle)
                except KeyError:
                    pass

        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_entities": new_handles,
                                         "segments": segments, "mirror": mirror}}
    except Exception as e:
        return {"status": "error", "message": f"Mandala failed: {str(e)}"}


def _comb_profile(p1, p2, n_fingers, depth, start_tab, tab_shrink, outward):
    """Square-wave (box-joint) profile from p1 to p2. `tab_shrink` narrows every
    raised tab by that amount (split each side) so a mating edge fits with kerf
    clearance. Returns a list of (x, y) vertices for an open LWPOLYLINE."""
    x1, y1 = p1
    x2, y2 = p2
    L = math.hypot(x2 - x1, y2 - y1)
    if L < 1e-6 or n_fingers < 1:
        return [tuple(p1), tuple(p2)]
    dx, dy = (x2 - x1) / L, (y2 - y1) / L          # along edge
    sgn = 1.0 if outward else -1.0
    nx, ny = -dy * sgn, dx * sgn                    # outward normal
    w = L / n_fingers
    half_shrink = max(0.0, tab_shrink) / 2.0

    def P(along, lift):
        return (x1 + dx * along + nx * lift, y1 + dy * along + ny * lift)

    pts = [P(0.0, 0.0)]
    for i in range(n_fingers):
        a0, a1 = i * w, (i + 1) * w
        is_tab = ((i % 2 == 0) == start_tab)
        if is_tab:
            s0, s1 = a0 + half_shrink, a1 - half_shrink
            if s1 < s0:                              # tab narrower than kerf → pin
                s0 = s1 = (a0 + a1) / 2.0
            pts.extend([P(s0, 0.0), P(s0, depth), P(s1, depth), P(s1, 0.0)])
        else:
            pts.append(P(a1, 0.0))                   # stay on the base line
    pts.append(P(L, 0.0))
    # drop consecutive duplicates
    out = [pts[0]]
    for p in pts[1:]:
        if math.hypot(p[0] - out[-1][0], p[1] - out[-1][1]) > 1e-7:
            out.append(p)
    return out


def op_box_joint(args: Dict[str, Any]) -> Dict[str, Any]:
    """Box Joint Maker: emit an interlocking finger-joint profile along the edge
    p1→p2. If `mate` is true and p3/p4 are given, the complementary profile is
    emitted on that edge (tabs↔slots) with `kerf` clearance so the two interlock.
    Profiles are open LWPOLYLINEs on the BOX_JOINT layer."""
    input_path = args.get("input")
    output_path = args.get("output")
    p1 = args.get("p1")
    p2 = args.get("p2")
    depth = float(args.get("depth", 5.0))
    kerf = float(args.get("kerf", 0.2))
    start_tab = bool(args.get("start_tab", True))
    outward = bool(args.get("outward", True))
    mate = bool(args.get("mate", False))
    p3 = args.get("p3")
    p4 = args.get("p4")

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not p1 or not p2:
        return {"status": "error", "message": "Pick an edge (two points) to fingerise."}

    L = math.hypot(p2[0] - p1[0], p2[1] - p1[1])
    if L < 1e-6:
        return {"status": "error", "message": "Edge has zero length."}
    if "finger_count" in args and args.get("finger_count"):
        n_fingers = max(1, int(args["finger_count"]))
    else:
        fw = max(1e-3, float(args.get("finger_width", 8.0)))
        n_fingers = max(1, int(round(L / fw)))

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        if "BOX_JOINT" not in doc.layers:
            doc.layers.new("BOX_JOINT", dxfattribs={"color": 5})

        new_handles = []
        prof = _comb_profile(p1, p2, n_fingers, depth, start_tab, 0.0, outward)
        e1 = msp.add_lwpolyline(prof, dxfattribs={"layer": "BOX_JOINT"})
        new_handles.append(e1.dxf.handle)

        if mate and p3 and p4:
            # Mating edge: flip tab/slot phase and shrink tabs by kerf for fit.
            prof2 = _comb_profile(p3, p4, n_fingers, depth, not start_tab, kerf, outward)
            e2 = msp.add_lwpolyline(prof2, dxfattribs={"layer": "BOX_JOINT"})
            new_handles.append(e2.dxf.handle)

        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_entities": new_handles,
                                         "fingers": n_fingers}}
    except Exception as e:
        return {"status": "error", "message": f"Box joint failed: {str(e)}"}


def op_golden(args: Dict[str, Any]) -> Dict[str, Any]:
    """Golden-ratio design guides on the GUIDES layer.
      kind='spiral'    : the true golden (logarithmic) spiral, fit to bbox.
      kind='rectangle' : a φ rectangle plus its recursive square subdivision.
      kind='centerline': a construction line between p1 and p2.
    bbox = [x, y, w, h]. PHI = 1.6180339887."""
    input_path = args.get("input")
    output_path = args.get("output")
    kind = str(args.get("kind", "spiral")).lower()
    PHI = (1.0 + 5.0 ** 0.5) / 2.0

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        if "GUIDES" not in doc.layers:
            doc.layers.new("GUIDES", dxfattribs={"color": 8})
        attr = {"layer": "GUIDES"}
        new_handles = []

        if kind == "centerline":
            p1 = args.get("p1"); p2 = args.get("p2")
            if not p1 or not p2:
                return {"status": "error", "message": "Centre line needs two points."}
            e = msp.add_line(p1, p2, dxfattribs=attr)
            new_handles.append(e.dxf.handle)
            doc.saveas(output_path)
            return {"status": "ok", "data": {"new_entities": new_handles}}

        bbox = args.get("bbox")
        if not bbox or len(bbox) != 4:
            return {"status": "error", "message": "Drag a bounding box for the guide."}
        bx, by, bw, bh = [float(v) for v in bbox]
        bw = bw if abs(bw) > 1e-6 else 1.0
        bh = bh if abs(bh) > 1e-6 else 1.0
        cw = str(args.get("handedness", "ccw")).lower() == "cw"
        subdivisions = max(1, int(args.get("subdivisions", 8)))

        def snap_phi(w, h):
            """Return a φ rectangle (w:h = φ:1) keeping the longer drawn side."""
            if abs(w) >= abs(h):
                return abs(h) * PHI * (1 if w >= 0 else -1), h
            return w, abs(w) * PHI * (1 if h >= 0 else -1)

        def draw_phi_rect(w, h):
            """Outline + recursive square subdivision lines; returns handles."""
            hs = []
            rect = [(bx, by), (bx + w, by), (bx + w, by + h), (bx, by + h)]
            hs.append(msp.add_lwpolyline(rect, close=True, dxfattribs=attr).dxf.handle)
            x, y, rw, rh = bx, by, w, h
            for _ in range(subdivisions):
                if abs(rw) < 1e-3 or abs(rh) < 1e-3:
                    break
                if abs(rw) >= abs(rh):
                    s = rh
                    hs.append(msp.add_line((x + s, y), (x + s, y + rh), dxfattribs=attr).dxf.handle)
                    x += s; rw -= s
                else:
                    s = rw
                    hs.append(msp.add_line((x, y + s), (x + rw, y + s), dxfattribs=attr).dxf.handle)
                    y += s; rh -= s
            return hs

        if kind == "rectangle":
            w, h = snap_phi(bw, bh)
            new_handles.extend(draw_phi_rect(w, h))
            doc.saveas(output_path)
            return {"status": "ok", "data": {"new_entities": new_handles}}

        # spiral: the true golden (logarithmic) spiral, fit to the φ-snapped box;
        # `turns` controls coil count, `handedness` the coil direction, and
        # `show_rect` overlays the golden rectangle + square subdivisions.
        w, h = snap_phi(bw, bh)
        if bool(args.get("show_rect", True)):
            new_handles.extend(draw_phi_rect(w, h))
        b = math.log(PHI) / (math.pi / 2.0)   # grows by φ every quarter turn
        turns = max(0.25, float(args.get("turns", 3.0)))
        theta_max = turns * 2.0 * math.pi
        n = max(64, int(turns * 90))
        raw = []
        for i in range(n + 1):
            th = theta_max * i / n
            r = math.exp(b * th)
            y = r * math.sin(th)
            raw.append((r * math.cos(th), -y if cw else y))
        xs = [p[0] for p in raw]; ys = [p[1] for p in raw]
        minx, maxx = min(xs), max(xs); miny, maxy = min(ys), max(ys)
        sx = abs(w) / (maxx - minx if maxx > minx else 1.0)
        sy = abs(h) / (maxy - miny if maxy > miny else 1.0)
        x0 = min(bx, bx + w); y0 = min(by, by + h)
        pts = [(x0 + (x - minx) * sx, y0 + (yy - miny) * sy) for x, yy in raw]
        new_handles.append(msp.add_lwpolyline(pts, dxfattribs=attr).dxf.handle)
        doc.saveas(output_path)
        return {"status": "ok", "data": {"new_entities": new_handles}}
    except Exception as e:
        return {"status": "error", "message": f"Golden guide failed: {str(e)}"}


OPERATIONS = {
    "list_entities": op_list_entities,
    "offset_lines": op_offset_lines,
    "add_thickness": op_add_thickness,
    "add_holes": op_add_holes,
    "edit_fold_line": op_edit_fold_line,
    "cleanup": op_cleanup,
    "export_svg": op_export_svg,
    "chain_select": op_chain_select,
    "add_entity": op_add_entity,
    "place_hardware": op_place_hardware,
    "edge_treatment": op_edge_treatment,
    "insert_net": op_insert_net,
    "offset_bbox": op_offset_bbox,
    "update_entity": op_update_entity,
    "set_layer": op_set_layer,
    "import_svg": op_import_svg,
    "export_pdf": op_export_pdf,
    "import_pdf": op_import_pdf,
    "trace_raster": op_trace_raster,
    "remove_bg_image": op_remove_bg_image,
    "commit_trace": op_commit_trace,
    "parse_psd": op_parse_psd,
    "translate_entities": op_translate_entities,
    "edit_vertices": op_edit_vertices,
    "apply_corners": op_apply_corners,
    "rotate_entities": op_rotate_entities,
    "reflect_entities": op_reflect_entities,
    "append_dxf": op_append_dxf,
    "import_distribute": op_import_distribute,
    "arrange_to_mat": op_arrange_to_mat,
    "normalize_dxf": op_normalize_dxf,
    "scale_all": op_scale_all,
    "export_dxf": op_export_dxf,
    "add_dashed_creases": op_add_dashed_creases,
    "add_glue_tabs": op_add_glue_tabs,
    "pattern_grid": op_pattern_grid,
    "pattern_circular": op_pattern_circular,
    "pattern_path": op_pattern_path,
    "add_text": op_add_text,
    "update_text": op_update_text,
    "delete_entities": op_delete_entities,
    "duplicate_entities": op_duplicate_entities,
    "convert_lines": op_convert_lines,
    "replace_import": op_replace_import,
    "mirror_entities": op_mirror_entities,
    "scale_entities": op_scale_entities,
    "new_dxf": op_new_dxf,
    "add_construction_lines": op_add_construction_lines,
    "join_lines": op_join_lines,
    "trim_segment": op_trim_segment,
    "boolean": op_boolean,
    "explode_compound": op_explode_compound,
    "convert_to_fill": op_convert_to_fill,
    "convert_to_stroke": op_convert_to_stroke,
    "box_stitch": op_box_stitch,
    "mandala": op_mandala,
    "box_joint": op_box_joint,
    "golden": op_golden,
}


def main() -> None:
    """CLI entry point for JSON subprocess interactions."""
    parser = argparse.ArgumentParser(description="Pathstitch DXF operations CLI tool.")
    parser.add_argument("--json", type=str, help="JSON execution configuration.")
    args = parser.parse_args()

    # Read configuration from parameter or stdin
    config_str = ""
    if args.json:
        config_str = args.json
    else:
        config_str = sys.stdin.read()

    try:
        config = json.loads(config_str)
    except Exception as e:
        print(json.dumps({"status": "error", "message": f"Failed to parse input JSON: {str(e)}"}))
        sys.exit(1)

    op = config.get("op")
    op_args = config.get("args", {})

    if op not in OPERATIONS:
        print(json.dumps({"status": "error", "message": f"Unknown operation: {op}"}))
        sys.exit(1)

    try:
        result = OPERATIONS[op](op_args)
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"status": "error", "message": f"Operation failed: {str(e)}"}))
        sys.exit(1)

if __name__ == "__main__":
    main()
