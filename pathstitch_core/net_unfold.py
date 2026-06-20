"""
net_unfold.py

Connected-net unfolding engine for Pathstitch.

Unlike `op_unfold_face`/`op_unfold_faces` (which flatten faces independently and
lay them side by side), this module unfolds a *set* of faces as one connected
net: a spanning tree is chosen over the face-adjacency graph, tree edges become
fold (crease) lines and every other edge becomes a cut (seam) line. Faces are
rolled out by rigidly aligning each child face's image of the shared edge onto
its parent's — exact (zero-distortion) for every developable surface OCC can
parameterise analytically: planes, cylinders and cones.

An edge may serve as a fold only when its 2D image is straight in BOTH faces'
unfoldings (a cube edge qualifies; the circular junction between a cylinder
wall and its flat cap does not — paper can't fold along a curve that differs
between the two pieces, so it is forced to be a seam).

Overlapping rollouts are detected with shapely and resolved by cutting the
offending tree edge, which starts a new patch placed beside the previous one.

Layer scheme of the emitted DXF (colors are ACI):
    SEAM_CUT  (red, 1)    — cut edges; the physical outline of every piece
    CREASE    (blue, 5)   — fold lines, dashed
    GLUE_TABS (green, 3)  — optional outward glue tabs on seam pairs
    SEW_HOLES (green, 3)  — optional inward sewing holes on seam pairs
"""

import math
from typing import Dict, List, Any, Tuple, Optional

import ezdxf

from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_EDGE
from OCC.Core.TopoDS import topods
from OCC.Core.TopTools import TopTools_IndexedMapOfShape
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepTools import breptools, BRepTools_WireExplorer
from OCC.Core.GeomAbs import GeomAbs_Plane, GeomAbs_Cylinder, GeomAbs_Cone
from OCC.Core.GProp import GProp_GProps
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepLProp import BRepLProp_SLProps
from OCC.Core.TopLoc import TopLoc_Location
import numpy as np
from pathstitch_core.surface_unfold import triangulate_face, parameterize_mesh

EDGE_SAMPLES = 24
GAP = 10.0  # mm between disconnected patches
STRAIGHT_REL_TOL = 1e-3


# ---------------------------------------------------------------------------
# Per-face isometric UV → 2D mappings
# ---------------------------------------------------------------------------

def _surface_kind(face) -> str:
    try:
        stype = BRepAdaptor_Surface(face).GetType()
    except Exception:
        return "Other"
    if stype == GeomAbs_Plane:
        return "Plane"
    if stype == GeomAbs_Cylinder:
        return "Cylinder"
    if stype == GeomAbs_Cone:
        return "Cone"
    return "Other"


def _uv_mapper(face, kind, surf=None):
    """Returns fn(u, v) -> (x, y), an isometry from the surface to the plane.

    Plane UV is already Cartesian; cylinder unrolls by arc length (R·u, v);
    cone unrolls into a circular sector around its apex.
    """
    if surf is None:
        surf = BRepAdaptor_Surface(face)
    if kind == "Plane":
        return lambda u, v: (u, v)
    if kind == "Cylinder":
        R = surf.Cylinder().Radius()
        return lambda u, v: (R * u, v)
    if kind == "Cone":
        cone = surf.Cone()
        R = cone.RefRadius()
        alpha = cone.SemiAngle()
        if abs(alpha) < 1e-9:
            return lambda u, v: (R * u, v)
        slant0 = R / math.sin(alpha)

        def mapper(u, v):
            L = slant0 + v
            theta = u * math.sin(alpha)
            return (L * math.cos(theta), L * math.sin(theta))

        return mapper
    raise ValueError(f"Not developable: {kind}")


def _surface_normal(surf, u, v) -> Tuple[float, float, float]:
    try:
        props = BRepLProp_SLProps(1, 1e-6)
        props.SetSurface(surf)
        props.SetParameters(u, v)
        if props.IsNormalDefined():
            n = props.Normal()
            return (float(n.X()), float(n.Y()), float(n.Z()))
    except Exception:
        pass
    return (0.0, 0.0, 1.0)


