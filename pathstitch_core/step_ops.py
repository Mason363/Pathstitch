"""
step_ops.py

STEP file parsing, triangulation, and face unfolding CLI module for Pathstitch.
"""

import sys
import json
import argparse
import os
import math
from typing import Dict, List, Any, Tuple, Optional
import ezdxf

from OCC.Core.STEPControl import STEPControl_Reader
from OCC.Core.IFSelect import IFSelect_RetDone
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopAbs import TopAbs_SOLID, TopAbs_SHELL, TopAbs_FACE
from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh
from OCC.Core.BRep import BRep_Tool
from OCC.Core.TopLoc import TopLoc_Location
from OCC.Core.GProp import GProp_GProps
from OCC.Core.BRepGProp import brepgprop

from pathstitch_core.surface_unfold import get_surface_type, unfold_face_geometry, save_polylines_to_dxf

def load_step_shape(file_path: str):
    """Loads a STEP file and returns its consolidated shape."""
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"STEP file not found: {file_path}")
        
    reader = STEPControl_Reader()
    status = reader.ReadFile(file_path)
    if status != IFSelect_RetDone:
        raise ValueError(f"STEP control reader failed to read. Status code: {status}")
        
    reader.TransferRoots()
    return reader.OneShape()

def get_solid_bodies(shape) -> List[Any]:
    """Isolates and returns all solid bodies (or shells as fallback)."""
    bodies = []
    
    # 1. Search for Solids
    exp = TopExp_Explorer(shape, TopAbs_SOLID)
    while exp.More():
        bodies.append(exp.Current())
        exp.Next()
        
    # 2. Search for Shells if no Solids found
    if not bodies:
        exp = TopExp_Explorer(shape, TopAbs_SHELL)
        while exp.More():
            bodies.append(exp.Current())
            exp.Next()
            
    # 3. Fallback: treat the entire shape as a single body if it contains any faces
    if not bodies:
        exp = TopExp_Explorer(shape, TopAbs_FACE)
        if exp.More():
            bodies.append(shape)
            
    return bodies

def op_list_bodies(args: Dict[str, Any]) -> Dict[str, Any]:
    """
    Triangulates the STEP file bodies and returns their faces, types,
    and 3D coordinates for rendering in Three.js.
    """
    input_path = args.get("input")
    if not input_path:
        return {"status": "error", "message": "Input path must be specified."}
        
    try:
        shape = load_step_shape(input_path)
        bodies = get_solid_bodies(shape)
        
        bodies_data = []
        global_min = [float("inf"), float("inf"), float("inf")]
        global_max = [float("-inf"), float("-inf"), float("-inf")]
        
        for b_idx, body in enumerate(bodies):
            # Run mesh triangulation (0.3mm linear deflection deflection tolerance is a good speed/detail trade-off)
            BRepMesh_IncrementalMesh(body, 0.05)
            
            faces_list = []
            face_exp = TopExp_Explorer(body, TopAbs_FACE)
            f_idx = 0
            
            while face_exp.More():
                face = face_exp.Current()
                face_exp.Next()
                
                stype = get_surface_type(face)
                
                # Area calculation
                gprops = GProp_GProps()
                brepgprop.SurfaceProperties(face, gprops)
                area = gprops.Mass()
                
                # Retrieve triangulation
                loc = TopLoc_Location()
                tri = BRep_Tool.Triangulation(face, loc)
                
                vertices = []
                indices = []
                
                if tri:
                    trans = loc.Transformation()
                    for i in range(1, tri.NbNodes() + 1):
                        pnt = tri.Node(i).Transformed(trans)
                        px, py, pz = float(pnt.X()), float(pnt.Y()), float(pnt.Z())
                        vertices.extend([px, py, pz])
                        
                        # Update bounding box
                        global_min[0] = min(global_min[0], px)
                        global_min[1] = min(global_min[1], py)
                        global_min[2] = min(global_min[2], pz)
                        
                        global_max[0] = max(global_max[0], px)
                        global_max[1] = max(global_max[1], py)
                        global_max[2] = max(global_max[2], pz)
                        
                    for i in range(1, tri.NbTriangles() + 1):
                        t = tri.Triangle(i)
                        idx1, idx2, idx3 = t.Get()
                        indices.extend([idx1 - 1, idx2 - 1, idx3 - 1])
                
                faces_list.append({
                    "face_index": f_idx,
                    "type": stype,
                    "area": float(area),
                    "vertices": vertices,
                    "indices": indices
                })
                f_idx += 1
                
            bodies_data.append({
                "body_index": b_idx,
                "name": f"Body {b_idx + 1}",
                "faces": faces_list
            })
            
        # If no vertices were found, reset bounding box
        if global_min[0] == float("inf"):
            global_min = [0.0, 0.0, 0.0]
            global_max = [0.0, 0.0, 0.0]
            
        bbox = {
            "min": global_min,
            "max": global_max,
            "center": [
                (global_min[0] + global_max[0]) / 2.0,
                (global_min[1] + global_max[1]) / 2.0,
                (global_min[2] + global_max[2]) / 2.0
            ]
        }
        
        return {
            "status": "ok",
            "data": {
                "bodies": bodies_data,
                "bbox": bbox
            }
        }
        
    except Exception as e:
        import traceback
        return {"status": "error", "message": f"Failed to list solid bodies: {str(e)}\n{traceback.format_exc()}"}

