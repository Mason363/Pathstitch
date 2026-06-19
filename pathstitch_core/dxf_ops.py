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
from shapely.geometry import LineString, LinearRing, MultiLineString, Point as ShapelyPoint
from shapely.ops import linemerge

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
    n = len(coords)
    if n < 3:
        return corners

    threshold_rad = math.radians(angle_threshold_deg)
    
    # Check loop state
    is_loop = coords[0] == coords[-1] or math.hypot(coords[0][0] - coords[-1][0], coords[0][1] - coords[-1][1]) < 1e-5
    
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

def get_offset_geometry(geom: LineString, distance: float, side: str) -> Optional[Any]:
    """Offsets a curve, expanding/shrinking closed shapes and side-offsetting open
    ones. Uses polygon ``buffer`` for closed rings (robust expand/shrink that never
    self-intersects into a "shifted" copy) and ``offset_curve`` for open lines —
    replacing shapely's deprecated, unreliable ``parallel_offset`` (MAS-71).

    Side semantics:
      * ``outer`` / ``inner`` — always expand / shrink (winding independent).
      * ``left`` / ``right``  — offset toward the first edge's left / right normal,
        which is what the on-canvas drag handle uses. Mapped to expand/shrink via
        the ring winding so dragging the handle outward always grows the shape.
    Returns a ``LinearRing`` (closed), ``LineString``/``MultiLineString`` (open),
    ``MultiLineString`` (closed result that split), or ``None`` (e.g. shrunk away).
    """
    from shapely.geometry import Polygon, MultiPolygon, MultiLineString as _MLS, LinearRing as _LR

    if abs(distance) < 1e-5:
        return geom

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

            result = poly.buffer(d, join_style="mitre", mitre_limit=4.0)
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
            oc = geom.offset_curve(d, join_style="mitre", mitre_limit=4.0)
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
        if ent.dxftype() not in ("LINE", "ARC", "CIRCLE", "LWPOLYLINE", "SPLINE", "ELLIPSE", "TEXT"):
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

            if not P:
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


