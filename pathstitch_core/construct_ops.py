"""Construct-mode geometry backend.

Construct mode assembles flat leather panels into a 3D object: pin a ground
panel, fold panels up along fold lines, stitch sewing-hole chains together.
The *live* part (folding, dragging, stitching) is solved at 60fps by an XPBD
solver in the viewport (`constructViewport.html`). This module does the
one-time-per-topology-change work: it turns each flat panel outline (plus its
fold lines) into a triangulated **bar-and-hinge** mesh the solver can run on.

Model produced (the "construct model"), per panel:
  - vertices  : 3D rest positions, flat on the ground plane (world XZ, y up)
  - vertices2d: the original 2D coordinates (mm)
  - triangles : [[a,b,c], ...] indices into vertices
  - edges     : unique undirected edges → distance ("bar") constraints; the
                solver reads rest length straight off the vertices, so leather
                bends but never stretches.
  - hinges    : dihedral ("bending") constraints. Every interior edge is a
                hinge. Facet creases (interior to a face) get foldId -1 and a
                0° rest angle so faces stay rigid (PackCAD's trick); edges that
                lie on a user fold line get that fold's id and become the
                adjustable folds.

This mirrors PackCAD's rigid bar-and-hinge representation, but the model here
is just data — the solver and every interactive feature (fold/drag/stitch)
live on top of it as different constraint sets.
"""
import os
import math
from collections import defaultdict
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np
from scipy.spatial import Delaunay
from shapely.geometry import Polygon, Point, LineString
from shapely.ops import split as shapely_split

Pt = Tuple[float, float]


# ---------------------------------------------------------------------------
# small geometry helpers
# ---------------------------------------------------------------------------

def _polyline_length(pts: Sequence[Pt]) -> float:
    return sum(math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1])
               for i in range(len(pts) - 1))


def _bbox(pts: Sequence[Pt]) -> Tuple[float, float, float, float]:
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def _resample_polyline(pts: Sequence[Pt], step: float, closed: bool) -> List[Pt]:
    """Returns points along `pts` no farther apart than `step` (keeps corners)."""
    if len(pts) < 2:
        return list(pts)
    src = list(pts)
    if closed and (src[0] != src[-1]):
        src = src + [src[0]]
    out: List[Pt] = [tuple(src[0])]
    for i in range(len(src) - 1):
        a, b = src[i], src[i + 1]
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        if seg < 1e-9:
            continue
        n = max(1, int(math.ceil(seg / step)))
        for k in range(1, n + 1):
            t = k / n
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    if closed and out and out[-1] == out[0] and len(out) > 1:
        out.pop()  # don't duplicate the wrap-around point
    return out


def _dist_point_to_polyline(p: Pt, poly: Sequence[Pt]) -> float:
    """Shortest distance from point `p` to an (open) polyline."""
    if len(poly) == 1:
        return math.hypot(p[0] - poly[0][0], p[1] - poly[0][1])
    best = float("inf")
    for i in range(len(poly) - 1):
        ax, ay = poly[i]
        bx, by = poly[i + 1]
        dx, dy = bx - ax, by - ay
        seg2 = dx * dx + dy * dy
        if seg2 < 1e-12:
            d = math.hypot(p[0] - ax, p[1] - ay)
        else:
            t = ((p[0] - ax) * dx + (p[1] - ay) * dy) / seg2
            t = max(0.0, min(1.0, t))
            cx, cy = ax + t * dx, ay + t * dy
            d = math.hypot(p[0] - cx, p[1] - cy)
        if d < best:
            best = d
    return best


# ---------------------------------------------------------------------------
# triangulation of one panel (constrained-ish Delaunay)
# ---------------------------------------------------------------------------

def _extend_polyline(pts: Sequence[Pt], d: float) -> List[Pt]:
    """Extends a polyline by `d` past each end along its end tangents."""
    pts = list(pts)
    if len(pts) < 2:
        return pts
    ax, ay = pts[0]
    bx, by = pts[1]
    la = math.hypot(bx - ax, by - ay) or 1.0
    head = (ax - (bx - ax) / la * d, ay - (by - ay) / la * d)
    cx, cy = pts[-1]
    dx, dy = pts[-2]
    lb = math.hypot(cx - dx, cy - dy) or 1.0
    tail = (cx + (cx - dx) / lb * d, cy + (cy - dy) / lb * d)
    return [head] + pts + [tail]