def get_dxf_bounds(msp) -> Optional[Tuple[float, float, float, float]]:
    """Calculates the 2D bounding box of all renderable geometries in the modelspace."""
    from ezdxf.path import make_path
    min_x, min_y = float('inf'), float('inf')
    max_x, max_y = float('-inf'), float('-inf')
    found = False
    
    for ent in msp:
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
                
    if not found:
        return None
    return min_x, min_y, max_x, max_y

def op_unfold_face(args: Dict[str, Any]) -> Dict[str, Any]:
    """
    Unfolds a specific face of a specific body to a DXF flat pattern.
    Appends and arranges to the right of any existing DXF geometry if existing_dxf is provided.
    """
    input_path = args.get("input")
    output_path = args.get("output")
    body_idx = args.get("body_index")
    face_idx = args.get("face_index")
    existing_dxf = args.get("existing_dxf")
    
    if not input_path or not output_path or body_idx is None or face_idx is None:
        return {"status": "error", "message": "Missing required arguments: input, output, body_index, face_index."}
        
    try:
        shape = load_step_shape(input_path)
        bodies = get_solid_bodies(shape)
        
        if body_idx < 0 or body_idx >= len(bodies):
            return {"status": "error", "message": f"Body index {body_idx} out of range. Total bodies: {len(bodies)}."}
            
        body = bodies[body_idx]
        
        # Traverse faces to find the target face index
        face_exp = TopExp_Explorer(body, TopAbs_FACE)
        f_idx = 0
        target_face = None
        
        while face_exp.More():
            face = face_exp.Current()
            face_exp.Next()
            if f_idx == face_idx:
                target_face = face
                break
            f_idx += 1
            
        if target_face is None:
            return {"status": "error", "message": f"Face index {face_idx} out of range for body {body_idx}."}
            
        # Call unfolding engine
        polylines = unfold_face_geometry(target_face)
        if not polylines:
            return {"status": "error", "message": "No geometry returned from unfolding."}
            
        # Calculate 2D bounds of unfolded shape
        min_x = min(pt[0] for poly in polylines for pt in poly)
        max_x = max(pt[0] for poly in polylines for pt in poly)
        min_y = min(pt[1] for poly in polylines for pt in poly)
        
        # Load or create DXF
        if existing_dxf and os.path.exists(existing_dxf):
            doc = ezdxf.readfile(existing_dxf)
            msp = doc.modelspace()
            bounds = get_dxf_bounds(msp)
            if bounds:
                start_x = bounds[2] + 10.0  # 10mm gap
                start_y = bounds[1]         # Align bottom Y
            else:
                start_x = 0.0
                start_y = 0.0
        else:
            doc = ezdxf.new(dxfversion="R2010")
            msp = doc.modelspace()
            start_x = 0.0
            start_y = 0.0
            
        if "UNFOLDED_3D" not in doc.layers:
            doc.layers.new("UNFOLDED_3D", dxfattribs={"color": 6})

        # Translate to correct position and add to layout
        for poly in polylines:
            translated = []
            for pt in poly:
                tx = pt[0] - min_x + start_x
                ty = pt[1] - min_y + start_y
                translated.append((tx, ty))
            if len(translated) >= 2:
                msp.add_lwpolyline(translated, dxfattribs={"layer": "UNFOLDED_3D"})
                
        doc.saveas(output_path)
        
        return {
            "status": "ok",
            "data": {
                "body_index": body_idx,
                "face_index": face_idx,
                "output": output_path,
                "polylines_count": len(polylines)
            }
        }
        
    except Exception as e:
        return {"status": "error", "message": f"Failed to unfold face: {str(e)}"}

