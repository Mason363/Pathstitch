"""
surface_unfold.py

Analytical surface unfolding engine for Pathstitch.
Supports planar projection, cylinder unrolling, and cone unrolling.
"""

import math
from typing import List, Tuple, Dict, Any
import ezdxf

from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.GeomAbs import GeomAbs_Plane, GeomAbs_Cylinder, GeomAbs_Cone
from OCC.Core.BRep import BRep_Tool
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopAbs import TopAbs_EDGE
from OCC.Core.gp import gp_Pnt, gp_Pnt2d

def get_surface_type(face) -> str:
    """Returns the geometry type of the face surface."""
    try:
        surf = BRepAdaptor_Surface(face)
        stype = surf.GetType()
        if stype == GeomAbs_Plane:
            return "Plane"
        elif stype == GeomAbs_Cylinder:
            return "Cylinder"
        elif stype == GeomAbs_Cone:
            return "Cone"
        else:
            return "Other"
    except Exception:
        return "Unknown"

def unfold_planar_face(face) -> List[List[Tuple[float, float]]]:
    """Projects planar face edges to a local 2D coordinate system."""
    surf = BRepAdaptor_Surface(face)
    plane = surf.Plane()
    pos = plane.Position()
    origin = pos.Location()
    x_dir = pos.XDirection()
    y_dir = pos.YDirection()

    wires_points = []
    # We explore all edges of the face
    # Note: we want to keep edges grouped by wires or simply list all edge segments
    # Grouping by edges is easiest: each edge becomes a 2D polyline segment.
    edge_explorer = TopExp_Explorer(face, TopAbs_EDGE)
    while edge_explorer.More():
        edge = edge_explorer.Current()
        edge_explorer.Next()
        
        # Get 3D curve
        curve3d, u_start, u_end = BRep_Tool.Curve(edge)
        if not curve3d:
            continue
            
        # Discretize
        pts = []
        samples = 30
        for i in range(samples + 1):
            t = u_start + (u_end - u_start) * (i / samples)
            p3d = curve3d.Value(t)
            
            # Project to plane coordinate system
            dx = p3d.X() - origin.X()
            dy = p3d.Y() - origin.Y()
            dz = p3d.Z() - origin.Z()
            
            x = dx * x_dir.X() + dy * x_dir.Y() + dz * x_dir.Z()
            y = dx * y_dir.X() + dy * y_dir.Y() + dz * y_dir.Z()
            
            pts.append((x, y))
        wires_points.append(pts)
        
    return wires_points

def unfold_cylindrical_face(face) -> List[List[Tuple[float, float]]]:
    """Unrolls a cylindrical face boundary and holes from UV space to 2D."""
    surf = BRepAdaptor_Surface(face)
    cylinder = surf.Cylinder()
    R = cylinder.Radius()

    wires_points = []
    edge_explorer = TopExp_Explorer(face, TopAbs_EDGE)
    while edge_explorer.More():
        edge = edge_explorer.Current()
        edge_explorer.Next()
        
        # Get CurveOnSurface
        curve2d, u_start, u_end = BRep_Tool.CurveOnSurface(edge, face)
        if not curve2d:
            continue
            
        pts = []
        samples = 30
        for i in range(samples + 1):
            t = u_start + (u_end - u_start) * (i / samples)
            p2d = curve2d.Value(t)
            u, v = p2d.X(), p2d.Y()
            
            # Transform UV to cylindrical unrolled 2D space
            x = R * u
            y = v
            pts.append((x, y))
        wires_points.append(pts)
        
    return wires_points

def unfold_conical_face(face) -> List[List[Tuple[float, float]]]:
    """Unrolls a conical face boundary and holes from UV space to 2D."""
    surf = BRepAdaptor_Surface(face)
    cone = surf.Cone()
    R = cone.RefRadius()
    alpha = cone.SemiAngle() # In radians
    
    if abs(alpha) < 1e-6:
        # Falls back to cylinder if angle is zero
        return unfold_cylindrical_face(face)

    wires_points = []
    edge_explorer = TopExp_Explorer(face, TopAbs_EDGE)
    while edge_explorer.More():
        edge = edge_explorer.Current()
        edge_explorer.Next()
        
        # Get CurveOnSurface
        curve2d, u_start, u_end = BRep_Tool.CurveOnSurface(edge, face)
        if not curve2d:
            continue
            
        pts = []
        samples = 30
        for i in range(samples + 1):
            t = u_start + (u_end - u_start) * (i / samples)
            p2d = curve2d.Value(t)
            u, v = p2d.X(), p2d.Y()
            
            # L is distance from apex along generator line
            L = R / math.sin(alpha) + v
            # Theta is angle in the unrolled plane
            theta = u * math.sin(alpha)
            
            x = L * math.cos(theta)
            y = L * math.sin(theta)
            pts.append((x, y))
        wires_points.append(pts)
        
    return wires_points

def unfold_face_geometry(face) -> List[List[Tuple[float, float]]]:
    """Main router to unfold a face and return list of 2D polylines."""
    stype = get_surface_type(face)
    if stype == "Plane":
        return unfold_planar_face(face)
    elif stype == "Cylinder":
        return unfold_cylindrical_face(face)
    elif stype == "Cone":
        return unfold_conical_face(face)
    else:
        raise ValueError(f"Surface type '{stype}' is not analytically developable / supported.")

def save_polylines_to_dxf(wires: List[List[Tuple[float, float]]], output_path: str):
    """Saves lists of 2D points as polylines in a DXF file."""
    doc = ezdxf.new(dxfversion="R2010")
    msp = doc.modelspace()
    
    for pts in wires:
        if len(pts) >= 2:
            msp.add_lwpolyline(pts)
            
    doc.saveas(output_path)