def _split_polygon(poly: Polygon, folds: Sequence[Sequence[Pt]]) -> List[Polygon]:
    """Cuts `poly` along each fold so folds become region boundaries.

    Plain Delaunay won't respect a fold as an edge (collinear fold samples are
    cocircular-degenerate with the surrounding grid and flip arbitrarily). By
    splitting the panel into regions along the folds and triangulating each
    independently, every fold segment is guaranteed to be a shared edge after
    welding — a clean, deterministic hinge chain.
    """
    minx, miny, maxx, maxy = poly.bounds
    diag = math.hypot(maxx - minx, maxy - miny) or 1.0
    regions: List[Polygon] = [poly]
    for f in folds:
        if len(f) < 2:
            continue
        line = LineString(_extend_polyline(f, diag * 0.1))
        nxt: List[Polygon] = []
        for r in regions:
            try:
                res = shapely_split(r, line)
                parts = [g for g in getattr(res, "geoms", [res])
                         if g.geom_type == "Polygon" and g.area > 1e-9]
                nxt.extend(parts if parts else [r])
            except Exception:
                nxt.append(r)
        regions = nxt
    return regions or [poly]


def _triangulate_simple(poly: Polygon, step: float) -> Tuple[List[Pt], List[Tuple[int, int, int]]]:
    """Triangulates one simple region: boundary samples + interior grid."""
    ext = list(poly.exterior.coords)
    if len(ext) > 1 and ext[0] == ext[-1]:
        ext = ext[:-1]
    pts: List[Pt] = list(_resample_polyline(ext, step, closed=True))

    # Sample interior rings too (cut-out windows) so the hole edge triangulates
    # cleanly instead of being bridged and dropped by the centroid test below.
    for ring in poly.interiors:
        r = list(ring.coords)
        if len(r) > 1 and r[0] == r[-1]:
            r = r[:-1]
        pts.extend(_resample_polyline(r, step, closed=True))

    minx, miny, maxx, maxy = poly.bounds
    inner = poly.buffer(-step * 0.25)  # keep grid off the boundary a touch
    gx = minx + step * 0.5
    while gx < maxx:
        gy = miny + step * 0.5
        while gy < maxy:
            q = Point(gx, gy)
            if not inner.is_empty and inner.contains(q):
                pts.append((gx, gy))
            gy += step
        gx += step

    uniq: List[Pt] = []
    seen = {}
    qtol = step * 0.05
    for p in pts:
        key = (round(p[0] / qtol), round(p[1] / qtol))
        if key not in seen:
            seen[key] = len(uniq)
            uniq.append((float(p[0]), float(p[1])))
    if len(uniq) < 3:
        return [], []

    arr = np.asarray(uniq, dtype=float)
    try:
        tri = Delaunay(arr)
    except Exception:
        return [], []

    kept: List[Tuple[int, int, int]] = []
    for a, b, c in tri.simplices:
        cx = (arr[a, 0] + arr[b, 0] + arr[c, 0]) / 3.0
        cy = (arr[a, 1] + arr[b, 1] + arr[c, 1]) / 3.0
        if poly.contains(Point(cx, cy)):
            kept.append((int(a), int(b), int(c)))
    if not kept:
        return [], []

    used = sorted({i for t in kept for i in t})
    remap = {old: new for new, old in enumerate(used)}
    verts = [uniq[i] for i in used]
    tris = [(remap[a], remap[b], remap[c]) for (a, b, c) in kept]
    return verts, tris


def _weld(verts: List[Pt], tris: List[Tuple[int, int, int]],
          qtol: float) -> Tuple[List[Pt], List[Tuple[int, int, int]]]:
    """Merges coincident vertices (so region boundaries fuse into shared edges)."""
    out_v: List[Pt] = []
    key_to_new: Dict[Tuple[int, int], int] = {}
    old_to_new: List[int] = []
    for (x, y) in verts:
        key = (round(x / qtol), round(y / qtol))
        ni = key_to_new.get(key)
        if ni is None:
            ni = len(out_v)
            key_to_new[key] = ni
            out_v.append((x, y))
        old_to_new.append(ni)
    out_t = []
    for (a, b, c) in tris:
        na, nb, nc = old_to_new[a], old_to_new[b], old_to_new[c]
        if na != nb and nb != nc and na != nc:  # drop degenerate
            out_t.append((na, nb, nc))
    return out_v, out_t


