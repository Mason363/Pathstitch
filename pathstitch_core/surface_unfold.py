"""
surface_unfold.py

Analytical surface unfolding engine for Pathstitch.
Supports planar projection, cylinder unrolling, and cone unrolling.
"""

import math
from typing import List, Tuple, Dict, Any
import ezdxf
import numpy as np

from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.GeomAdaptor import GeomAdaptor_Curve
from OCC.Core.Geom2dAdaptor import Geom2dAdaptor_Curve
from OCC.Core.GeomAbs import GeomAbs_Plane, GeomAbs_Cylinder, GeomAbs_Cone, GeomAbs_Line
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh
from OCC.Core.TopLoc import TopLoc_Location
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
            
        # Check if the curve is a straight line to optimize sampling density
        try:
            is_line = (GeomAdaptor_Curve(curve3d).GetType() == GeomAbs_Line)
        except Exception:
            is_line = False
            
        # Discretize
        pts = []
        samples = 1 if is_line else 30
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
            
        # Check if the UV curve is a straight line to optimize sampling density
        try:
            is_line = (Geom2dAdaptor_Curve(curve2d).GetType() == GeomAbs_Line)
        except Exception:
            is_line = False
            
        pts = []
        samples = 1 if is_line else 30
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

        # The cone unrolling is a nonlinear polar transform (x = L*cos(theta),
        # y = L*sin(theta) with theta = u*sin(alpha)), so a straight line in UV
        # space is only a straight line in the unrolled plane when the angular
        # coordinate u is constant (a radial generator). Edges where u varies
        # (e.g. circular cross-sections, v = const) become arcs and must keep
        # full discretization. Only collapse genuinely radial straight edges.
        is_straight_output = False
        try:
            if Geom2dAdaptor_Curve(curve2d).GetType() == GeomAbs_Line:
                u0 = curve2d.Value(u_start).X()
                u1 = curve2d.Value(u_end).X()
                is_straight_output = abs(u1 - u0) < 1e-9
        except Exception:
            is_straight_output = False

        pts = []
        samples = 1 if is_straight_output else 30
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

# --- Phase 2: doubly-curved flattening via LSCM (MAS-112) -----------------
# Developable faces (plane/cylinder/cone) flatten analytically above. Anything
# else — spheres, B-spline / freeform faces — cannot flatten without distortion
# (Theorema Egregium), so we conformally parameterise the OCC triangulation with
# Least Squares Conformal Maps (Lévy et al. 2002). A single face's mesh is small,
# so a dense numpy least-squares solve suffices — no scipy dependency.

def triangulate_face(face, deflection: float = 0.25):
    """Returns (verts3d, tris) for a face's OCC triangulation. Indices are
    0-based triples; verts are world-space (x, y, z) tuples."""
    BRepMesh_IncrementalMesh(face, deflection)
    loc = TopLoc_Location()
    tri = BRep_Tool.Triangulation(face, loc)
    if tri is None:
        return [], []
    trans = loc.Transformation()
    verts: List[Tuple[float, float, float]] = []
    for i in range(1, tri.NbNodes() + 1):
        p = tri.Node(i).Transformed(trans)
        verts.append((float(p.X()), float(p.Y()), float(p.Z())))
    tris: List[Tuple[int, int, int]] = []
    for i in range(1, tri.NbTriangles() + 1):
        a, b, c = tri.Triangle(i).Get()
        tris.append((a - 1, b - 1, c - 1))
    return verts, tris