class MeshMapper:
    def __init__(self, face, distortion_mode="conformal"):
        verts3d, tris = triangulate_face(face)
        if not tris:
            raise ValueError("Face has no triangulation.")
            
        loc = TopLoc_Location()
        tri = BRep_Tool.Triangulation(face, loc)
        uv_nodes = []
        for i in range(1, tri.NbNodes() + 1):
            p2d = tri.UVNode(i)
            uv_nodes.append((p2d.X(), p2d.Y()))
        self.uv_nodes = np.array(uv_nodes)
        
        self.uv2d = parameterize_mesh(verts3d, tris, distortion_mode)
        self.tris = tris

    def __call__(self, u, v):
        p = np.array([u, v])
        for (i0, i1, i2) in self.tris:
            a = self.uv_nodes[i0]
            b = self.uv_nodes[i1]
            c = self.uv_nodes[i2]
            
            v0 = b - a
            v1 = c - a
            v2 = p - a
            
            den = v0[0]*v1[1] - v1[0]*v0[1]
            if abs(den) < 1e-12:
                continue
                
            v_coord = (v2[0]*v1[1] - v1[0]*v2[1]) / den
            w_coord = (v0[0]*v2[1] - v2[0]*v0[1]) / den
            u_coord = 1.0 - v_coord - w_coord
            
            if u_coord >= -1e-4 and v_coord >= -1e-4 and w_coord >= -1e-4:
                p0_2d = self.uv2d[i0]
                p1_2d = self.uv2d[i1]
                p2_2d = self.uv2d[i2]
                xy = u_coord*p0_2d + v_coord*p1_2d + w_coord*p2_2d
                return (float(xy[0]), float(xy[1]))
                
        dists = np.sum((self.uv_nodes - p)**2, axis=1)
        idx = np.argmin(dists)
        return (float(self.uv2d[idx][0]), float(self.uv2d[idx][1]))


def _sample_edge(edge, face, mapper, surf=None) -> Optional[Dict[str, Any]]:
    """Samples one edge of `face`: matched lists of 2D (unfolded) and 3D points, plus normal at midpoint."""
    try:
        curve2d, t0, t1 = BRep_Tool.CurveOnSurface(edge, face)
    except Exception:
        return None
    if curve2d is None:
        return None
    if surf is None:
        surf = BRepAdaptor_Surface(face)
    pts2d: List[Tuple[float, float]] = []
    pts3d: List[Tuple[float, float, float]] = []
    
    t_mid = t0 + (t1 - t0) * 0.5
    p_mid = curve2d.Value(t_mid)
    normal = _surface_normal(surf, p_mid.X(), p_mid.Y())
    
    for i in range(EDGE_SAMPLES + 1):
        t = t0 + (t1 - t0) * (i / EDGE_SAMPLES)
        p = curve2d.Value(t)
        u, v = p.X(), p.Y()
        pts2d.append(mapper(u, v))
        p3 = surf.Value(u, v)
        pts3d.append((p3.X(), p3.Y(), p3.Z()))
    return {"pts2d": pts2d, "pts3d": pts3d, "normal": normal}


def _is_straight(pts: List[Tuple[float, float]]) -> bool:
    """True when the polyline stays within tolerance of its chord."""
    (x0, y0), (x1, y1) = pts[0], pts[-1]
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy)
    if length < 1e-9:
        return False
    tol = max(1e-5, STRAIGHT_REL_TOL * length)
    for (px, py) in pts[1:-1]:
        # Perpendicular distance from chord
        d = abs((px - x0) * dy - (py - y0) * dx) / length
        if d > tol:
            return False
    return True


def _polyline_length(pts) -> float:
    return sum(math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1])
               for i in range(len(pts) - 1))


# ---------------------------------------------------------------------------
# 2D rigid transforms (rotation + translation, optional mirror)
# ---------------------------------------------------------------------------

class Rigid2D:
    """x' = R·(x mirrored?) + t, with R a pure rotation."""

    def __init__(self, cos_a=1.0, sin_a=0.0, tx=0.0, ty=0.0, mirror=False):
        self.c, self.s, self.tx, self.ty, self.m = cos_a, sin_a, tx, ty, mirror

    def apply(self, p):
        x, y = p
        if self.m:
            y = -y
        return (self.c * x - self.s * y + self.tx,
                self.s * x + self.c * y + self.ty)

    def apply_all(self, pts):
        return [self.apply(p) for p in pts]

    @staticmethod
    def aligning(a_src, b_src, a_dst, b_dst, mirror):
        """Maps segment (a_src→b_src) onto (a_dst→b_dst); lengths must agree."""
        ax, ay = a_src
        if mirror:
            ay = -ay
        bx, by = b_src
        if mirror:
            by = -by
        v_src = (bx - ax, by - ay)
        v_dst = (b_dst[0] - a_dst[0], b_dst[1] - a_dst[1])
        ls = math.hypot(*v_src)
        ld = math.hypot(*v_dst)
        if ls < 1e-12 or ld < 1e-12:
            return Rigid2D(mirror=mirror)
        # Rotation taking v_src to v_dst direction
        cos_a = (v_src[0] * v_dst[0] + v_src[1] * v_dst[1]) / (ls * ld)
        sin_a = (v_src[0] * v_dst[1] - v_src[1] * v_dst[0]) / (ls * ld)
        tx = a_dst[0] - (cos_a * ax - sin_a * ay)
        ty = a_dst[1] - (sin_a * ax + cos_a * ay)
        return Rigid2D(cos_a, sin_a, tx, ty, mirror)


def _side_of(a, b, p) -> float:
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])


def _centroid(pts):
    n = max(len(pts), 1)
    return (sum(p[0] for p in pts) / n, sum(p[1] for p in pts) / n)


# ---------------------------------------------------------------------------
# Face record extraction
# ---------------------------------------------------------------------------