def _triangulate_panel(outline: Sequence[Pt],
                       folds: Sequence[Sequence[Pt]],
                       target_len: float,
                       holes: Optional[Sequence[Sequence[Pt]]] = None) -> Dict[str, Any]:
    """Triangulates a flat panel so fold lines fall on shared mesh edges.

    `holes` (optional) are interior rings to leave open — cut-out windows."""
    poly = Polygon(outline, holes or [])
    if not poly.is_valid:
        poly = poly.buffer(0)
    if poly.is_empty or poly.area <= 1e-9:
        raise ValueError("degenerate panel outline")

    step = max(target_len, 1e-3)
    fold_polys = [list(f) for f in folds if len(f) >= 2]
    regions = _split_polygon(poly, fold_polys) if fold_polys else [poly]

    all_v: List[Pt] = []
    all_t: List[Tuple[int, int, int]] = []
    for r in regions:
        v, t = _triangulate_simple(r, step)
        base = len(all_v)
        all_v.extend(v)
        all_t.extend((a + base, b + base, c + base) for (a, b, c) in t)
    if not all_t:
        raise ValueError("triangulation produced no faces")

    verts2d, tris = _weld(all_v, all_t, step * 0.05)
    if len(tris) == 0:
        raise ValueError("triangulation collapsed after welding")

    edges, hinges = _build_edges_and_hinges(verts2d, tris, fold_polys, step)
    return {"vertices2d": verts2d, "triangles": tris, "edges": edges, "hinges": hinges}


def _build_edges_and_hinges(verts2d: List[Pt],
                            tris: List[Tuple[int, int, int]],
                            fold_polys: List[List[Pt]],
                            step: float) -> Tuple[List[List[int]], List[Dict[str, Any]]]:
    """Unique edges (bars) + dihedral hinges, tagging fold-line edges."""
    # edge -> list of (opposite vertex) for each incident triangle
    edge_opp: Dict[Tuple[int, int], List[int]] = {}
    for (a, b, c) in tris:
        for (i, j, k) in ((a, b, c), (b, c, a), (c, a, b)):
            key = (i, j) if i < j else (j, i)
            edge_opp.setdefault(key, []).append(k)

    edges = [[i, j] for (i, j) in edge_opp.keys()]

    # Fold tagging must be tighter than the grid-exclusion zone (step*0.45) so
    # grid points sitting just off the fold can't be mistaken for fold vertices;
    # genuine fold samples lie exactly on the line (dist 0).
    fold_tol = step * 0.2
    hinges: List[Dict[str, Any]] = []
    for (i, j), opps in edge_opp.items():
        if len(opps) != 2:
            continue  # boundary edge → bar only, no bending constraint
        fold_id = _fold_id_for_edge(verts2d[i], verts2d[j], fold_polys, fold_tol)
        hinges.append({
            "v0": i, "v1": j,            # the hinge spine (shared edge)
            "vl": opps[0], "vr": opps[1],  # the wing vertices, one per face
            "foldId": fold_id,           # -1 = facet crease (kept rigid at 0°)
        })
    return edges, hinges


def _fold_id_for_edge(p: Pt, q: Pt, fold_polys: List[List[Pt]], tol: float) -> int:
    """Returns the index of the fold line this edge lies on, or -1."""
    mid = ((p[0] + q[0]) * 0.5, (p[1] + q[1]) * 0.5)
    for fid, f in enumerate(fold_polys):
        if (_dist_point_to_polyline(p, f) <= tol
                and _dist_point_to_polyline(q, f) <= tol
                and _dist_point_to_polyline(mid, f) <= tol):
            return fid
    return -1


# ---------------------------------------------------------------------------
# sewing holes → chains (the stitch flagship's input)
# ---------------------------------------------------------------------------
#
# Sewing holes live on the SEWING_HOLES layer as small CIRCLE / ELLIPSE / closed
# LWPOLYLINE cut-paths (see dxf_ops._emit_iron_slits). For construct mode they
# stop being anonymous circles and become ordered **chains**: a run of holes
# along one seam, which is what the user stitches to another chain. Each hole is
# also **embedded** into its panel's triangulation (containing triangle + barycentric
# weights) so it rides the mesh as the panel folds — a hole's 3D position is just
# a barycentric blend of its triangle's three (folded) vertices.


