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
    """Calculates parallel offset geometry, handling positive/negative distance offsets."""
    if abs(distance) < 1e-5:
        return geom
    try:
        if distance < 0:
            opp_side = "right" if side == "left" else "left"
            return geom.parallel_offset(abs(distance), opp_side)
        else:
            return geom.parallel_offset(distance, side)
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
        if ent.dxftype() not in ("LINE", "ARC", "CIRCLE", "LWPOLYLINE", "SPLINE", "ELLIPSE"):
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
            elif ent.dxftype() == "LWPOLYLINE":
                data["vertices"] = [[p[0], p[1]] for p in ent.get_points()]
                data["closed"] = ent.closed
            else:
                # Splines & Ellipses
                path = make_path(ent)
                vertices = list(path.flattening(distance=0.1))
                data["vertices"] = [[p.x, p.y] for p in vertices]
                data["closed"] = ent.is_closed
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

    for ent in targets:
        # Standalone CIRCLE optimization
        if ent.dxftype() == "CIRCLE" and not handles:
            cx, cy = ent.dxf.center.x, ent.dxf.center.y
            r = ent.dxf.radius
            r_offset = r + distance if side == "left" else r - distance
            if r_offset > 0:
                new_ent = msp.add_circle(center=(cx, cy), radius=r_offset, dxfattribs={"layer": layer})
                new_handles.append(new_ent.dxf.handle)
            continue

        try:
            path = make_path(ent)
            vertices = [(p.x, p.y) for p in path.flattening(distance=0.01)]
            if len(vertices) < 2:
                continue

            is_closed = ent.dxftype() == "CIRCLE" or getattr(ent, "closed", False) or getattr(ent, "is_closed", False)
            geom = LinearRing(vertices) if is_closed else LineString(vertices)
            
            offset_geom = get_offset_geometry(geom, distance, side)
            if not offset_geom:
                continue

            # Output geometry to modelspace
            if isinstance(offset_geom, MultiLineString):
                for sub_geom in offset_geom.geoms:
                    new_ent = msp.add_lwpolyline(list(sub_geom.coords), dxfattribs={"layer": layer})
                    new_handles.append(new_ent.dxf.handle)
            elif isinstance(offset_geom, (LineString, LinearRing)):
                new_ent = msp.add_lwpolyline(list(offset_geom.coords), dxfattribs={"layer": layer})
                new_handles.append(new_ent.dxf.handle)
        except Exception:
            pass

    doc.saveas(output_path)
    return {"status": "ok", "data": {"new_entities": new_handles}}

def op_add_holes(args: Dict[str, Any]) -> Dict[str, Any]:
    """Adds sewing hole circle entities relative to selected geometry paths."""
    input_path = args.get("input")
    output_path = args.get("output")
    handles = args.get("handles", [])
    offset_distance = float(args.get("offset_distance", 2.0))
    hole_diameter = float(args.get("hole_diameter", 1.0))
    hole_spacing = float(args.get("hole_spacing", 4.0))
    pattern = args.get("pattern", "single")  # single, saddle
    corner_behavior = args.get("corner_behavior", "skip")  # skip, wrap
    side = args.get("side", "left")  # left, right
    row_spacing = float(args.get("row_spacing", 3.0))

    if not input_path or not os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    if "SEWING_HOLES" not in doc.layers:
        doc.layers.new("SEWING_HOLES", dxfattribs={"color": 3})  # Green

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

    # Convert targets to LineString components
    geoms: List[LineString] = []
    original_vertices_all: List[Tuple[float, float]] = []

    for ent in targets:
        try:
            path = make_path(ent)
            vertices = [(p.x, p.y) for p in path.flattening(distance=0.01)]
            if len(vertices) < 2:
                continue
            original_vertices_all.extend(vertices)
            
            is_closed = ent.dxftype() == "CIRCLE" or getattr(ent, "closed", False) or getattr(ent, "is_closed", False)
            geoms.append(LinearRing(vertices) if is_closed else LineString(vertices))
        except Exception:
            pass

    if not geoms:
        return {"status": "error", "message": "No valid geometry found to apply sewing holes."}

    # Snap and merge connected paths
    snapped = snap_endpoints(geoms)
    merged = linemerge(snapped)

    # Convert merged result to list of components
    paths: List[LineString] = []
    if isinstance(merged, MultiLineString):
        paths.extend(merged.geoms)
    elif isinstance(merged, LineString):
        paths.append(merged)

    # Detect corner points on original vertices
    corners = []
    if corner_behavior == "skip":
        corners = find_corners(original_vertices_all)

    hole_centers: List[Tuple[float, float]] = []
    hole_radius = hole_diameter / 2.0

    # Process each merged continuous path
    for path in paths:
        is_closed = path.is_closed or math.hypot(path.coords[0][0] - path.coords[-1][0], path.coords[0][1] - path.coords[-1][1]) < 0.05
        
        # Calculate offsets based on stitch pattern
        offsets = []
        if pattern == "saddle":
            offsets.append((offset_distance - row_spacing / 2.0, 0.0))
            offsets.append((offset_distance + row_spacing / 2.0, hole_spacing / 2.0))
        else:
            offsets.append((offset_distance, 0.0))

        for dist, shift in offsets:
            offset_path = get_offset_geometry(path, dist, side)
            if not offset_path:
                continue

            # Flatten offset path components
            sub_paths = []
            if isinstance(offset_path, MultiLineString):
                sub_paths.extend(offset_path.geoms)
            elif isinstance(offset_path, (LineString, LinearRing)):
                sub_paths.append(offset_path)

            for sp in sub_paths:
                candidates = sample_path(sp, hole_spacing, is_closed, shift)
                for pt in candidates:
                    # Apply corner skip checks
                    if corner_behavior == "skip" and corners:
                        too_close = False
                        for crn in corners:
                            if math.hypot(pt[0] - crn[0], pt[1] - crn[1]) < hole_diameter:
                                too_close = True
                                break
                        if too_close:
                            continue
                    
                    hole_centers.append(pt)

    # Write holes to DXF
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
        return {"status": "error", "message": "No renderable geometry found in DXF."}

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
    dwg = svgwrite.Drawing(output_path, size=("100%", "100%"), viewBox=f"{svg_min_x} {svg_min_y} {width} {height}")

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
        "chain_select": op_chain_select
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