def _face_area(face) -> float:
    g = GProp_GProps()
    brepgprop.SurfaceProperties(face, g)
    return g.Mass()


def _outer_wire_polygon(face, mapper, surf=None) -> List[Tuple[float, float]]:
    """Ordered 2D polygon of the face's outer wire (pragmatically chained)."""
    try:
        wire = breptools.OuterWire(face)
    except Exception:
        return []
    chains: List[List[Tuple[float, float]]] = []
    wexp = BRepTools_WireExplorer(wire, face)
    while wexp.More():
        edge = wexp.Current()
        wexp.Next()
        rec = _sample_edge(edge, face, mapper, surf=surf)
        if rec:
            chains.append(rec["pts2d"])
    poly: List[Tuple[float, float]] = []
    for pts in chains:
        if not poly:
            poly.extend(pts)
            continue
        tail = poly[-1]
        d_fwd = math.hypot(pts[0][0] - tail[0], pts[0][1] - tail[1])
        d_rev = math.hypot(pts[-1][0] - tail[0], pts[-1][1] - tail[1])
        seg = pts if d_fwd <= d_rev else list(reversed(pts))
        poly.extend(seg[1:])
    return poly


def _collect_faces(body) -> List[Any]:
    """Faces of `body` in the same explorer order the UI's face indices use."""
    faces = []
    exp = TopExp_Explorer(body, TopAbs_FACE)
    while exp.More():
        faces.append(topods.Face(exp.Current()))
        exp.Next()
    return faces


def _build_records(body, wanted: Optional[set], distortion_mode: str = "conformal") -> Tuple[Dict[int, Dict], Dict[int, List[int]], List[Dict]]:
    """Extracts unfold data for the wanted faces of one body.

    Returns (face_records, edge_to_faces, skipped):
      face_records[f_idx] = {kind, area, polygon, edges: [
          {eid, pts2d, pts3d, straight, length, is_seam, degenerated}]}
      edge_to_faces[eid] = [f_idx, ...] (wanted faces only)
    """
    emap = TopTools_IndexedMapOfShape()
    # PRE-POPULATE all edges of the body to guarantee stable, absolute IDs!
    edge_exp = TopExp_Explorer(body, TopAbs_EDGE)
    while edge_exp.More():
        emap.Add(topods.Edge(edge_exp.Current()))
        edge_exp.Next()

    records: Dict[int, Dict] = {}
    edge_to_faces: Dict[int, List[int]] = {}
    skipped: List[Dict] = []

    for f_idx, face in enumerate(_collect_faces(body)):
        if wanted is not None and f_idx not in wanted:
            continue
        kind = _surface_kind(face)
        if kind == "Other":
            try:
                mapper = MeshMapper(face, distortion_mode)
                surf = BRepAdaptor_Surface(face)
            except Exception as e:
                skipped.append({"face_index": f_idx, "type": f"Other (Flattening failed: {str(e)})"})
                continue
        else:
            surf = BRepAdaptor_Surface(face)
            mapper = _uv_mapper(face, kind, surf=surf)

        edges = []
        eexp = TopExp_Explorer(face, TopAbs_EDGE)
        while eexp.More():
            edge = topods.Edge(eexp.Current())
            eexp.Next()
            degenerated = BRep_Tool.Degenerated(edge)
            rec = None if degenerated else _sample_edge(edge, face, mapper, surf=surf)
            if rec is None:
                continue
            eid = emap.Add(edge)
            is_seam = bool(BRep_Tool.IsClosed(edge, face))
            edges.append({
                "eid": eid,
                "pts2d": rec["pts2d"],
                "pts3d": rec["pts3d"],
                "straight": _is_straight(rec["pts2d"]),
                "length": _polyline_length(rec["pts2d"]),
                "is_seam": is_seam,
                "normal": rec["normal"],
            })
            if not is_seam:
                edge_to_faces.setdefault(eid, [])
                if f_idx not in edge_to_faces[eid]:
                    edge_to_faces[eid].append(f_idx)

        records[f_idx] = {
            "kind": kind,
            "area": _face_area(face),
            "polygon": _outer_wire_polygon(face, mapper, surf=surf),
            "edges": edges,
        }
        if kind == "Other":
            verts3d, _ = triangulate_face(face)
            records[f_idx]["uv2d"] = mapper.uv2d.tolist()
            records[f_idx]["tris"] = mapper.tris
            records[f_idx]["verts3d"] = verts3d
            
    return records, edge_to_faces, skipped


# ---------------------------------------------------------------------------
# Spanning forest + rollout
# ---------------------------------------------------------------------------