def _bary(p: Pt, a: Pt, b: Pt, c: Pt) -> Tuple[float, float, float]:
    """Barycentric coords of `p` in triangle (a,b,c)."""
    v0 = (b[0] - a[0], b[1] - a[1])
    v1 = (c[0] - a[0], c[1] - a[1])
    v2 = (p[0] - a[0], p[1] - a[1])
    d00 = v0[0] * v0[0] + v0[1] * v0[1]
    d01 = v0[0] * v1[0] + v0[1] * v1[1]
    d11 = v1[0] * v1[0] + v1[1] * v1[1]
    d20 = v2[0] * v0[0] + v2[1] * v0[1]
    d21 = v2[0] * v1[0] + v2[1] * v1[1]
    denom = d00 * d11 - d01 * d01
    if abs(denom) < 1e-15:
        return 1.0, 0.0, 0.0
    v = (d11 * d20 - d01 * d21) / denom
    w = (d00 * d21 - d01 * d20) / denom
    u = 1.0 - v - w
    return u, v, w


def _embed_point(x: float, y: float,
                 verts2d: List[Pt],
                 tris: List[Tuple[int, int, int]]) -> Tuple[int, List[float]]:
    """Finds the triangle containing (x,y) and returns (triIndex, [u,v,w]).

    Holes sit just inside the panel boundary, so they normally land inside a
    triangle; if one falls in a grid gap we fall back to the closest triangle
    with clamped, renormalized weights (still rides the mesh smoothly).
    """
    p = (x, y)
    best_tri, best_bary, best_neg = 0, [1.0, 0.0, 0.0], -1e18
    for ti, (a, b, c) in enumerate(tris):
        u, v, w = _bary(p, verts2d[a], verts2d[b], verts2d[c])
        m = min(u, v, w)
        if m >= -1e-6:
            return ti, [u, v, w]
        if m > best_neg:
            best_neg, best_tri, best_bary = m, ti, [u, v, w]
    u, v, w = (max(0.0, c) for c in best_bary)
    s = (u + v + w) or 1.0
    return best_tri, [u / s, v / s, w / s]


def _order_run(idxs: List[int], adj: List[List[int]], P: "np.ndarray") -> Tuple[List[int], bool]:
    """Orders one connected component of holes into a walk; flags closed loops."""
    idxset = set(idxs)
    deg = {i: sum(1 for v in adj[i] if v in idxset) for i in idxs}
    endpoints = [i for i in idxs if deg[i] == 1]
    closed = (len(endpoints) == 0 and len(idxs) > 2)
    start = endpoints[0] if endpoints else idxs[0]
    order, visited, cur = [start], {start}, start
    while len(visited) < len(idxs):
        cand = [v for v in adj[cur] if v in idxset and v not in visited]
        if not cand:
            cand = [v for v in idxs if v not in visited]
            if not cand:
                break
        nxt = min(cand, key=lambda v: math.hypot(P[cur, 0] - P[v, 0], P[cur, 1] - P[v, 1]))
        order.append(nxt); visited.add(nxt); cur = nxt
    return order, closed


def _chain_holes(pts: List[Pt]) -> List[Tuple[List[int], bool, float]]:
    """Groups holes into ordered chains by spacing.

    Returns [(ordered_indices, closed, pitch), ...]. Holes on one seam are evenly
    spaced (~pitch); a connected component under a pitch-scaled gap is one chain.
    In the *flat* net, separate seam runs stay separate (they only meet once
    folded), so connected-components on rest positions is the right grouping.
    """
    n = len(pts)
    if n < 2:
        return []
    P = np.asarray(pts, dtype=float)
    # per-hole nearest-neighbour distance → robust global pitch estimate
    nn = []
    for i in range(n):
        d = np.hypot(P[:, 0] - P[i, 0], P[:, 1] - P[i, 1]); d[i] = 1e18
        nn.append(float(d.min()))
    pitch = float(np.median(nn)) or 1.0
    gap = pitch * 1.7
    adj: List[List[int]] = [[] for _ in range(n)]
    for i in range(n):
        for j in range(i + 1, n):
            if math.hypot(P[i, 0] - P[j, 0], P[i, 1] - P[j, 1]) <= gap:
                adj[i].append(j); adj[j].append(i)
    comp = [-1] * n; cid = 0
    for i in range(n):
        if comp[i] >= 0:
            continue
        stack = [i]; comp[i] = cid
        while stack:
            u = stack.pop()
            for v in adj[u]:
                if comp[v] < 0:
                    comp[v] = cid; stack.append(v)
        cid += 1
    chains: List[Tuple[List[int], bool, float]] = []
    for c in range(cid):
        idxs = [i for i in range(n) if comp[i] == c]
        if len(idxs) < 2:
            continue  # a lone hole isn't a stitch chain
        ordered, closed = _order_run(idxs, adj, P)
        ds = [math.hypot(P[ordered[k], 0] - P[ordered[k + 1], 0],
                         P[ordered[k], 1] - P[ordered[k + 1], 1])
              for k in range(len(ordered) - 1)]
        chains.append((ordered, closed, float(np.median(ds)) if ds else pitch))
    return chains