def op_unfold_faces(args: Dict[str, Any]) -> Dict[str, Any]:
    """
    Unfolds multiple faces side-by-side and saves to a combined DXF.
    Appends and arranges to the right of any existing DXF geometry if existing_dxf is provided.
    """
    input_path = args.get("input")
    output_path = args.get("output")
    faces_to_unfold = args.get("faces")
    existing_dxf = args.get("existing_dxf")
    
    if not input_path or not output_path or not faces_to_unfold:
        return {"status": "error", "message": "Missing required arguments: input, output, faces."}
        
    try:
        shape = load_step_shape(input_path)
        bodies = get_solid_bodies(shape)
        
        # Load or create DXF
        if existing_dxf and os.path.exists(existing_dxf):
            doc = ezdxf.readfile(existing_dxf)
            msp = doc.modelspace()
            bounds = get_dxf_bounds(msp)
            if bounds:
                current_x_offset = bounds[2] + 10.0  # 10mm gap
                current_y_offset = bounds[1]
            else:
                current_x_offset = 0.0
                current_y_offset = 0.0
        else:
            doc = ezdxf.new(dxfversion="R2010")
            msp = doc.modelspace()
            current_x_offset = 0.0
            current_y_offset = 0.0
            
        if "UNFOLDED_3D" not in doc.layers:
            doc.layers.new("UNFOLDED_3D", dxfattribs={"color": 6})
            
        gap = 10.0 # 10mm gap between unfolded layouts
        unfolded_count = 0
        
        for item in faces_to_unfold:
            body_idx = item.get("body_index")
            face_idx = item.get("face_index")
            if body_idx is None or face_idx is None:
                continue
                
            if body_idx < 0 or body_idx >= len(bodies):
                continue
            body = bodies[body_idx]
            
            # Find face
            face_exp = TopExp_Explorer(body, TopAbs_FACE)
            f_idx = 0
            target_face = None
            while face_exp.More():
                face = face_exp.Current()
                face_exp.Next()
                if f_idx == face_idx:
                    target_face = face
                    break
                f_idx += 1
                
            if target_face is None:
                continue
                
            # Unfold face geometry
            polylines = unfold_face_geometry(target_face)
            if not polylines:
                continue
                
            # Compute 2D bounding box
            min_x = min(pt[0] for poly in polylines for pt in poly)
            max_x = max(pt[0] for poly in polylines for pt in poly)
            min_y = min(pt[1] for poly in polylines for pt in poly)
            
            # Translate to current horizontal offset and align base Y
            translated_polylines = []
            for poly in polylines:
                translated_poly = []
                for pt in poly:
                    tx = pt[0] - min_x + current_x_offset
                    ty = pt[1] - min_y + current_y_offset
                    translated_poly.append((tx, ty))
                translated_polylines.append(translated_poly)
                
            for pts in translated_polylines:
                if len(pts) >= 2:
                    msp.add_lwpolyline(pts, dxfattribs={"layer": "UNFOLDED_3D"})
                    
            width = max_x - min_x
            current_x_offset += width + gap
            unfolded_count += 1
            
        doc.saveas(output_path)
        return {
            "status": "ok",
            "data": {
                "output": output_path,
                "unfolded_count": unfolded_count
            }
        }
    except Exception as e:
        return {"status": "error", "message": f"Failed to unfold multiple faces: {str(e)}"}