def _fold_candidates(records, edge_to_faces, forced_seams=None, forbidden_seams=None) -> Dict[int, List[Tuple[int, int, float]]]:
    """adjacency[f] = [(neighbor_face, eid, shared_edge_length)], fold-eligible only."""
    if forced_seams is None:
        forced_seams = set()
    if forbidden_seams is None:
        forbidden_seams = set()

    adj: Dict[int, List[Tuple[int, int, float]]] = {f: [] for f in records}
    for eid, faces in edge_to_faces.items():
        if len(faces) != 2:
            continue
        # Drop forced seams from fold candidate adjacency
        if eid in forced_seams:
            continue
            
        fa, fb = faces
        ra = next(e for e in records[fa]["edges"] if e["eid"] == eid)
        rb = next(e for e in records[fb]["edges"] if e["eid"] == eid)
        # Foldable only if straight in BOTH unfoldings
        if not (ra["straight"] and rb["straight"]):
            continue
            
        length = min(ra["length"], rb["length"])
        
        # Curvature weights: prefer flatter folds (dihedral angle close to 0)
        na = ra.get("normal", (0.0, 0.0, 1.0))
        nb = rb.get("normal", (0.0, 0.0, 1.0))
        cos_theta = na[0]*nb[0] + na[1]*nb[1] + na[2]*nb[2]
        weight = length * (1.0 + cos_theta)
        
        # Pin forbidden seams (forced folds) into spanning tree by boosting weight
        if eid in forbidden_seams:
            weight = weight + 1e6
            
        adj[fa].append((fb, eid, weight))
        adj[fb].append((fa, eid, weight))
    return adj


def _spanning_order(records, adj, anchor: int, mode: str) -> List[Tuple[int, Optional[int], Optional[int]]]:
    """Orders faces for rollout as (face, parent_face|None, fold_eid|None).

    radial   — BFS from the anchor: faces unroll outward in rings (petal net)
    strip    — greedy DFS, longest shared edge first: long chains/strips
    spanning — Prim's maximum-weight tree: prefers the longest (most stable,
               least error-prone) fold edges overall
    """
    order: List[Tuple[int, Optional[int], Optional[int]]] = []
    visited = set()

    def visit_component(root):
        visited.add(root)
        order.append((root, None, None))
        if mode == "strip":
            stack = [root]
            while stack:
                f = stack[-1]
                nbrs = [(l, n, e) for (n, e, l) in adj.get(f, []) if n not in visited]
                if not nbrs:
                    stack.pop()
                    continue
                l, n, e = max(nbrs)
                visited.add(n)
                order.append((n, f, e))
                stack.append(n)
        elif mode == "spanning":
            import heapq
            heap = [(-l, eid, root, n) for (n, eid, l) in adj.get(root, [])]
            heapq.heapify(heap)
            while heap:
                negl, eid, par, n = heapq.heappop(heap)
                if n in visited:
                    continue
                visited.add(n)
                order.append((n, par, eid))
                for (n2, e2, l2) in adj.get(n, []):
                    if n2 not in visited:
                        heapq.heappush(heap, (-l2, e2, n, n2))
        else:  # radial (BFS)
            queue = [root]
            while queue:
                f = queue.pop(0)
                nbrs = sorted(adj.get(f, []), key=lambda t: -t[2])
                for (n, eid, _l) in nbrs:
                    if n not in visited:
                        visited.add(n)
                        order.append((n, f, eid))
                        queue.append(n)

    if anchor in records:
        visit_component(anchor)
    # Remaining components (disconnected selections): largest face first
    for f in sorted(records, key=lambda f: -records[f]["area"]):
        if f not in visited:
            visit_component(f)
    return order


def _edge_record(records, f, eid):
    return next(e for e in records[f]["edges"] if e["eid"] == eid)


def _rollout(records, order):
    """Places each face in the plane; cuts tree edges whose child would overlap.

    Returns (placements, fold_pairs, patch_of_face):
      placements[f] = Rigid2D
      fold_pairs    = [(parent, child, eid)] folds actually kept
      patch_of_face = {f: patch_index}
    """
    try:
        from shapely.geometry import Polygon
        from shapely.ops import unary_union
        have_shapely = True
    except Exception:
        have_shapely = False

    placements: Dict[int, Rigid2D] = {}
    fold_pairs: List[Tuple[int, int, int]] = []
    patch_of_face: Dict[int, int] = {}
    patch_unions: Dict[int, Any] = {}
    next_patch = 0

    def face_shape(f, xf):
        poly = records[f]["polygon"]
        if len(poly) < 3:
            return None
        try:
            shp = Polygon(xf.apply_all(poly))
            if not shp.is_valid:
                shp = shp.buffer(0)
            return shp
        except Exception:
            return None

    for (f, parent, eid) in order:
        if parent is None or parent not in placements:
            xf = Rigid2D()
            patch = next_patch
            next_patch += 1
        else:
            ra = _edge_record(records, parent, eid)
            rb = _edge_record(records, f, eid)
            # Match endpoints through their shared 3D edge points
            pa0, pa1 = ra["pts3d"][0], ra["pts3d"][-1]
            pb0 = rb["pts3d"][0]
            d00 = sum((pa0[i] - pb0[i]) ** 2 for i in range(3))
            d10 = sum((pa1[i] - pb0[i]) ** 2 for i in range(3))
            parent_xf = placements[parent]
            a_dst = parent_xf.apply(ra["pts2d"][0])
            b_dst = parent_xf.apply(ra["pts2d"][-1])
            if d00 > d10:  # child's first sample matches parent's LAST endpoint
                a_dst, b_dst = b_dst, a_dst
            a_src, b_src = rb["pts2d"][0], rb["pts2d"][-1]

            parent_c = parent_xf.apply(_centroid(records[parent]["polygon"]))
            child_c_local = _centroid(records[f]["polygon"])
            best = None
            for mirror in (False, True):
                cand = Rigid2D.aligning(a_src, b_src, a_dst, b_dst, mirror)
                child_c = cand.apply(child_c_local)
                s_child = _side_of(a_dst, b_dst, child_c)
                s_parent = _side_of(a_dst, b_dst, parent_c)
                if s_child * s_parent < 0:  # opposite sides of fold: correct
                    best = cand
                    break
                if best is None:
                    best = cand
            xf = best
            patch = patch_of_face[parent]

            # Overlap → cut here, start a fresh patch
            if have_shapely:
                shp = face_shape(f, xf)
                union = patch_unions.get(patch)
                if shp is not None and union is not None:
                    inter = union.intersection(shp).area
                    if inter > max(1e-6, 0.005 * shp.area):
                        xf = Rigid2D()
                        patch = next_patch
                        next_patch += 1
                        parent = None  # the fold is cut
            if parent is not None:
                fold_pairs.append((parent, f, eid))

        placements[f] = xf
        patch_of_face[f] = patch
        if have_shapely:
            shp = face_shape(f, xf)
            if shp is not None:
                u = patch_unions.get(patch)
                patch_unions[patch] = shp if u is None else unary_union([u, shp])

    return placements, fold_pairs, patch_of_face