def op_normalize_dxf(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    
    doc = ezdxf.readfile(input_path)
    translate_to_positive_quadrant(doc)
    doc.saveas(output_path)
    return {"status": "ok"}

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

def op_export_dxf(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles")
    
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        doc = ezdxf.readfile(input_path)
        if handles is not None:
            msp = doc.modelspace()
            for ent in list(msp):
                if ent.dxf.handle not in handles:
                    msp.delete_entity(ent)
        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to export DXF: {str(e)}"}

def op_import_svg(args: Dict[str, Any]) -> Dict[str, Any]:
    import xml.etree.ElementTree as ET
    import re
    input_path = args.get("input")
    output_path = args.get("output")
    consolidate = args.get("consolidate", False)
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    try:
        tree = ET.parse(input_path)
        root = tree.getroot()
        doc = ezdxf.new(dxfversion="R2010")
        msp = doc.modelspace()
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
            def add_poly(coords: List[Tuple[float, float]], is_closed: bool, layer: str):
                if len(coords) < 2:
                    return
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
                add_poly(pts, True, current_layer)
            elif tag == 'circle':
                cx = parse_svg_val(attrib.get('cx', 0))
                cy = parse_svg_val(attrib.get('cy', 0))
                r = parse_svg_val(attrib.get('r', 0))
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
                add_poly(pts, True, current_layer)
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
                add_poly(pts, True, current_layer)
            elif tag == 'path':
                d_str = attrib.get('d', '')
                paths_data = parse_svg_d(d_str)
                for subpath in paths_data:
                    inverted_path = [(p[0], -p[1]) for p in subpath]
                    if len(inverted_path) >= 2:
                        is_cl = math.hypot(inverted_path[0][0] - inverted_path[-1][0], inverted_path[0][1] - inverted_path[-1][1]) < 1e-4
                        if is_cl:
                            inverted_path = inverted_path[:-1]
                        add_poly(inverted_path, is_cl, current_layer)
        if "ORIGINAL" not in doc.layers:
            doc.layers.new("ORIGINAL")
        process_element(root, "ORIGINAL")
        translate_to_positive_quadrant(doc)
        doc.saveas(output_path)
        return {"status": "ok"}
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
    enable_corner_interpolation = args.get("enable_corner_interpolation", True)

    # Distribution mode (MAS-59): "spacing" fills the contour at a fixed pitch;
    # "count" places a fixed number of evenly-spaced holes per contour (the pitch
    # is derived from the contour length, and variable spacing is disabled).
    distribution = args.get("distribution", "spacing")
    hole_count = int(args.get("hole_count", 0) or 0)
    if distribution == "count" and hole_count > 0:
        enable_variable_spacing = False
    
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
            vertices = [(p.x, p.y) for p in path.flattening(distance=0.01)]
            if len(vertices) < 2:
                continue
            is_cl = ent.dxftype() == "CIRCLE" or getattr(ent, "closed", False) or getattr(ent, "is_closed", False)
            geoms.append(LinearRing(vertices) if is_cl else LineString(vertices))
        except Exception:
            pass

    if not geoms:
        return {"status": "error", "message": "No valid geometry found to apply sewing holes."}

    snapped = snap_endpoints(geoms)
    merged = linemerge(snapped)

    paths: List[LineString] = []
    if isinstance(merged, MultiLineString):
        paths.extend(merged.geoms)
    elif isinstance(merged, LineString):
        paths.append(merged)

    hole_centers: List[Tuple[float, float]] = []
    hole_radius = hole_diameter / 2.0

    def check_collision_with_others(p_pt, geoms_list, radius: float, og_distances: dict, og_contains_path: dict, og_is_contour: dict) -> bool:
        for og in geoms_list:
            # Skip only geometry that *is* part of the sewing contour (collinear
            # overlap). Geometry that merely *crosses* the contour is a real
            # obstacle and must still filter holes — the old `dist < 0.05` skip
            # wrongly excluded crossing lines, so holes landed across them (MAS-106).
            if og_is_contour.get(id(og), False):
                continue
            if enable_line_proximity_filter and og.distance(p_pt) < line_proximity_threshold:
                return True
            if og.distance(p_pt) < radius:
                return True
            if isinstance(og, LinearRing):
                from shapely.geometry import Polygon
                try:
                    if og_contains_path.get(id(og), False):
                        continue
                    poly = Polygon(og)
                    if poly.contains(p_pt):
                        return True
                except Exception:
                    pass
        return False

    for path in paths:
        # Precompute path-to-other-geoms distances and containment checks to avoid O(N*M) heavy calculations in the hot loop
        og_distances = {}
        og_contains_path = {}
        og_is_contour = {}
        for og in other_geoms:
            try:
                og_distances[id(og)] = og.distance(path)
            except Exception:
                og_distances[id(og)] = 9999.0

            # An "other" geometry that overlaps the contour along a length (not just
            # a crossing point) is really part of the contour itself — skip it as an
            # obstacle. A crossing line meets the contour at a point and is kept so
            # holes near it are filtered (MAS-106).
            try:
                inter = og.intersection(path)
                og_is_contour[id(og)] = bool(getattr(inter, "length", 0.0) > 0.5)
            except Exception:
                og_is_contour[id(og)] = og_distances[id(og)] < 0.05

            if isinstance(og, LinearRing):
                from shapely.geometry import Polygon
                try:
                    poly = Polygon(og)
                    og_contains_path[id(og)] = poly.contains(path)
                except Exception:
                    og_contains_path[id(og)] = False
            else:
                og_contains_path[id(og)] = False

        is_closed = path.is_closed or math.hypot(path.coords[0][0] - path.coords[-1][0], path.coords[0][1] - path.coords[-1][1]) < 0.05
        polygon = None
        if is_closed:
            from shapely.geometry import Polygon
            try:
                polygon = Polygon(path)
            except Exception:
                pass
        offsets = []
        if pattern == "saddle":
            offsets.append((offset_distance - row_spacing / 2.0, 0.0))
            offsets.append((offset_distance + row_spacing / 2.0, hole_spacing / 2.0))
        else:
            offsets.append((offset_distance, 0.0))
            
        step_size = 0.1
        L = path.length
        if L < 0.1:
            continue
        steps = int(math.ceil(L / step_size))
        
        for dist, shift in offsets:
            contour_internal_candidates = []
            contour_external_candidates = []
            prev_pt = None
            prev_normal = None
            
            for i in range(steps + 1):
                d = (i / steps) * L
                pt, normal = get_point_and_normal(path, d, is_closed)
                
                # Corner normal interpolation
                if enable_corner_interpolation and prev_pt and prev_normal:
                    dot = prev_normal[0]*normal[0] + prev_normal[1]*normal[1]
                    if dot < 0.999:
                        angle1 = math.atan2(prev_normal[1], prev_normal[0])
                        angle2 = math.atan2(normal[1], normal[0])
                        diff = angle2 - angle1
                        while diff < -math.pi: diff += 2 * math.pi
                        while diff > math.pi: diff -= 2 * math.pi
                        if abs(diff) > 0.05:
                            arc_steps = int(math.ceil(dist * abs(diff) / step_size))
                            for j in range(1, arc_steps):
                                t = j / arc_steps
                                angle = angle1 + diff * t
                                interp_normal = (math.cos(angle), math.sin(angle))
                                p1 = (prev_pt[0] + interp_normal[0] * dist, prev_pt[1] + interp_normal[1] * dist)
                                p2 = (prev_pt[0] - interp_normal[0] * dist, prev_pt[1] - interp_normal[1] * dist)
                                for p in [p1, p2]:
                                    p_pt = ShapelyPoint(p)
                                    is_internal = polygon.contains(p_pt) if (is_closed and polygon) else (p == p1)
                                    parent_dist = path.distance(p_pt)
                                    
                                    # Line proximity filter check for self-overlap
                                    is_overlap = False
                                    if enable_line_proximity_filter:
                                        if parent_dist < line_proximity_threshold:
                                            is_overlap = True
                                    else:
                                        if parent_dist < dist - 0.5:
                                            is_overlap = True
                                            
                                    if is_overlap:
                                        proj_d = path.project(p_pt)
                                        d_diff = abs(d - proj_d)
                                        if is_closed:
                                            d_diff = min(d_diff, L - d_diff)
                                        if d_diff > 3.0 * offset_distance:
                                            continue
                                            
                                    if check_collision_with_others(p_pt, other_geoms, hole_radius, og_distances, og_contains_path, og_is_contour):
                                        continue
                                    if is_internal:
                                        contour_internal_candidates.append(p)
                                    else:
                                        contour_external_candidates.append(p)
                                        
                # Regular candidate normal offset
                p1 = (pt[0] + normal[0] * dist, pt[1] + normal[1] * dist)
                p2 = (pt[0] - normal[0] * dist, pt[1] - normal[1] * dist)
                for p in [p1, p2]:
                    p_pt = ShapelyPoint(p)
                    is_internal = polygon.contains(p_pt) if (is_closed and polygon) else (p == p1)
                    parent_dist = path.distance(p_pt)
                    
                    # Line proximity filter check for self-overlap
                    is_overlap = False
                    if enable_line_proximity_filter:
                        if parent_dist < line_proximity_threshold:
                            is_overlap = True
                    else:
                        if parent_dist < dist - 0.5:
                            is_overlap = True
                            
                    if is_overlap:
                        proj_d = path.project(p_pt)
                        d_diff = abs(d - proj_d)
                        if is_closed:
                            d_diff = min(d_diff, L - d_diff)
                        if d_diff > 3.0 * offset_distance:
                            continue
                            
                    if check_collision_with_others(p_pt, other_geoms, hole_radius, og_distances, og_contains_path, og_is_contour):
                        continue
                    if is_internal:
                        contour_internal_candidates.append(p)
                    else:
                        contour_external_candidates.append(p)
                prev_pt = pt
                prev_normal = normal
                
            if distribution == "count" and hole_count > 0:
                # Even count per contour. Seed the pitch from contour length / count,
                # then refine: filter_by_density's ">= spacing" test overshoots a
                # little each step, so we proportionally rescale the pitch a few
                # times until it yields exactly the requested number of holes.
                def _spacing_for_count(pts, target):
                    if target <= 0 or len(pts) < 2:
                        return hole_spacing
                    clen = sum(math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
                               for i in range(1, len(pts)))
                    if clen <= 1e-6:
                        return hole_spacing
                    spacing = clen / target
                    best_spacing, best_err = spacing, None
                    for _ in range(12):
                        m = len(filter_by_density(pts, spacing, 0.0))
                        err = abs(m - target)
                        # Keep the closest; on a tie prefer not undershooting.
                        if best_err is None or err < best_err or (err == best_err and m > target):
                            best_err, best_spacing = err, spacing
                        if m == target or m == 0:
                            break
                        spacing *= float(m) / float(target)
                    return max(best_spacing, 1e-6)
                spacing_internal = _spacing_for_count(contour_internal_candidates, hole_count)
                spacing_external = _spacing_for_count(contour_external_candidates, hole_count)
            else:
                spacing_internal = select_optimal_spacing(contour_internal_candidates, is_closed, hole_spacing, enable_variable_spacing, variable_spacing_min, variable_spacing_max)
                spacing_external = select_optimal_spacing(contour_external_candidates, is_closed, hole_spacing, enable_variable_spacing, variable_spacing_min, variable_spacing_max)
            
            final_internal = filter_by_density(contour_internal_candidates, spacing_internal, shift)
            final_external = filter_by_density(contour_external_candidates, spacing_external, shift)
            
            sides_to_use = []
            if side in ("left", "inner"):
                sides_to_use = [True]
            elif side in ("right", "outer"):
                sides_to_use = [False]
            else:
                sides_to_use = [True, False]
                
            for is_int in sides_to_use:
                cand_list = final_internal if is_int else final_external
                for p in cand_list:
                    selected_pt = (p[0], p[1])
                    # Ensure no duplicate centers
                    if not any(math.hypot(selected_pt[0] - hc[0], selected_pt[1] - hc[1]) < 0.01 for hc in hole_centers):
                        hole_centers.append(selected_pt)

    if enable_proximity_filter and hole_centers:
        to_remove = set()
        for i in range(len(hole_centers)):
            if i in to_remove:
                continue
            for j in range(i + 1, len(hole_centers)):
                if j in to_remove:
                    continue
                dist = math.hypot(hole_centers[i][0] - hole_centers[j][0], hole_centers[i][1] - hole_centers[j][1])
                if dist < proximity_filter_distance:
                    to_remove.add(j)
        hole_centers = [hole_centers[idx] for idx in range(len(hole_centers)) if idx not in to_remove]

    # Proximity filter against existing circles
    filtered_centers = []
    for hc in hole_centers:
        too_close = False
        for cx, cy, r in existing_circles:
            dist = math.hypot(hc[0] - cx, hc[1] - cy)
            if dist < proximity_filter_distance:
                too_close = True
                break
        if not too_close:
            filtered_centers.append(hc)
    hole_centers = filtered_centers

    # Keep-out clearance (MAS-120 Phase 1, Gap Mode): drop any hole whose center is
    # within `avoidance_radius` (C) of a keep-out element, or inside a closed one.
    suppressed_by_keepout = 0
    if keepout_geoms:
        kept = []
        for hc in hole_centers:
            p_pt = ShapelyPoint(hc)
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

    for cx, cy in hole_centers:
        msp.add_circle(center=(cx, cy), radius=hole_radius, dxfattribs={"layer": "SEWING_HOLES"})

    doc.saveas(output_path)
    return {"status": "ok", "data": {"hole_count": len(hole_centers), "suppressed_by_keepout": suppressed_by_keepout}}

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

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    doc = ezdxf.readfile(input_path)
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
    dwg = svgwrite.Drawing(output_path, size=(width, height), viewBox=f"{svg_min_x} {svg_min_y} {width} {height}")

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

        g = dwg.g(id=safe_id, stroke=color_hex, fill="none", stroke_width=0.5)

        for ent in entities:
            if ent["type"] == "CIRCLE":
                cx, cy = ent["center"]
                r = ent["radius"]
                g.add(dwg.circle(center=(cx, -cy), r=r, stroke=color_hex))
            else:
                pts = ent["vertices"]
                svg_pts = [(p[0], -p[1]) for p in pts]
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
        from PIL import Image
        import potrace
        import numpy as np
        
        img = Image.open(input_path).convert("L")
        img_np = np.array(img)
        bmp = img_np < threshold
        
        bmp_obj = potrace.Bitmap(bmp)
        path = bmp_obj.trace(turdsize=turdsize, alphamax=alphamax, opttolerance=opttolerance)
        
        doc = ezdxf.new(dxfversion="R2010")
        msp = doc.modelspace()
        if "ORIGINAL" not in doc.layers:
            doc.layers.new("ORIGINAL")
            
        h = img.height
        for curve in path:
            start_point = curve.start_point
            pts = [(float(start_point.x), h - float(start_point.y))]
            
            for segment in curve:
                if segment.is_corner:
                    c = segment.c
                    p = segment.end_point
                    pts.append((float(c.x), h - float(c.y)))
                    pts.append((float(p.x), h - float(p.y)))
                else:
                    p0 = pts[-1]
                    p1 = (float(segment.c1.x), h - float(segment.c1.y))
                    p2 = (float(segment.c2.x), h - float(segment.c2.y))
                    p3 = (float(segment.end_point.x), h - float(segment.end_point.y))
                    for t in np.linspace(0.1, 1.0, 10):
                        x = (1-t)**3 * p0[0] + 3*(1-t)**2*t * p1[0] + 3*(1-t)*t**2 * p2[0] + t**3 * p3[0]
                        y = (1-t)**3 * p0[1] + 3*(1-t)**2*t * p1[1] + 3*(1-t)*t**2 * p2[1] + t**3 * p3[1]
                        pts.append((x, y))
            
            if len(pts) >= 2:
                msp.add_lwpolyline(pts, dxfattribs={"layer": "ORIGINAL", "closed": True})
                
        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to trace image: {str(e)}"}

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


OPERATIONS = {
    "list_entities": op_list_entities,
    "offset_lines": op_offset_lines,
    "add_holes": op_add_holes,
    "cleanup": op_cleanup,
    "export_svg": op_export_svg,
    "chain_select": op_chain_select,
    "add_entity": op_add_entity,
    "offset_bbox": op_offset_bbox,
    "update_entity": op_update_entity,
    "set_layer": op_set_layer,
    "import_svg": op_import_svg,
    "export_pdf": op_export_pdf,
    "import_pdf": op_import_pdf,
    "trace_raster": op_trace_raster,
    "commit_trace": op_commit_trace,
    "translate_entities": op_translate_entities,
    "edit_vertices": op_edit_vertices,
    "apply_corners": op_apply_corners,
    "rotate_entities": op_rotate_entities,
    "reflect_entities": op_reflect_entities,
    "append_dxf": op_append_dxf,
    "import_distribute": op_import_distribute,
    "normalize_dxf": op_normalize_dxf,
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