def lscm_flatten(verts3d, tris):
    """Least Squares Conformal Map: returns an (N,2) array of 2D coordinates that
    conformally (angle-preserving) flattens the triangle mesh. Two far-apart
    boundary vertices are pinned to fix the translation/rotation/scale gauge, the
    scale set so the pinned pair keeps its true 3D distance."""
    V = np.asarray(verts3d, dtype=float)
    n = len(V)
    if n < 3 or len(tris) == 0:
        raise ValueError("Mesh too small to flatten.")

    rows: List[List[float]] = []   # real/imag rows of the conformal system
    cols2 = 2 * n

    for (i0, i1, i2) in tris:
        p0, p1, p2 = V[i0], V[i1], V[i2]
        e1 = p1 - p0
        d = np.linalg.norm(e1)
        if d < 1e-12:
            continue
        e1 = e1 / d
        nrm = np.cross(p1 - p0, p2 - p0)
        nlen = np.linalg.norm(nrm)
        if nlen < 1e-12:
            continue
        nrm = nrm / nlen
        e2 = np.cross(nrm, e1)
        # Local isometric 2D coords of the triangle.
        x0, y0 = 0.0, 0.0
        x1, y1 = d, 0.0
        x2 = np.dot(p2 - p0, e1)
        y2 = np.dot(p2 - p0, e2)
        dT = abs((x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0))  # 2*area
        if dT < 1e-14:
            continue
        s = math.sqrt(dT)
        # Complex per-vertex coefficients Wj (Lévy LSCM).
        W = [
            ((x2 - x1) / s, (y2 - y1) / s),
            ((x0 - x2) / s, (y0 - y2) / s),
            ((x1 - x0) / s, (y1 - y0) / s),
        ]
        verts = (i0, i1, i2)
        re = [0.0] * cols2
        im = [0.0] * cols2
        for (g, (wx, wy)) in zip(verts, W):
            # U_g = u_g + i v_g; equation sum Wj * U_j = 0.
            re[g] += wx          # Re: wx*u
            re[n + g] += -wy     # Re: -wy*v
            im[g] += wy          # Im: wy*u
            im[n + g] += wx      # Im: wx*v
        rows.append(re)
        rows.append(im)

    if not rows:
        raise ValueError("Degenerate mesh — no valid triangles to flatten.")

    A = np.asarray(rows, dtype=float)

    # Pin two far-apart boundary vertices to remove the gauge freedom.
    loops = boundary_loops(tris)
    boundary = loops[0] if loops else list(range(n))
    pin_a = boundary[0]
    pin_b = max(boundary, key=lambda v: np.linalg.norm(V[v] - V[pin_a]))
    if pin_b == pin_a:
        pin_b = (pin_a + 1) % n
    L = float(np.linalg.norm(V[pin_b] - V[pin_a])) or 1.0

    pinned = {pin_a: (0.0, 0.0), pin_b: (L, 0.0)}
    pin_cols = []
    pin_vals = []
    for g, (pu, pv) in pinned.items():
        pin_cols.extend([g, n + g])
        pin_vals.extend([pu, pv])
    free_cols = [c for c in range(cols2) if c not in set(pin_cols)]

    A_free = A[:, free_cols]
    A_pin = A[:, pin_cols]
    rhs = -A_pin @ np.asarray(pin_vals, dtype=float)

    sol, *_ = np.linalg.lstsq(A_free, rhs, rcond=None)

    full = np.zeros(cols2)
    for c, val in zip(pin_cols, pin_vals):
        full[c] = val
    for c, val in zip(free_cols, sol):
        full[c] = val
    return np.column_stack([full[:n], full[n:]])


def boundary_loops(tris):
    """Ordered boundary vertex loops of a triangle mesh (edges used by exactly
    one triangle), as lists of vertex indices."""
    from collections import defaultdict
    edge_count = defaultdict(int)
    for (a, b, c) in tris:
        for (u, v) in ((a, b), (b, c), (c, a)):
            edge_count[(min(u, v), max(u, v))] += 1
    # Directed boundary edges preserve orientation for loop walking.
    nxt = {}
    for (a, b, c) in tris:
        for (u, v) in ((a, b), (b, c), (c, a)):
            if edge_count[(min(u, v), max(u, v))] == 1:
                nxt[u] = v
    loops = []
    visited = set()
    for start in list(nxt.keys()):
        if start in visited:
            continue
        loop = [start]
        visited.add(start)
        cur = nxt.get(start)
        while cur is not None and cur != start and cur not in visited:
            loop.append(cur)
            visited.add(cur)
            cur = nxt.get(cur)
        if len(loop) >= 3:
            loops.append(loop)
    loops.sort(key=len, reverse=True)
    return loops


def unfold_freeform_face(face) -> List[List[Tuple[float, float]]]:
    """Flattens a doubly-curved face by LSCM and returns its boundary loops as
    2D polylines (MAS-112 Phase 2)."""
    verts, tris = triangulate_face(face)
    if not tris:
        raise ValueError("Face has no triangulation to flatten.")
    uv = lscm_flatten(verts, tris)
    loops = boundary_loops(tris)
    if not loops:
        raise ValueError("Flattened face has no boundary loop.")
    wires: List[List[Tuple[float, float]]] = []
    for loop in loops:
        pts = [(float(uv[i][0]), float(uv[i][1])) for i in loop]
        pts.append(pts[0])   # close the loop
        wires.append(pts)
    return wires


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
        # Doubly-curved / freeform → conformal LSCM flattening (Phase 2).
        return unfold_freeform_face(face)

def save_polylines_to_dxf(wires: List[List[Tuple[float, float]]], output_path: str):
    """Saves lists of 2D points as polylines in a DXF file."""
    doc = ezdxf.new(dxfversion="R2010")
    msp = doc.modelspace()
    
    for pts in wires:
        if len(pts) >= 2:
            msp.add_lwpolyline(pts)
            
    doc.saveas(output_path)