def _build_hole_chains(holes: List[Pt],
                       polys: Dict[int, Polygon],
                       meshes: Dict[int, Tuple[List[Pt], List[Tuple[int, int, int]]]]
                       ) -> List[Dict[str, Any]]:
    """Assigns holes to panels, chains them, and embeds each into its panel mesh."""
    by_panel: Dict[int, List[Pt]] = defaultdict(list)
    for (hx, hy) in holes:
        pt = Point(hx, hy)
        best, best_score = None, 1e18
        for pid, poly in polys.items():
            if poly.contains(pt):
                score = -1.0 + poly.exterior.distance(pt) * 1e-6  # containment wins
            else:
                score = poly.distance(pt)
            if score < best_score:
                best_score, best = score, pid
        if best is not None:
            by_panel[best].append((float(hx), float(hy)))

    chains: List[Dict[str, Any]] = []
    cid = 0
    for pid in sorted(by_panel.keys()):
        hs = by_panel[pid]
        if pid not in meshes:
            continue
        verts2d, tris = meshes[pid]
        for ordered, closed, pitch in _chain_holes(hs):
            chole = []
            for k in ordered:
                x, y = hs[k]
                tri, bary = _embed_point(x, y, verts2d, tris)
                chole.append({"x": x, "y": y, "tri": tri, "bary": bary})
            chains.append({"id": cid, "panelId": pid, "closed": closed,
                           "pitch": pitch, "holes": chole})
            cid += 1
    return chains


# ---------------------------------------------------------------------------
# chain matching (arc-length correspondence — the auto stitch matcher)
# ---------------------------------------------------------------------------

def _arc_params(pts: Sequence[Pt], closed: bool) -> Tuple[List[float], float]:
    """Normalized arc-length parameter [0,1] of each point, and total length."""
    n = len(pts)
    if n < 2:
        return [0.0] * n, 1.0
    segs = [math.hypot(pts[(i + 1) % n][0] - pts[i][0], pts[(i + 1) % n][1] - pts[i][1])
            for i in range(n if closed else n - 1)]
    total = sum(segs) or 1.0
    params, acc = [0.0], 0.0
    for s in segs[: (n - 1)]:
        acc += s; params.append(acc / total)
    while len(params) < n:
        params.append(1.0)
    return params[:n], total


def _pairs_for(pa: List[float], pb: List[float]) -> Tuple[List[Tuple[int, int]], float]:
    """Mutual nearest-param pairing: every hole on both chains gets ≥1 partner.

    This is what makes mismatched counts work without painful 1:1 — the longer
    chain's surplus holes converge onto the nearest hole of the shorter chain
    (realistic gathering), and no hole is ever left unsewn.
    """
    pairs = set()
    cost = 0.0
    for i, t in enumerate(pa):
        j = min(range(len(pb)), key=lambda k: abs(pb[k] - t))
        pairs.add((i, j)); cost += abs(pb[j] - t)
    for j, t in enumerate(pb):
        i = min(range(len(pa)), key=lambda k: abs(pa[k] - t))
        pairs.add((i, j)); cost += abs(pa[i] - t)
    return sorted(pairs), cost


def op_match_chains(args: Dict[str, Any]) -> Dict[str, Any]:
    """Auto-matches two hole chains for stitching.

    args: chainA / chainB = [[x,y], ...] ordered hole centers; closedA/closedB.
    Returns matched index pairs, the two seam lengths, the perimeter mismatch
    ratio, whether B was reversed to line up, and the recommended policy
    (`even` if lengths agree, else `ease` = gather the longer onto the shorter).
    """
    A = [(float(p[0]), float(p[1])) for p in args.get("chainA", [])]
    B = [(float(p[0]), float(p[1])) for p in args.get("chainB", [])]
    if len(A) < 2 or len(B) < 2:
        return {"status": "error", "message": "Each chain needs at least 2 holes."}
    closedA = bool(args.get("closedA", False))
    closedB = bool(args.get("closedB", False))

    pa, lenA = _arc_params(A, closedA)
    pb_fwd, lenB = _arc_params(B, closedB)
    fwd, cfwd = _pairs_for(pa, pb_fwd)
    pb_rev, _ = _arc_params(B[::-1], closedB)
    rev, crev = _pairs_for(pa, pb_rev)

    if crev < cfwd:
        m = len(B)
        pairs = sorted({(i, m - 1 - j) for (i, j) in rev})
        reversed_ = True
    else:
        pairs = fwd
        reversed_ = False

    mismatch = abs(lenA - lenB) / max(lenA, lenB, 1e-9)
    policy = "even" if mismatch < 0.12 else "ease"
    return {"status": "ok", "data": {
        "pairs": [[i, j] for (i, j) in pairs],
        "lenA": lenA, "lenB": lenB,
        "mismatch": mismatch, "reversed": reversed_, "policy": policy,
    }}