# ---------------------------------------------------------------------------
# Decorations
# ---------------------------------------------------------------------------

def _resample(pts, step_hint=0.5):
    """Arc-length parameterisation helpers: returns (cumlen, total)."""
    cum = [0.0]
    for i in range(len(pts) - 1):
        cum.append(cum[-1] + math.hypot(pts[i + 1][0] - pts[i][0],
                                        pts[i + 1][1] - pts[i][1]))
    return cum, cum[-1]


def _point_at(pts, cum, s):
    """Point and unit tangent at arc length s along polyline pts."""
    s = min(max(s, 0.0), cum[-1])
    for i in range(len(cum) - 1):
        if cum[i + 1] >= s:
            seg = cum[i + 1] - cum[i]
            t = 0.0 if seg < 1e-12 else (s - cum[i]) / seg
            px = pts[i][0] + (pts[i + 1][0] - pts[i][0]) * t
            py = pts[i][1] + (pts[i + 1][1] - pts[i][1]) * t
            tx, ty = pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]
            tl = math.hypot(tx, ty) or 1.0
            return (px, py), (tx / tl, ty / tl)
    return pts[-1], (1.0, 0.0)


def _interior_side(pts2d, cum, face_poly) -> float:
    """+1 if the face interior lies to the LEFT of the edge's travel direction,
    -1 if to the right. Sampled at the midpoint; the side is constant along an
    edge of a simple face outline, so local normals can reuse it everywhere
    (a single fixed normal direction is wrong for curved edges)."""
    mid, tang = _point_at(pts2d, cum, cum[-1] / 2.0)
    left = (-tang[1], tang[0])
    probe = 0.05 * max(cum[-1], 1.0)
    try:
        from shapely.geometry import Point, Polygon
        poly = Polygon(face_poly)
        p_left = Point(mid[0] + left[0] * probe, mid[1] + left[1] * probe)
        return 1.0 if poly.buffer(probe * 0.5).contains(p_left) else -1.0
    except Exception:
        c = _centroid(face_poly)
        d = (c[0] - mid[0], c[1] - mid[1])
        return 1.0 if (left[0] * d[0] + left[1] * d[1]) >= 0 else -1.0


def _local_normal(pts2d, cum, s, side) -> Tuple[Tuple[float, float], Tuple[float, float]]:
    """(point, unit normal toward `side`) at arc length s along the edge."""
    p, tang = _point_at(pts2d, cum, s)
    return p, (-tang[1] * side, tang[0] * side)


