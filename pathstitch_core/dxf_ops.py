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
from ezdxf.path import make_path, Path
from shapely.geometry import LineString, LinearRing, MultiLineString, Point as ShapelyPoint
from shapely.ops import linemerge

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
    Helps prepare curves for successful line merging.
    """
    if not geoms:
        return []

    # Extract all endpoints
    endpoints = []
    for g in geoms:
        endpoints.append(g.coords[0])
        endpoints.append(g.coords[-1])

    # Cluster endpoints
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

    # Snap geometry endpoints to their cluster centers
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
    return snapped_geoms

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
    """Calculates parallel offset geometry, handling positive/negative distance offsets and inner/outer sides."""
    if abs(distance) < 1e-5:
        return geom
        
    is_closed = geom.is_closed or isinstance(geom, LinearRing)
    if is_closed:
        try:
            geom = LinearRing(geom.coords)
        except Exception:
            pass
            
    if side == "inner":
        if is_closed and isinstance(geom, LinearRing):
            actual_side = "left" if geom.is_ccw else "right"
        else:
            actual_side = "left"
    elif side == "outer":
        if is_closed and isinstance(geom, LinearRing):
            actual_side = "right" if geom.is_ccw else "left"
        else:
            actual_side = "right"
    else:
        # Fallback to left/right if passed directly
        actual_side = "left" if side == "left" else "right"
        
    try:
        if distance < 0:
            opp_side = "right" if actual_side == "left" else "left"
            return geom.parallel_offset(abs(distance), opp_side)
        else:
            return geom.parallel_offset(distance, actual_side)
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
    layer = args.get("layer", "OFFSET")

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    if layer not in doc.layers:
        doc.layers.new(layer, dxfattribs={"color": 3})  # Green by default

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
                new_ent = msp.add_circle(center=(cx, cy), radius=r_offset, dxfattribs={"layer": layer})
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

        from shapely.geometry import MultiLineString, LineString, LinearRing
        if isinstance(merged, (LineString, LinearRing, MultiLineString)):
            if isinstance(merged, MultiLineString):
                merged_list = list(merged.geoms)
            else:
                merged_list = [merged]
        elif isinstance(merged, list):
            merged_list = merged
        else:
            merged_list = []

        for geom in merged_list:
            is_closed = geom.is_closed or isinstance(geom, LinearRing)
            sides_to_try = ["inner", "outer"] if side == "both" else [side]
            for s in sides_to_try:
                offset_geom = get_offset_geometry(geom, distance, s)
                if not offset_geom:
                    continue

                if isinstance(offset_geom, MultiLineString):
                    for sub_geom in offset_geom.geoms:
                        new_ent = msp.add_lwpolyline(list(sub_geom.coords), dxfattribs={"layer": layer})
                        new_handles.append(new_ent.dxf.handle)
                elif isinstance(offset_geom, (LineString, LinearRing)):
                    new_ent = msp.add_lwpolyline(list(offset_geom.coords), dxfattribs={"layer": layer})
                    new_handles.append(new_ent.dxf.handle)

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
    layer = args.get("layer", "ORIGINAL")

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
    layer = args.get("layer", "OFFSET")

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
    layer = args.get("layer")
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
    if not layer:
        return {"status": "error", "message": "Layer name must be specified."}
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
    
    if abs(dx) < 1e-4 and abs(dy) < 1e-4:
        return
        
    # Translate all entities
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
            layer_name = layer.dxf.name
            if layer_name not in primary_doc.layers:
                primary_doc.layers.new(layer_name, dxfattribs={"color": layer.dxf.color})

        # Copy entities
        for ent in secondary_msp:
            try:
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
            if tag == 'g':
                layer_name = elem.get('id') or elem.get('{http://www.inkscape.org/namespaces/inkscape}label')
                if layer_name:
                    layer_name = layer_name.replace("layer_", "").strip()
                    if not layer_name:
                        layer_name = current_layer
                else:
                    layer_name = current_layer
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
    
    # New customizable proximity and variable spacing parameters
    enable_line_proximity_filter = args.get("enable_line_proximity_filter", True)
    line_proximity_threshold = float(args.get("line_proximity_threshold", 1.0))
    proximity_filter_distance = float(args.get("proximity_filter_distance", 3.0))
    variable_spacing_min = float(args.get("variable_spacing_min", 4.0))
    variable_spacing_max = float(args.get("variable_spacing_max", 5.0))

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

    def check_collision_with_others(p_pt, geoms_list, radius: float, current_path) -> bool:
        for og in geoms_list:
            if og.distance(current_path) < 0.05:
                continue
            if enable_line_proximity_filter and og.distance(p_pt) < line_proximity_threshold:
                return True
            if og.distance(p_pt) < radius:
                return True
            if isinstance(og, LinearRing):
                from shapely.geometry import Polygon
                try:
                    poly = Polygon(og)
                    if poly.contains(current_path):
                        continue
                    if poly.contains(p_pt):
                        return True
                except Exception:
                    pass
        return False

    for path in paths:
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
                                    if enable_line_proximity_filter:
                                        if parent_dist < line_proximity_threshold:
                                            continue
                                    else:
                                        if parent_dist < dist - 0.5:
                                            continue
                                            
                                    if check_collision_with_others(p_pt, other_geoms, hole_radius, path):
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
                    if enable_line_proximity_filter:
                        if parent_dist < line_proximity_threshold:
                            continue
                    else:
                        if parent_dist < dist - 0.5:
                            continue
                            
                    if check_collision_with_others(p_pt, other_geoms, hole_radius, path):
                        continue
                    if is_internal:
                        contour_internal_candidates.append(p)
                    else:
                        contour_external_candidates.append(p)
                prev_pt = pt
                prev_normal = normal
                
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

    for cx, cy in hole_centers:
        msp.add_circle(center=(cx, cy), radius=hole_radius, dxfattribs={"layer": "SEWING_HOLES"})

    doc.saveas(output_path)
    return {"status": "ok", "data": {"hole_count": len(hole_centers)}}

def op_cleanup(args: Dict[str, Any]) -> Dict[str, Any]:
    """Cleans up and joins coincident endpoint segments within the DXF."""
    input_path = args.get("input")
    output_path = args.get("output")
    tolerance = float(args.get("tolerance", 0.1))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    # Collect and remove original target entities
    targets = []
    for ent in list(msp):
        if ent.dxftype() in ("LINE", "ARC", "LWPOLYLINE", "SPLINE"):
            targets.append(ent)

    before_count = len(list(msp))
    geoms = []
    
    for ent in targets:
        try:
            path = make_path(ent)
            vertices = [(p.x, p.y) for p in path.flattening(distance=0.01)]
            if len(vertices) < 2:
                # Remove zero-length entities
                msp.delete_entity(ent)
                continue
            
            # Keep tracks of properties
            geoms.append((LineString(vertices), ent.dxf.layer, ent.dxf.color))
            msp.delete_entity(ent)
        except Exception:
            pass

    # Group geometry by layer to keep structural isolation
    layer_groups: Dict[str, List[Tuple[LineString, int]]] = {}
    for geom, layer, color in geoms:
        if layer not in layer_groups:
            layer_groups[layer] = []
        layer_groups[layer].append((geom, color))

    joins_count = 0
    
    for layer, items in layer_groups.items():
        if not items:
            continue
        
        linestrings = [item[0] for item in items]
        default_color = items[0][1]
        
        # Snap and merge
        snapped = snap_endpoints(linestrings, tolerance)
        merged = linemerge(snapped)
        
        final_components = []
        if isinstance(merged, MultiLineString):
            final_components.extend(merged.geoms)
        elif isinstance(merged, LineString):
            final_components.append(merged)
            
        for path in final_components:
            # Simplify collinear segments
            simplified = path.simplify(tolerance=1e-5)
            coords = list(simplified.coords)
            if len(coords) < 2:
                continue
            
            # Re-insert joined polyline
            msp.add_lwpolyline(coords, dxfattribs={"layer": layer, "color": default_color})
            joins_count += len(coords) - 1

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

    for layer_name, entities in layers_data.items():
        try:
            dxf_layer = doc.layers.get(layer_name)
            color_hex = aci_to_hex(dxf_layer.color)
        except Exception:
            color_hex = "#ffffff"

        # Create SVG Group representing the DXF Layer
        g = dwg.g(id=f"layer_{layer_name}", stroke=color_hex, fill="none", stroke_width=0.5)

        for ent in entities:
            if ent["type"] == "CIRCLE":
                cx, cy = ent["center"]
                r = ent["radius"]
                g.add(dwg.circle(center=(cx, -cy), r=r))
            else:
                pts = ent["vertices"]
                svg_pts = [(p[0], -p[1]) for p in pts]
                if ent["is_closed"]:
                    g.add(dwg.polygon(points=svg_pts))
                else:
                    g.add(dwg.polyline(points=svg_pts))
        dwg.add(g)

    dwg.save()
    return {"status": "ok", "data": {"svg_path": output_path}}

def op_chain_select(args: Dict[str, Any]) -> Dict[str, Any]:
    """Finds all entity handles geometrically connected to the seed entity (within 0.01mm)."""
    input_path = args.get("input")
    seed_handle = args.get("seed_handle")
    tolerance = float(args.get("tolerance", 0.01))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not seed_handle:
        return {"status": "error", "message": "Seed handle must be specified."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    # Build segment endpoints lookup
    entity_points = {}
    for ent in msp:
        if ent.dxftype() not in ("LINE", "ARC", "LWPOLYLINE", "SPLINE", "ELLIPSE"):
            continue
        try:
            path = make_path(ent)
            start = (path.start.x, path.start.y)
            end = (path.end.x, path.end.y)
            entity_points[ent.dxf.handle] = (start, end)
        except Exception:
            pass

    if seed_handle not in entity_points:
        return {"status": "ok", "data": {"handles": [seed_handle]}}

    # BFS search to find connected paths
    chain = {seed_handle}
    queue = [seed_handle]

    while queue:
        curr = queue.pop(0)
        curr_start, curr_end = entity_points[curr]

        for h, (start, end) in entity_points.items():
            if h in chain:
                continue

            # Check distance between all endpoint pairs
            d1 = math.hypot(curr_start[0] - start[0], curr_start[1] - start[1])
            d2 = math.hypot(curr_start[0] - end[0], curr_start[1] - end[1])
            d3 = math.hypot(curr_end[0] - start[0], curr_end[1] - start[1])
            d4 = math.hypot(curr_end[0] - end[0], curr_end[1] - end[1])

            if min(d1, d2, d3, d4) < tolerance:
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
    turdsize = int(args.get("turdsize", 2))
    
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
        path = bmp_obj.trace(turdsize=turdsize)
        
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
                msp.add_lwpolyline(pts, dxfattribs={"layer": "ORIGINAL", "closed": curve.is_loop})
                
        doc.saveas(output_path)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": f"Failed to trace image: {str(e)}"}

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
                
                if side == "left":
                    nx = -uy
                    ny = ux
                else:
                    nx = uy
                    ny = -ux
                    
                tab_pts = [p1]
                
                if tab_type == "triangle":
                    mid_x = (p1[0] + p2[0]) / 2.0
                    mid_y = (p1[1] + p2[1]) / 2.0
                    peak = (mid_x + height * nx, mid_y + height * ny)
                    tab_pts.append(peak)
                else:
                    h_offset = min(height, L / 2.1)
                    t1 = (p1[0] + h_offset * ux + height * nx, p1[1] + h_offset * uy + height * ny)
                    t2 = (p2[0] - h_offset * ux + height * nx, p2[1] - h_offset * uy + height * ny)
                    tab_pts.append(t1)
                    tab_pts.append(t2)
                    
                tab_pts.append(p2)
                
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
    
    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}
        
    try:
        doc = ezdxf.readfile(input_path)
        msp = doc.modelspace()
        
        if layer not in doc.layers:
            doc.layers.new(layer, dxfattribs={"color": 7})
            
        txt_ent = msp.add_text(text, dxfattribs={"height": height, "layer": layer})
        txt_ent.dxf.insert = (float(insert[0]), float(insert[1]))
        
        doc.saveas(output_path)
        return {"status": "ok", "data": {"handle": txt_ent.dxf.handle}}
    except Exception as e:
        return {"status": "error", "message": f"Failed to add text: {str(e)}"}

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

    operations = {
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
        "translate_entities": op_translate_entities,
        "append_dxf": op_append_dxf,
        "normalize_dxf": op_normalize_dxf,
        "export_dxf": op_export_dxf,
        "add_dashed_creases": op_add_dashed_creases,
        "add_glue_tabs": op_add_glue_tabs,
        "pattern_grid": op_pattern_grid,
        "pattern_path": op_pattern_path,
        "add_text": op_add_text,
        "delete_entities": op_delete_entities,
        "new_dxf": op_new_dxf
    }

    if op not in operations:
        print(json.dumps({"status": "error", "message": f"Unknown operation: {op}"}))
        sys.exit(1)

    try:
        result = operations[op](op_args)
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"status": "error", "message": f"Operation failed: {str(e)}"}))
        sys.exit(1)

if __name__ == "__main__":
    main()