def discretize_edge(edge, num_points: int = 30) -> List[Tuple[float, float, float]]:
    from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
    from OCC.Core.BRep import BRep_Tool
    adaptor = BRepAdaptor_Curve(edge)
    first = adaptor.FirstParameter()
    last = adaptor.LastParameter()
    
    if math.isinf(first) or math.isinf(last):
        from OCC.Core.TopExp import TopExp
        v1 = TopExp.FirstVertex(edge)
        v2 = TopExp.LastVertex(edge)
        p1 = BRep_Tool.Pnt(v1)
        p2 = BRep_Tool.Pnt(v2)
        return [(p1.X(), p1.Y(), p1.Z()), (p2.X(), p2.Y(), p2.Z())]
        
    pts = []
    for i in range(num_points):
        t = first + (last - first) * i / (num_points - 1)
        p = adaptor.Value(t)
        pts.append((p.X(), p.Y(), p.Z()))
    return pts

def get_face_plane_basis(face):
    from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
    from OCC.Core.gp import gp_Pnt, gp_Vec
    
    surf = BRepAdaptor_Surface(face)
    u_mid = (surf.FirstUParameter() + surf.LastUParameter()) / 2.0
    v_mid = (surf.FirstVParameter() + surf.LastVParameter()) / 2.0
    
    pnt = gp_Pnt()
    u_vec = gp_Vec()
    v_vec = gp_Vec()
    surf.D1(u_mid, v_mid, pnt, u_vec, v_vec)
    
    normal_vec = u_vec.Crossed(v_vec)
    if normal_vec.Magnitude() < 1e-6:
        normal_vec = gp_Vec(0, 0, 1)
    else:
        normal_vec.Normalize()
        
    u_vec.Normalize()
    v_axis = normal_vec.Crossed(u_vec)
    v_axis.Normalize()
    
    origin = (pnt.X(), pnt.Y(), pnt.Z())
    normal = (normal_vec.X(), normal_vec.Y(), normal_vec.Z())
    u_axis = (u_vec.X(), u_vec.Y(), u_vec.Z())
    v_axis_coords = (v_axis.X(), v_axis.Y(), v_axis.Z())
    
    return origin, normal, u_axis, v_axis_coords