def _glue_tab(pts2d, face_poly, height):
    """Outward trapezoidal tab along the (possibly curved) edge polyline."""
    cum, total = _resample(pts2d)
    if total < 1e-6:
        return None
    h = min(height, total / 3.0)
    out_side = -_interior_side(pts2d, cum, face_poly)
    tab = [pts2d[0]]
    n_steps = max(4, len(pts2d) // 2)
    for i in range(n_steps + 1):
        s = h + (total - 2 * h) * (i / n_steps)
        p, n = _local_normal(pts2d, cum, s, out_side)
        tab.append((p[0] + n[0] * h, p[1] + n[1] * h))
    tab.append(pts2d[-1])
    return tab


def _sew_holes(pts2d, face_poly, diameter, spacing, margin):
    """Hole centers inset INTO the face along the edge polyline."""
    cum, total = _resample(pts2d)
    if total < spacing:
        return []
    in_side = _interior_side(pts2d, cum, face_poly)
    holes = []
    s = spacing / 2.0
    while s <= total - spacing / 2.0 + 1e-9:
        p, n = _local_normal(pts2d, cum, s, in_side)
        holes.append(((p[0] + n[0] * margin, p[1] + n[1] * margin),
                      diameter / 2.0))
        s += spacing
    return holes


# ---------------------------------------------------------------------------
# DXF assembly
# ---------------------------------------------------------------------------
def _ensure_layers(doc):
    specs = [("SEAM_CUT", 1, "CONTINUOUS"), ("CREASE", 5, "DASHED"),
             ("GLUE_TABS", 3, "CONTINUOUS"), ("SEW_HOLES", 3, "CONTINUOUS"),
             ("DISTORTION", 7, "CONTINUOUS")]
    if "DASHED" not in doc.linetypes:
        doc.linetypes.add("DASHED", pattern=[0.75, 0.5, -0.25])
    for name, color, lt in specs:
        if name not in doc.layers:
            doc.layers.new(name, dxfattribs={"color": color, "linetype": lt})


def unfold_connected(body, wanted: Optional[set], mode: str, anchor: Optional[int],
                      decoration: str, deco_params: Dict[str, float],
                      distortion_mode: str = "conformal",
                      forced_seams: Optional[set] = None,
                      forbidden_seams: Optional[set] = None,
                      seam_decorations: Optional[Dict[int, str]] = None):
    """Runs the full pipeline for one body. Returns (draw_ops, stats, skipped).

    draw_ops: list of ("polyline"|"circle"|"solid", layer, payload) in net coordinates.
    """
    records, edge_to_faces, skipped = _build_records(body, wanted, distortion_mode)
    if not records:
        return [], {"patches": 0, "faces": 0, "folds": 0, "seams": 0}, skipped

    if anchor is None or anchor not in records:
        anchor = max(records, key=lambda f: records[f]["area"])

    adj = _fold_candidates(records, edge_to_faces, forced_seams, forbidden_seams)
    order = _spanning_order(records, adj, anchor, mode)
    placements, fold_pairs, patch_of_face = _rollout(records, order)

    placed_rank = {f: i for i, (f, _p, _e) in enumerate(order)}
    fold_eids = {(min(a, b), max(a, b), e) for (a, b, e) in fold_pairs}
    fold_edge_ids = {e for (_a, _b, e) in fold_pairs}

    # draw_ops entries: (kind, layer, payload, patch_index_or_tuple)
    draw_ops: List[Tuple[str, str, Any, Any]] = []
    n_seams = 0

    seam_instance_seen: set = set()
    for f, rec in records.items():
        xf = placements[f]
        patch = patch_of_face[f]
        face_poly_placed = xf.apply_all(rec["polygon"])
        
        # If this is a curved face, add solid triangle fills on the DISTORTION layer
        if rec["kind"] == "Other" and "tris" in rec:
            tris = rec["tris"]
            uv2d = np.array(rec["uv2d"])
            verts3d = np.array(rec["verts3d"])
            uv2d_placed = np.array(xf.apply_all(rec["uv2d"]))
            
            for (i0, i1, i2) in tris:
                p0_3d, p1_3d, p2_3d = verts3d[i0], verts3d[i1], verts3d[i2]
                a3d = 0.5 * np.linalg.norm(np.cross(p1_3d - p0_3d, p2_3d - p0_3d))
                a3d = max(a3d, 1e-12)
                
                p0_2d, p1_2d, p2_2d = uv2d_placed[i0], uv2d_placed[i1], uv2d_placed[i2]
                a2d = 0.5 * abs((p1_2d[0] - p0_2d[0]) * (p2_2d[1] - p0_2d[1]) - (p2_2d[0] - p0_2d[0]) * (p1_2d[1] - p0_2d[1]))
                a2d = max(a2d, 1e-12)
                
                dist = max(a2d / a3d, a3d / a2d) - 1.0
                if dist < 0.02:
                    aci = 5 # Blue
                elif dist < 0.1:
                    aci = 3 # Green
                else:
                    aci = 1 # Red
                
                draw_ops.append(("solid", "DISTORTION", [p0_2d, p1_2d, p2_2d], (patch, aci)))

        for e in rec["edges"]:
            placed = xf.apply_all(e["pts2d"])
            partner = [o for o in edge_to_faces.get(e["eid"], []) if o != f]
            is_fold = False
            if e["eid"] in fold_edge_ids and partner:
                key = (min(f, partner[0]), max(f, partner[0]), e["eid"])
                if key in fold_eids:
                    is_fold = True
            if is_fold:
                # Folds are shared geometry: draw once, from the earlier face
                if placed_rank[f] < placed_rank[partner[0]]:
                    draw_ops.append(("polyline", "CREASE", placed, patch))
                continue

            draw_ops.append(("polyline", "SEAM_CUT", placed, patch))
            n_seams += 1

            # Decorations only where both mating pieces are in the net: either a
            # seam *pair* between two faces, or a closure seam where a rolled
            # surface (cylinder/cone wall) mates with itself.
            mated = bool(partner and partner[0] in placements)
            if e["is_seam"]:
                mated = True
            if mated:
                edge_deco = seam_decorations.get(e["eid"], decoration) if seam_decorations else decoration
                if edge_deco == "tabs":
                    # One tab per mating pair: the earlier-placed face's
                    # instance, or the first-seen instance of a closure seam.
                    first_instance = (e["is_seam"] and
                                      (f, e["eid"]) not in seam_instance_seen)
                    if e["is_seam"]:
                        seam_instance_seen.add((f, e["eid"]))
                    earlier = (not e["is_seam"] and partner and
                               placed_rank[f] < placed_rank[partner[0]])
                    if first_instance or earlier:
                        tab = _glue_tab(placed, face_poly_placed,
                                        deco_params.get("tab_height", 8.0))
                        if tab:
                            draw_ops.append(("polyline", "GLUE_TABS", tab, patch))
                elif edge_deco == "holes":
                    for (c, r) in _sew_holes(placed, face_poly_placed,
                                             deco_params.get("hole_diameter", 2.0),
                                             deco_params.get("hole_spacing", 8.0),
                                             deco_params.get("hole_margin", 4.0)):
                        draw_ops.append(("circle", "SEW_HOLES", (c, r), patch))

    # Lay disconnected patches out left → right (offset computed over ALL the
    # patch's drawn geometry so tabs/holes can't poke outside the slot)
    patch_pts: Dict[int, List[Tuple[float, float]]] = {}
    for (kind, _layer, payload, patch) in draw_ops:
        p_idx = patch[0] if isinstance(patch, tuple) else patch
        if kind == "circle":
            (cx, cy), r = payload
            patch_pts.setdefault(p_idx, []).extend(
                [(cx - r, cy - r), (cx + r, cy + r)])
        elif kind == "solid":
            patch_pts.setdefault(p_idx, []).extend(payload)
        else:
            patch_pts.setdefault(p_idx, []).extend(payload)
            
    offsets: Dict[int, Tuple[float, float]] = {}
    cursor = 0.0
    for p in sorted(patch_pts):
        xs = [q[0] for q in patch_pts[p]]
        ys = [q[1] for q in patch_pts[p]]
        offsets[p] = (cursor - min(xs), -min(ys))
        cursor += (max(xs) - min(xs)) + GAP

    shifted: List[Tuple[str, str, Any]] = []
    for (kind, layer, payload, patch) in draw_ops:
        p_idx = patch[0] if isinstance(patch, tuple) else patch
        ox, oy = offsets.get(p_idx, (0.0, 0.0))
        if kind == "circle":
            (cx, cy), r = payload
            shifted.append((kind, layer, ((cx + ox, cy + oy), r)))
        elif kind == "solid":
            pts = [(x + ox, y + oy) for (x, y) in payload]
            aci = patch[1]
            shifted.append((kind, layer, (pts, aci)))
        else:
            shifted.append((kind, layer, [(x + ox, y + oy) for (x, y) in payload]))

    stats = {
        "patches": len(patch_pts),
        "faces": len(records),
        "folds": len(fold_pairs),
        "seams": n_seams,
    }
    return shifted, stats, skipped


# ---------------------------------------------------------------------------
# Worker op
# ---------------------------------------------------------------------------

def op_unfold_connected(args: Dict[str, Any]) -> Dict[str, Any]:
    """Unfolds selected faces (or whole bodies) as connected nets into a DXF.

    args:
      input         STEP path (required)
      output        DXF path (required)
      existing_dxf  optional DXF to append after (canvas working buffer)
      faces         [{body_index, face_index}, ...] — ignored if whole_body
      whole_body    bool: unfold every face of every body
      mode          "radial" | "strip" | "spanning"   (default "radial")
      anchor        {body_index, face_index} optional rollout root
      decoration    "none" | "tabs" | "holes"          (default "none")
      tab_height, hole_diameter, hole_spacing, hole_margin  floats (mm)
      distortion_mode "conformal" | "equal-area" | "equidistant" | "balanced"
      forced_seams  [{body_index, edge_index}, ...]
      forbidden_seams [{body_index, edge_index}, ...]
    """
    import os
    from pathstitch_core.step_ops import load_step_shape, get_solid_bodies, get_dxf_bounds

    input_path = args.get("input")
    output_path = args.get("output")
    if not input_path or not output_path:
        return {"status": "error", "message": "Missing input or output path."}

    mode = args.get("mode", "radial")
    decoration = args.get("decoration", "none")
    deco_params = {
        "tab_height": float(args.get("tab_height", 8.0)),
        "hole_diameter": float(args.get("hole_diameter", 2.0)),
        "hole_spacing": float(args.get("hole_spacing", 8.0)),
        "hole_margin": float(args.get("hole_margin", 4.0)),
    }
    whole_body = bool(args.get("whole_body", False))
    anchor_arg = args.get("anchor") or {}
    distortion_mode = args.get("distortion_mode", "conformal")
    forced_seams_list = args.get("forced_seams") or []
    forbidden_seams_list = args.get("forbidden_seams") or []

    try:
        shape = load_step_shape(input_path)
        bodies = get_solid_bodies(shape)

        # Group requested faces per body
        per_body: Dict[int, Optional[set]] = {}
        if whole_body:
            for b_idx in range(len(bodies)):
                per_body[b_idx] = None  # None = all faces
        else:
            for item in args.get("faces") or []:
                b = item.get("body_index")
                f = item.get("face_index")
                if b is None or f is None or b < 0 or b >= len(bodies):
                    continue
                per_body.setdefault(b, set()).add(f)
        if not per_body:
            return {"status": "error", "message": "No faces requested."}

        all_ops: List[Tuple[str, str, Any]] = []
        all_skipped: List[Dict] = []
        totals = {"patches": 0, "faces": 0, "folds": 0, "seams": 0}
        cursor_x = 0.0

        for b_idx in sorted(per_body):
            anchor = None
            if anchor_arg.get("body_index") == b_idx:
                anchor = anchor_arg.get("face_index")
                
            # Filter seams for this body
            forced_seams = {item.get("edge_index") for item in forced_seams_list if item.get("body_index") == b_idx}
            forbidden_seams = {item.get("edge_index") for item in forbidden_seams_list if item.get("body_index") == b_idx}
            
            # Filter seam decorations for this body
            seam_decorations_list = args.get("seam_decorations") or []
            seam_decorations = {
                item.get("edge_index"): item.get("decoration")
                for item in seam_decorations_list
                if item.get("body_index") == b_idx
            }
            
            ops, stats, skipped = unfold_connected(
                bodies[b_idx], per_body[b_idx], mode, anchor,
                decoration, deco_params,
                distortion_mode=distortion_mode,
                forced_seams=forced_seams,
                forbidden_seams=forbidden_seams,
                seam_decorations=seam_decorations)
            for s in skipped:
                s["body_index"] = b_idx
            all_skipped.extend(skipped)
            for k in totals:
                totals[k] += stats[k]

            # Place this body's nets after the previous body's
            max_x = cursor_x
            for (kind, layer, payload) in ops:
                if kind == "circle":
                    (cx, cy), r = payload
                    all_ops.append((kind, layer, ((cx + cursor_x, cy), r)))
                    max_x = max(max_x, cx + cursor_x + r)
                elif kind == "solid":
                    pts, aci = payload
                    translated = [(x + cursor_x, y) for (x, y) in pts]
                    all_ops.append((kind, layer, (translated, aci)))
                    max_x = max(max_x, max(p[0] for p in translated))
                else:
                    pts = [(x + cursor_x, y) for (x, y) in payload]
                    all_ops.append((kind, layer, pts))
                    max_x = max(max_x, max(p[0] for p in pts))
            cursor_x = max_x + GAP

        if not all_ops:
            msg = "Nothing unfoldable in the selection."
            if all_skipped:
                msg += (" Skipped non-developable faces: " +
                        ", ".join(f"B{s['body_index']+1}:F{s['face_index']}"
                                  for s in all_skipped) +
                        ". Flattening failed.")
            return {"status": "error", "message": msg}

        # Load or create the destination DXF, appending after existing content
        if args.get("existing_dxf") and os.path.exists(args["existing_dxf"]):
            doc = ezdxf.readfile(args["existing_dxf"])
            msp = doc.modelspace()
            bounds = get_dxf_bounds(msp)
            start_x, start_y = (bounds[2] + GAP, bounds[1]) if bounds else (0.0, 0.0)
        else:
            doc = ezdxf.new(dxfversion="R2010", setup=True)
            msp = doc.modelspace()
            start_x, start_y = 0.0, 0.0

        _ensure_layers(doc)

        for (kind, layer, payload) in all_ops:
            if kind == "circle":
                (cx, cy), r = payload
                msp.add_circle((cx + start_x, cy + start_y), r,
                               dxfattribs={"layer": layer})
            elif kind == "solid":
                pts, aci = payload
                translated = [(x + start_x, y + start_y) for (x, y) in pts]
                msp.add_solid(translated, dxfattribs={"layer": layer, "color": aci})
            else:
                pts = [(x + start_x, y + start_y) for (x, y) in payload]
                if len(pts) >= 2:
                    msp.add_lwpolyline(pts, dxfattribs={"layer": layer})

        doc.saveas(output_path)

        return {
            "status": "ok",
            "data": {
                "output": output_path,
                "patches": totals["patches"],
                "faces_unfolded": totals["faces"],
                "fold_edges": totals["folds"],
                "seam_edges": totals["seams"],
                "skipped_faces": all_skipped,
            },
        }
    except Exception as e:
        import traceback
        return {"status": "error",
                "message": f"Connected unfold failed: {str(e)}\n{traceback.format_exc()}"}