# ---------------------------------------------------------------------------
# DXF extraction (live-sketch source)
# ---------------------------------------------------------------------------

_FOLD_LAYERS = {"FOLD", "FOLDS", "CREASE", "CREASES", "FOLD_LINES"}
_HOLE_LAYERS = {"SEWING_HOLES", "HOLES", "STITCH", "STITCHES"}
_SKIP_LAYERS = {"SEWING_HOLES", "DISTORTION", "CONSTRUCTION"}


def _entity_center(ent) -> Optional[Pt]:
    """Center of a sewing-hole entity (circle/ellipse center, or ring centroid)."""
    et = ent.dxftype()
    if et in ("CIRCLE", "ELLIPSE"):
        return (float(ent.dxf.center.x), float(ent.dxf.center.y))
    if et == "POINT":
        return (float(ent.dxf.location.x), float(ent.dxf.location.y))
    if et in ("LWPOLYLINE", "POLYLINE"):
        try:
            from ezdxf.path import make_path
            pts = [(p.x, p.y) for p in make_path(ent).flattening(distance=0.2)]
        except Exception:
            return None
        if len(pts) >= 2 and pts[0] == pts[-1]:
            pts = pts[:-1]
        if not pts:
            return None
        return (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))
    return None


def _extract_from_dxf(input_path: str,
                      fold_layers: Optional[List[str]],
                      include_handles: Optional[set] = None
                      ) -> Tuple[List[List[Pt]], List[List[Pt]], List[Pt], List[str], List[str]]:
    """Reads panel outlines, fold-layer lines, sewing-hole centers, the DXF handle
    of each panel (parallel to `panels`), and *all* closed-area handles in the
    sketch (regardless of the include filter — used to prune stale references).

    `include_handles` (optional) restricts which closed areas become panels — to
    their DXF entity handle — so the user can assemble just one selected area.
    """
    import ezdxf
    from ezdxf.path import make_path

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()
    fold_set = {s.upper() for s in (fold_layers or [])} | _FOLD_LAYERS

    panels: List[List[Pt]] = []
    panel_handles: List[str] = []
    all_handles: List[str] = []
    folds: List[List[Pt]] = []
    holes: List[Pt] = []
    for ent in msp:
        layer = (ent.dxf.layer or "").upper()
        et = ent.dxftype()
        if layer in _HOLE_LAYERS:
            c = _entity_center(ent)
            if c is not None:
                holes.append(c)
            continue
        if et == "LINE":
            seg = [(ent.dxf.start.x, ent.dxf.start.y), (ent.dxf.end.x, ent.dxf.end.y)]
            if layer in fold_set:
                folds.append(seg)
            continue
        if et in ("LWPOLYLINE", "POLYLINE", "SPLINE", "ELLIPSE"):
            try:
                path = make_path(ent)
                pts = [(p.x, p.y) for p in path.flattening(distance=0.2)]
            except Exception:
                continue
            if len(pts) < 2:
                continue
            closed = bool(getattr(ent, "closed", False) or getattr(ent, "is_closed", False))
            if layer in fold_set:
                folds.append(pts)
            elif closed and layer not in _SKIP_LAYERS:
                all_handles.append(str(ent.dxf.handle))   # every area, pre-filter
                if include_handles and str(ent.dxf.handle) not in include_handles:
                    continue  # only the user-chosen area(s) become panels
                panels.append(pts)
                panel_handles.append(str(ent.dxf.handle))
    return panels, folds, holes, panel_handles, all_handles


# ---------------------------------------------------------------------------
# operation entry point
# ---------------------------------------------------------------------------

def _auto_target_len(outline: Sequence[Pt], requested: float) -> float:
    if requested and requested > 0:
        return requested
    minx, miny, maxx, maxy = _bbox(outline)
    span = max(maxx - minx, maxy - miny, 1.0)
    # ~24 cells across the larger dimension — fine enough that folds and brush
    # bends read as smooth curves, not faceted ridges. (Floor keeps tiny tabs sane.)
    return max(span / 24.0, 0.8)