def op_project_edges(args: Dict[str, Any]) -> Dict[str, Any]:
    input_path = args.get("input")
    output_path = args.get("output")
    body_idx = args.get("body_index", 0)
    plane_type = args.get("plane_type", "XY") # "XY", "XZ", "YZ", or "face"
    face_idx = args.get("face_index")
    existing_dxf = args.get("existing_dxf")
    
    if not input_path or not output_path:
        return {"status": "error", "message": "Missing input or output path."}
        
    try:
        shape = load_step_shape(input_path)
        bodies = get_solid_bodies(shape)
        
        if body_idx < 0 or body_idx >= len(bodies):
            return {"status": "error", "message": f"Body index {body_idx} out of range."}
            
        body = bodies[body_idx]
        
        origin = (0.0, 0.0, 0.0)
        normal = (0.0, 0.0, 1.0)
        u_axis = (1.0, 0.0, 0.0)
        v_axis = (0.0, 1.0, 0.0)
        
        if plane_type == "XY":
            pass
        elif plane_type == "XZ":
            normal = (0.0, 1.0, 0.0)
            v_axis = (0.0, 0.0, 1.0)
        elif plane_type == "YZ":
            normal = (1.0, 0.0, 0.0)
            u_axis = (0.0, 1.0, 0.0)
            v_axis = (0.0, 0.0, 1.0)
        elif plane_type == "face" and face_idx is not None:
            face_exp = TopExp_Explorer(body, TopAbs_FACE)
            f_idx = 0
            target_face = None
            while face_exp.More():
                face = face_exp.Current()
                face_exp.Next()
                if f_idx == face_idx:
                    target_face = face
                    break
                f_idx += 1
            if target_face is None:
                return {"status": "error", "message": f"Face index {face_idx} not found."}
            basis = get_face_plane_basis(target_face)
            if basis:
                origin, normal, u_axis, v_axis = basis
                
        from OCC.Core.TopExp import TopExp_Explorer
        from OCC.Core.TopAbs import TopAbs_EDGE
        edge_exp = TopExp_Explorer(body, TopAbs_EDGE)
        polylines = []
        seen_edges = set()
        
        while edge_exp.More():
            edge = edge_exp.Current()
            edge_exp.Next()
            h = edge.this
            if h in seen_edges:
                continue
            seen_edges.add(h)
            
            try:
                pts3d = discretize_edge(edge)
                pts2d = []
                for pt in pts3d:
                    dx = pt[0] - origin[0]
                    dy = pt[1] - origin[1]
                    dz = pt[2] - origin[2]
                    u = dx * u_axis[0] + dy * u_axis[1] + dz * u_axis[2]
                    v = dx * v_axis[0] + dy * v_axis[1] + dz * v_axis[2]
                    pts2d.append((u, v))
                if len(pts2d) >= 2:
                    polylines.append(pts2d)
            except Exception:
                pass
                
        if not polylines:
            return {"status": "error", "message": "No projectable edges found."}
            
        min_x = min(pt[0] for poly in polylines for pt in poly)
        max_x = max(pt[0] for poly in polylines for pt in poly)
        min_y = min(pt[1] for poly in polylines for pt in poly)
        
        if existing_dxf and os.path.exists(existing_dxf):
            doc = ezdxf.readfile(existing_dxf)
            msp = doc.modelspace()
            bounds = get_dxf_bounds(msp)
            if bounds:
                start_x = bounds[2] + 10.0
                start_y = bounds[1]
            else:
                start_x = 0.0
                start_y = 0.0
        else:
            doc = ezdxf.new(dxfversion="R2010")
            msp = doc.modelspace()
            start_x = 0.0
            start_y = 0.0
            
        if "PROJECTED_SKETCH" not in doc.layers:
            doc.layers.new("PROJECTED_SKETCH", dxfattribs={"color": 5})
            
        for poly in polylines:
            translated = []
            for pt in poly:
                tx = pt[0] - min_x + start_x
                ty = pt[1] - min_y + start_y
                translated.append((tx, ty))
            msp.add_lwpolyline(translated, dxfattribs={"layer": "PROJECTED_SKETCH"})
            
        doc.saveas(output_path)
        return {
            "status": "ok",
            "data": {
                "output": output_path,
                "polylines_count": len(polylines)
            }
        }
    except Exception as e:
        import traceback
        return {"status": "error", "message": f"Projection failed: {str(e)}\n{traceback.format_exc()}"}

def main() -> None:
    """CLI entry point for JSON subprocess interactions."""
    parser = argparse.ArgumentParser(description="Pathstitch STEP operations CLI tool.")
    parser.add_argument("--json", type=str, help="JSON execution configuration.")
    args = parser.parse_args()

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
        "list_bodies": op_list_bodies,
        "unfold_face": op_unfold_face,
        "unfold_faces": op_unfold_faces,
        "project_edges": op_project_edges
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