def op_build_construct_model(args: Dict[str, Any]) -> Dict[str, Any]:
    """Triangulates panels into bar-and-hinge meshes for the construct solver.

    args:
      input        : path to a DXF (closed polylines = panels; fold-layer
                     lines = folds).  OR pass geometry directly:
      panels       : [[[x,y], ...], ...]  explicit panel outlines
      folds        : [[[x,y], ...], ...]  explicit fold polylines (shared by all)
      fold_layers  : extra DXF layer names to treat as folds
      target_len   : target mesh edge length (mm); auto if omitted/<=0
      ground_panel : index of the panel pinned to the ground (default 0)
    """
    panels_in = args.get("panels")
    folds_in = args.get("folds") or []
    holes_in = args.get("holes") or []
    panel_handles: List[str] = []
    all_handles: List[str] = []

    if panels_in is None:
        input_path = args.get("input")
        if not input_path or not os.path.exists(input_path):
            return {"status": "error", "message": f"Input file not found: {input_path}"}
        inc = args.get("include_handles") or []
        inc_set = {str(h) for h in inc} if inc else None
        try:
            panels_in, folds_in, holes_in, panel_handles, all_handles = _extract_from_dxf(input_path, args.get("fold_layers"), inc_set)
        except Exception as e:
            return {"status": "error", "message": f"DXF read failed: {e}"}
    if not panel_handles:
        panel_handles = [str(i) for i in range(len(panels_in or []))]
    if not all_handles:
        all_handles = list(panel_handles)

    # Fold lines the user drew directly in 3D (two points on a panel) — appended
    # so they're triangulated as real hinges just like DXF FOLD-layer folds. A
    # fold has to cut the panel edge-to-edge to actually separate a foldable
    # region, so extend the drawn segment into a long chord along its direction
    # (shapely only splits where the chord crosses the panel; the overshoot is
    # harmless, and the hinge tagging then covers the full crossing).
    # A crease drawn on panel N must cut *only* panel N — so chords carrying a
    # panelId are bucketed per panel and applied just to that one (an untagged
    # legacy chord still falls through to the global fold list).
    extra_by_panel: Dict[int, List[List[Pt]]] = {}
    for ef in (args.get("extra_folds") or []):
        seg = ef.get("seg") if isinstance(ef, dict) else ef
        pid = ef.get("panelId") if isinstance(ef, dict) else None
        if seg and len(seg) >= 2:
            p0 = (float(seg[0][0]), float(seg[0][1]))
            p1 = (float(seg[-1][0]), float(seg[-1][1]))
            dx, dy = p1[0] - p0[0], p1[1] - p0[1]
            ln = math.hypot(dx, dy) or 1.0
            ux, uy = dx / ln, dy / ln
            L = 1.0e4
            chord = [(p0[0] - ux * L, p0[1] - uy * L), (p1[0] + ux * L, p1[1] + uy * L)]
            if pid is None:
                folds_in = list(folds_in) + [chord]
            else:
                extra_by_panel.setdefault(int(pid), []).append(chord)

    if not panels_in:
        return {"status": "error", "message": "No closed panel outlines found."}

    requested_len = float(args.get("target_len", 0) or 0)
    ground_panel = int(args.get("ground_panel", 0) or 0)

    # Overlap handling: detect each area engulfed by a larger one and apply the
    # user's per-area treatment (keyed by DXF handle). cutout → hole in the outer
    # panel + drop inner; stamp → decorative surface outline on the outer + drop
    # inner; patch → keep inner, tag it onto the outer (raised); independent / none
    # → both stay normal panels. Engulfed pairs are reported so the UI can prompt.
    norm_outlines: List[List[Pt]] = []
    for outline in panels_in:
        o = [(float(p[0]), float(p[1])) for p in outline]
        if len(o) >= 2 and o[0] == o[-1]:
            o = o[:-1]
        norm_outlines.append(o)
    area_polys: List[Optional[Polygon]] = []
    for o in norm_outlines:
        if len(o) < 3:
            area_polys.append(None); continue
        pg = Polygon(o)
        if not pg.is_valid:
            pg = pg.buffer(0)
        area_polys.append(None if (pg.is_empty or pg.area <= 1e-9) else pg)

    treatments = args.get("area_treatments") or {}
    engulfed: List[Dict[str, str]] = []
    container_of: Dict[int, int] = {}
    for i, pi in enumerate(area_polys):
        if pi is None:
            continue
        best, best_area = -1, float("inf")
        for j, pj in enumerate(area_polys):
            if i == j or pj is None or pj.area <= pi.area:
                continue
            if pj.buffer(1e-6).contains(pi) and pj.area < best_area:
                best, best_area = j, pj.area
        if best >= 0:
            container_of[i] = best
            engulfed.append({"inner": panel_handles[i], "outer": panel_handles[best]})

    dropped: set = set()
    holes_by_panel: Dict[int, List[List[Pt]]] = {}
    stamps_src: Dict[int, List[List[Pt]]] = {}
    patch_of: Dict[int, int] = {}
    for i, j in container_of.items():
        t = treatments.get(panel_handles[i], "independent")
        if t == "cutout":
            dropped.add(i); holes_by_panel.setdefault(j, []).append(norm_outlines[i])
        elif t == "stamp":
            dropped.add(i); stamps_src.setdefault(j, []).append(norm_outlines[i])
        elif t == "patch":
            patch_of[i] = j   # stays a panel, raised onto its container

    out_panels: List[Dict[str, Any]] = []
    all_pts: List[Pt] = []
    panel_polys: Dict[int, Polygon] = {}
    panel_meshes: Dict[int, Tuple[List[Pt], List[Tuple[int, int, int]]]] = {}
    for idx, outline in enumerate(panels_in):
        if idx in dropped:
            continue
        outline = norm_outlines[idx]
        if len(outline) < 3:
            continue
        # only fold lines that actually touch this panel
        poly = Polygon(outline)
        if not poly.is_valid:
            poly = poly.buffer(0)
        my_folds = [f for f in folds_in
                    if len(f) >= 2 and poly.buffer(1e-6).intersects(LineString(f))]
        my_folds = my_folds + extra_by_panel.get(idx, [])   # this panel's own creases
        tl = _auto_target_len(outline, requested_len)
        try:
            mesh = _triangulate_panel(outline, my_folds, tl, holes_by_panel.get(idx))
        except Exception as e:
            return {"status": "error", "message": f"Panel {idx} triangulation failed: {e}"}

        # Map flat 2D onto the ground plane: world XZ, y is up (folds lift in +y).
        verts3d = [[v[0], 0.0, v[1]] for v in mesh["vertices2d"]]
        all_pts.extend(mesh["vertices2d"])
        n_folds = len({h["foldId"] for h in mesh["hinges"] if h["foldId"] >= 0})
        panel_polys[idx] = poly
        panel_meshes[idx] = (mesh["vertices2d"], mesh["triangles"])
        out_panels.append({
            "id": idx,
            "handle": panel_handles[idx] if idx < len(panel_handles) else str(idx),
            "patchOf": patch_of.get(idx, -1),
            "vertices": verts3d,
            "vertices2d": mesh["vertices2d"],
            "triangles": mesh["triangles"],
            "edges": mesh["edges"],
            "hinges": mesh["hinges"],
            "isGround": (idx == ground_panel),
            "foldCount": n_folds,
            "targetLen": tl,
        })

    if not out_panels:
        return {"status": "error", "message": "No valid panels after triangulation."}

    # Stamps: embed each engulfed outline into its container panel's mesh so the
    # decorative outline rides the fold (like sewing holes). Visual-only.
    stamps: List[Dict[str, Any]] = []
    for j, outs in stamps_src.items():
        if j not in panel_meshes:
            continue
        v2d, tris = panel_meshes[j]
        for outline in outs:
            pts = []
            for (x, y) in outline:
                ti, bary = _embed_point(x, y, v2d, tris)
                pts.append({"tri": ti, "bary": bary})
            if pts:
                stamps.append({"panelId": j, "closed": True, "pts": pts})

    # Sewing holes → ordered chains, each hole embedded in its panel's mesh so it
    # rides the fold. This is the raw material the stitch flagship matches.
    hole_chains: List[Dict[str, Any]] = []
    if holes_in:
        try:
            hole_chains = _build_hole_chains(
                [(float(h[0]), float(h[1])) for h in holes_in], panel_polys, panel_meshes)
        except Exception as e:
            hole_chains = []  # holes are additive; never fail the whole build

    minx, miny, maxx, maxy = _bbox(all_pts)
    return {"status": "ok", "data": {
        "panels": out_panels,
        "bbox": [minx, miny, maxx, maxy],
        "groundPanel": ground_panel,
        "holeChains": hole_chains,
        "engulfed": engulfed,
        "stamps": stamps,
        "allHandles": all_handles,
    }}


OPERATIONS = {
    "build_construct_model": op_build_construct_model,
    "match_chains": op_match_chains,
}
