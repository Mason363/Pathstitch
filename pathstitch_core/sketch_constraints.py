"""2D geometric constraint solver for the sketch engine (Phase 1).

Entities (LINE / CIRCLE / ARC) are lowered to a flat parameter vector and
constraints become residual equations solved with scipy.optimize.least_squares.
A soft "stay close to the current configuration" regularization keeps
under-constrained systems well-posed, so free geometry drags naturally while
constraints are maintained. Diagnostics (DOF, rank, per-entity fully-constrained
detection, conflict/redundancy flags) come from the constraint Jacobian.

Two op families:

* Stateless (`sketch_solve`, `sketch_diagnose`) — the classic file-in→file-out
  contract, used when adding/removing constraints and on project load.
* Stateful session (`session_open/drag/commit/abort`) — holds the ezdxf doc and
  parameter table in memory between drag frames so a live constraint-aware drag
  never pays the file round-trip. One session at a time; a worker restart wipes
  it and the Swift side falls back to aborting the drag.

Constraint record (also the .stch wire format; `branch` is captured here on
first solve and persisted opaquely by the Swift side):

    {"id": "...", "kind": "coincident|horizontal|vertical|parallel|
     perpendicular|tangent|equal|distance|angle|ground",
     "points": [{"handle": "1AF", "role": "start"}], "entities": ["1B0"],
     "value": 25.0, "branch": 1}

Angles are radians internally, degrees at the DXF boundary. Never print to
real stdout here — the worker's frame channel lives there (see worker.py).
"""
import json
import math
import time
import uuid
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import ezdxf
from scipy.optimize import least_squares

SOLVABLE_TYPES = ("LINE", "CIRCLE", "ARC")
CONVERGE_TOL = 1e-6          # mm; residual infinity-norm for "constraints hold"
REG_WEIGHT = 1e-2            # sqrt(lambda), lambda = 1e-4
DRAG_WEIGHT = 0.3            # below constraint weight (1.0) so constraints win
MAX_NFEV = 200               # per solve stage
NULLSPACE_TOL = 1e-6         # nullspace component below this = param determined
MIN_RADIUS = 1e-9

CONSTRAINT_KINDS = (
    "coincident", "horizontal", "vertical", "parallel", "perpendicular",
    "tangent", "equal", "distance", "angle", "ground",
)


class SolveTimeout(Exception):
    """Raised inside the residual closure when the wall-clock cap is hit."""


class ConstraintError(Exception):
    """Structured validation failure; message lists the offending constraint."""


# ---------------------------------------------------------------------------
# Parameter table: entity dicts <-> flat parameter vector
# ---------------------------------------------------------------------------

class ParamTable:
    """Maps LINE/CIRCLE/ARC entity dicts (op_list_entities shape) to a flat
    numpy parameter vector and back.

    Layout per entity: LINE [x1,y1,x2,y2], CIRCLE [cx,cy,r],
    ARC [cx,cy,r,a_start,a_end] with angles in radians and a_end > a_start.
    """

    def __init__(self, ent_dicts: List[Dict[str, Any]]):
        self.meta: List[Dict[str, Any]] = []
        self.by_handle: Dict[str, Dict[str, Any]] = {}
        vals: List[float] = []
        for e in ent_dicts:
            t = e["type"]
            off = len(vals)
            if t == "LINE":
                vals += [e["start"][0], e["start"][1], e["end"][0], e["end"][1]]
                count = 4
            elif t == "CIRCLE":
                vals += [e["center"][0], e["center"][1], e["radius"]]
                count = 3
            elif t == "ARC":
                a0 = math.radians(e["start_angle"])
                a1 = math.radians(e["end_angle"])
                while a1 <= a0:
                    a1 += 2.0 * math.pi
                vals += [e["center"][0], e["center"][1], e["radius"], a0, a1]
                count = 5
            else:
                continue
            m = {"handle": e["handle"], "type": t, "layer": e.get("layer", "0"),
                 "color": e.get("color", 7), "offset": off, "count": count}
            self.meta.append(m)
            self.by_handle[e["handle"]] = m
        self.x0 = np.array(vals, dtype=float)
        self.n = len(vals)

    # -- point addressing ---------------------------------------------------

    def point_spec(self, handle: str, role: str):
        """Returns a spec for evaluating a named point, or None if invalid.

        ("direct", ix, iy) for points that map straight to params;
        ("arc_end", offset, role) for ARC start/end (derived trig points).
        """
        m = self.by_handle.get(handle)
        if m is None:
            return None
        t, off = m["type"], m["offset"]
        if t == "LINE":
            if role == "start":
                return ("direct", off, off + 1)
            if role == "end":
                return ("direct", off + 2, off + 3)
        elif t == "CIRCLE":
            if role == "center":
                return ("direct", off, off + 1)
        elif t == "ARC":
            if role == "center":
                return ("direct", off, off + 1)
            if role in ("start", "end"):
                return ("arc_end", off, role)
        return None

    @staticmethod
    def point_xy(x: np.ndarray, spec) -> Tuple[float, float]:
        if spec[0] == "direct":
            return x[spec[1]], x[spec[2]]
        off, role = spec[1], spec[2]
        a = x[off + 3] if role == "start" else x[off + 4]
        return x[off] + x[off + 2] * math.cos(a), x[off + 1] + x[off + 2] * math.sin(a)

    def line_pts(self, x: np.ndarray, handle: str):
        off = self.by_handle[handle]["offset"]
        return x[off], x[off + 1], x[off + 2], x[off + 3]

    def radius_index(self, handle: str) -> Optional[int]:
        m = self.by_handle[handle]
        if m["type"] in ("CIRCLE", "ARC"):
            return m["offset"] + 2
        return None

    def entity_indices(self, handle: str) -> List[int]:
        m = self.by_handle[handle]
        return list(range(m["offset"], m["offset"] + m["count"]))

    def translatable_indices(self, handle: str) -> List[int]:
        """(index, axis) pairs that shift under a rigid body translation."""
        m = self.by_handle[handle]
        off = m["offset"]
        if m["type"] == "LINE":
            return [(off, 0), (off + 1, 1), (off + 2, 0), (off + 3, 1)]
        return [(off, 0), (off + 1, 1)]  # CIRCLE/ARC center

    def entity_json(self, x: np.ndarray, handle: str) -> Dict[str, Any]:
        """Entity dict in the exact op_list_entities shape (degrees at boundary)."""
        m = self.by_handle[handle]
        off = m["offset"]
        d = {"handle": m["handle"], "type": m["type"], "layer": m["layer"],
             "color": m["color"]}
        if m["type"] == "LINE":
            d["start"] = [x[off], x[off + 1]]
            d["end"] = [x[off + 2], x[off + 3]]
        elif m["type"] == "CIRCLE":
            d["center"] = [x[off], x[off + 1]]
            d["radius"] = x[off + 2]
        else:  # ARC
            d["center"] = [x[off], x[off + 1]]
            d["radius"] = x[off + 2]
            d["start_angle"] = math.degrees(x[off + 3]) % 360.0
            d["end_angle"] = math.degrees(x[off + 4]) % 360.0
        return d

    def changed_handles(self, x: np.ndarray, x_ref: np.ndarray, tol: float = 1e-9):
        out = []
        for m in self.meta:
            sl = slice(m["offset"], m["offset"] + m["count"])
            if not np.allclose(x[sl], x_ref[sl], rtol=0.0, atol=tol):
                out.append(m["handle"])
        return out


# ---------------------------------------------------------------------------
# Constraint compilation: records -> residual closures + hard-pinned params
# ---------------------------------------------------------------------------

def _clamped_len(dx: float, dy: float) -> float:
    return max(math.hypot(dx, dy), 1e-9)


def _wrap_angle(a: float) -> float:
    return (a + math.pi) % (2.0 * math.pi) - math.pi


def _compile(table: ParamTable, constraints: List[Dict[str, Any]]):
    """Compiles constraint records into residual closures over the full vector.

    Returns (funcs, rowmap, pinned) where rowmap is [(constraint_id, n_rows)]
    aligned with funcs and pinned is the set of hard-grounded param indices.
    Mutates records to capture missing `branch` values (deterministic re-solves).
    Raises ConstraintError on invalid records — the caller reports, never crashes.
    """
    x0 = table.x0
    funcs, rowmap = [], []
    pinned: set = set()

    def fail(c, why):
        raise ConstraintError(f"Constraint {c.get('id', '?')} ({c.get('kind', '?')}): {why}")

    def specs(c, n):
        pts = c.get("points") or []
        if len(pts) != n:
            fail(c, f"needs {n} point reference(s)")
        out = []
        for p in pts:
            s = table.point_spec(p.get("handle", ""), p.get("role", ""))
            if s is None:
                fail(c, f"invalid point {p.get('handle')}:{p.get('role')}")
            out.append(s)
        return out

    def line_handles(c, n):
        hs = c.get("entities") or []
        if len(hs) != n:
            fail(c, f"needs {n} entit{'y' if n == 1 else 'ies'}")
        for h in hs:
            m = table.by_handle.get(h)
            if m is None:
                fail(c, f"unknown entity {h}")
            if m["type"] != "LINE":
                fail(c, f"entity {h} must be a LINE")
        return hs

    def add(c, fn, n_rows):
        funcs.append(fn)
        rowmap.append((c.get("id", ""), n_rows))

    for c in constraints:
        kind = c.get("kind")
        if kind not in CONSTRAINT_KINDS:
            fail(c, f"unknown kind '{kind}'")

        if kind == "coincident":
            p, q = specs(c, 2)
            def f(x, p=p, q=q):
                px, py = table.point_xy(x, p)
                qx, qy = table.point_xy(x, q)
                return np.array([px - qx, py - qy])
            add(c, f, 2)

        elif kind in ("horizontal", "vertical"):
            axis = 1 if kind == "horizontal" else 0  # equalize y (horizontal) / x
            ents = c.get("entities") or []
            if ents:
                (h,) = line_handles(c, 1)
                def f(x, h=h, axis=axis):
                    x1, y1, x2, y2 = table.line_pts(x, h)
                    return np.array([(y1 - y2) if axis == 1 else (x1 - x2)])
            else:
                p, q = specs(c, 2)
                def f(x, p=p, q=q, axis=axis):
                    a = table.point_xy(x, p)
                    b = table.point_xy(x, q)
                    return np.array([a[axis] - b[axis]])
            add(c, f, 1)

        elif kind in ("parallel", "perpendicular"):
            h1, h2 = line_handles(c, 2)
            x11, y11, x12, y12 = table.line_pts(x0, h1)
            x21, y21, x22, y22 = table.line_pts(x0, h2)
            char_len = max(0.5 * (_clamped_len(x12 - x11, y12 - y11)
                                  + _clamped_len(x22 - x21, y22 - y21)), 1.0)
            use_cross = (kind == "parallel")
            def f(x, h1=h1, h2=h2, char_len=char_len, use_cross=use_cross):
                a1, b1, a2, b2 = table.line_pts(x, h1)
                c1, d1, c2, d2 = table.line_pts(x, h2)
                u1 = (a2 - a1, b2 - b1)
                u2 = (c2 - c1, d2 - d1)
                denom = _clamped_len(*u1) * _clamped_len(*u2)
                v = (u1[0] * u2[1] - u1[1] * u2[0]) if use_cross else (u1[0] * u2[0] + u1[1] * u2[1])
                return np.array([v / denom * char_len])
            add(c, f, 1)

        elif kind == "equal":
            hs = c.get("entities") or []
            if len(hs) != 2:
                fail(c, "needs 2 entities")
            ms = []
            for h in hs:
                m = table.by_handle.get(h)
                if m is None:
                    fail(c, f"unknown entity {h}")
                ms.append(m)
            types = {m["type"] for m in ms}
            if types == {"LINE"}:
                def f(x, h1=hs[0], h2=hs[1]):
                    a1, b1, a2, b2 = table.line_pts(x, h1)
                    c1, d1, c2, d2 = table.line_pts(x, h2)
                    return np.array([math.hypot(a2 - a1, b2 - b1)
                                     - math.hypot(c2 - c1, d2 - d1)])
            elif types <= {"CIRCLE", "ARC"}:
                r1, r2 = table.radius_index(hs[0]), table.radius_index(hs[1])
                def f(x, r1=r1, r2=r2):
                    return np.array([x[r1] - x[r2]])
            else:
                fail(c, "operands must be two lines or two circles/arcs")
            add(c, f, 1)

        elif kind == "distance":
            if c.get("value") is None:
                fail(c, "needs a value (mm)")
            d = float(c["value"])
            pts = c.get("points") or []
            ents = c.get("entities") or []
            if len(pts) == 2 and not ents:
                p, q = specs(c, 2)
                def f(x, p=p, q=q, d=d):
                    a = table.point_xy(x, p)
                    b = table.point_xy(x, q)
                    return np.array([math.hypot(a[0] - b[0], a[1] - b[1]) - d])
            elif len(pts) == 1 and len(ents) == 1:
                (p,) = specs(c, 1)
                (h,) = line_handles(c, 1)
                if c.get("branch") not in (1, -1):
                    x1, y1, x2, y2 = table.line_pts(x0, h)
                    px, py = table.point_xy(x0, p)
                    cross = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
                    c["branch"] = 1 if cross >= 0 else -1
                s = c["branch"]
                def f(x, p=p, h=h, d=d, s=s):
                    x1, y1, x2, y2 = table.line_pts(x, h)
                    px, py = table.point_xy(x, p)
                    L = _clamped_len(x2 - x1, y2 - y1)
                    cross = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
                    return np.array([cross / L - s * d])
            else:
                fail(c, "needs 2 points, or 1 point + 1 line")
            add(c, f, 1)

        elif kind == "angle":
            if c.get("value") is None:
                fail(c, "needs a value (degrees)")
            alpha = math.radians(float(c["value"]))
            h1, h2 = line_handles(c, 2)
            x11, y11, x12, y12 = table.line_pts(x0, h1)
            x21, y21, x22, y22 = table.line_pts(x0, h2)
            char_len = max(0.5 * (_clamped_len(x12 - x11, y12 - y11)
                                  + _clamped_len(x22 - x21, y22 - y21)), 1.0)
            def f(x, h1=h1, h2=h2, alpha=alpha, char_len=char_len):
                a1, b1, a2, b2 = table.line_pts(x, h1)
                c1, d1, c2, d2 = table.line_pts(x, h2)
                u1 = (a2 - a1, b2 - b1)
                u2 = (c2 - c1, d2 - d1)
                theta = math.atan2(u1[0] * u2[1] - u1[1] * u2[0],
                                   u1[0] * u2[0] + u1[1] * u2[1])
                return np.array([_wrap_angle(theta - alpha) * char_len / math.pi])
            add(c, f, 1)

        elif kind == "tangent":
            hs = c.get("entities") or []
            if len(hs) != 2:
                fail(c, "needs 2 entities")
            ms = []
            for h in hs:
                m = table.by_handle.get(h)
                if m is None:
                    fail(c, f"unknown entity {h}")
                ms.append(m)
            types = [m["type"] for m in ms]
            if "LINE" in types and (set(types) & {"CIRCLE", "ARC"}):
                line_h = hs[types.index("LINE")]
                circ_h = hs[1 - types.index("LINE")]
                ri = table.radius_index(circ_h)
                ci = table.by_handle[circ_h]["offset"]
                if c.get("branch") not in (1, -1):
                    x1, y1, x2, y2 = table.line_pts(x0, line_h)
                    cross = ((x2 - x1) * (x0[ci + 1] - y1)
                             - (y2 - y1) * (x0[ci] - x1))
                    c["branch"] = 1 if cross >= 0 else -1
                s = c["branch"]
                def f(x, line_h=line_h, ci=ci, ri=ri, s=s):
                    x1, y1, x2, y2 = table.line_pts(x, line_h)
                    L = _clamped_len(x2 - x1, y2 - y1)
                    cross = (x2 - x1) * (x[ci + 1] - y1) - (y2 - y1) * (x[ci] - x1)
                    return np.array([cross / L - s * x[ri]])
            elif set(types) <= {"CIRCLE", "ARC"}:
                c1i = table.by_handle[hs[0]]["offset"]
                c2i = table.by_handle[hs[1]]["offset"]
                r1i, r2i = table.radius_index(hs[0]), table.radius_index(hs[1])
                if c.get("branch") not in (1, -1):
                    dist0 = math.hypot(x0[c1i] - x0[c2i], x0[c1i + 1] - x0[c2i + 1])
                    ext = abs(dist0 - (x0[r1i] + x0[r2i]))
                    inte = abs(dist0 - abs(x0[r1i] - x0[r2i]))
                    c["branch"] = 1 if ext <= inte else -1
                s = c["branch"]
                def f(x, c1i=c1i, c2i=c2i, r1i=r1i, r2i=r2i, s=s):
                    dist = math.hypot(x[c1i] - x[c2i], x[c1i + 1] - x[c2i + 1])
                    target = (x[r1i] + x[r2i]) if s == 1 else abs(x[r1i] - x[r2i])
                    return np.array([dist - target])
            else:
                fail(c, "operands must be line + circle/arc or two circles/arcs")
            add(c, f, 1)

        elif kind == "ground":
            pts = c.get("points") or []
            ents = c.get("entities") or []
            if not pts and not ents:
                fail(c, "needs a point or an entity")
            for h in ents:
                if h not in table.by_handle:
                    fail(c, f"unknown entity {h}")
                pinned.update(table.entity_indices(h))
            for p in pts:
                s = table.point_spec(p.get("handle", ""), p.get("role", ""))
                if s is None:
                    fail(c, f"invalid point {p.get('handle')}:{p.get('role')}")
                if s[0] == "direct":
                    pinned.add(s[1])
                    pinned.add(s[2])
                else:
                    # Derived point (arc endpoint): can't pin params directly,
                    # so ground it with equality rows to its current position.
                    tx, ty = table.point_xy(x0, s)
                    def f(x, s=s, tx=tx, ty=ty):
                        px, py = table.point_xy(x, s)
                        return np.array([px - tx, py - ty])
                    add(c, f, 2)

    return funcs, rowmap, pinned


# ---------------------------------------------------------------------------
# Solve + diagnostics
# ---------------------------------------------------------------------------

def _finite_and_sane(table: ParamTable, x: np.ndarray) -> bool:
    if not np.all(np.isfinite(x)):
        return False
    for m in table.meta:
        if m["type"] in ("CIRCLE", "ARC") and x[m["offset"] + 2] <= MIN_RADIUS:
            return False
    return True


def _diagnostics(table, funcs, rowmap, pinned, free, x_eval,
                 solve_ms: float, nfev: int) -> Dict[str, Any]:
    def F(xf):
        if not funcs:
            return np.zeros(0)
        return np.concatenate([fn(xf) for fn in funcs])

    F0 = F(x_eval)
    m = len(F0)
    n_free = len(free)

    if m == 0 or n_free == 0:
        rank = 0
        ns = np.eye(n_free)  # every free param undetermined
        determined_free = np.zeros(n_free, dtype=bool) if n_free else np.zeros(0, dtype=bool)
        if m == 0 and n_free == 0:
            determined_free = np.zeros(0, dtype=bool)
    else:
        J = np.zeros((m, n_free))
        for k, i in enumerate(free):
            h = 1e-6 * (1.0 + abs(x_eval[i]))
            xp = x_eval.copy()
            xp[i] += h
            J[:, k] = (F(xp) - F0) / h
        U, s, Vt = np.linalg.svd(J)
        tol = max(J.shape) * np.finfo(float).eps * (s[0] if s.size else 0.0)
        rank = int(np.sum(s > max(tol, 1e-10)))
        ns = Vt[rank:, :]
        if ns.size:
            determined_free = np.all(np.abs(ns) < NULLSPACE_TOL, axis=0)
        else:
            determined_free = np.ones(n_free, dtype=bool)

    converged = (m == 0) or bool(np.max(np.abs(F0)) < CONVERGE_TOL)

    conflicting: List[str] = []
    if not converged:
        row = 0
        for cid, n_rows in rowmap:
            if np.max(np.abs(F0[row:row + n_rows])) >= CONVERGE_TOL and cid:
                conflicting.append(cid)
            row += n_rows

    redundant = max(0, m - rank) if converged else 0

    determined = {i: True for i in pinned}
    for k, i in enumerate(free):
        determined[i] = bool(determined_free[k]) if n_free else False
    fully = []
    for meta in table.meta:
        idxs = range(meta["offset"], meta["offset"] + meta["count"])
        if all(determined.get(i, False) for i in idxs):
            fully.append(meta["handle"])

    return {
        "converged": converged,
        "dof": max(0, n_free - rank),
        "n_params": n_free,
        "rank": rank,
        "fully_constrained": fully,
        "conflicting_constraints": conflicting,
        "redundant_count": int(redundant),
        "residual_max": float(np.max(np.abs(F0))) if m else 0.0,
        "iterations": int(nfev),
        "solve_ms": round(solve_ms, 3),
    }


def _solve_system(table: ParamTable, constraints: List[Dict[str, Any]],
                  drag: Optional[Dict[str, Any]] = None,
                  time_cap_ms: float = 250.0,
                  x_start: Optional[np.ndarray] = None,
                  x_body_base: Optional[np.ndarray] = None,
                  do_solve: bool = True) -> Dict[str, Any]:
    """Runs the two-stage solve (or a diagnose-only pass when do_solve=False).

    Returns {"x": final vector (reverted to x_start on failure),
             "reverted": bool, "diagnostics": {...}}.
    Raises ConstraintError for invalid records.
    """
    t_begin = time.monotonic()
    funcs, rowmap, pinned = _compile(table, constraints)
    x0 = (x_start if x_start is not None else table.x0).astype(float).copy()
    base = x_body_base if x_body_base is not None else x0
    free = [i for i in range(table.n) if i not in pinned]
    free_arr = np.array(free, dtype=int)
    n_free = len(free)

    def embed(xf: np.ndarray) -> np.ndarray:
        xfull = x0.copy()
        if n_free:
            xfull[free_arr] = xf
        return xfull

    def constraints_F(xfull: np.ndarray) -> np.ndarray:
        if not funcs:
            return np.zeros(0)
        return np.concatenate([fn(xfull) for fn in funcs])

    # Drag rows (soft targets, weight below constraints).
    drag_fn = None
    if drag is not None:
        handle = drag.get("handle", "")
        role = drag.get("role", "body")
        target = drag.get("target") or [float("nan"), float("nan")]
        tx, ty = float(target[0]), float(target[1])
        if not (math.isfinite(tx) and math.isfinite(ty)):
            raise ConstraintError("Drag target is not finite")
        if handle not in table.by_handle:
            raise ConstraintError(f"Drag references unknown entity {handle}")
        if role == "body":
            anchor = drag.get("anchor") or [tx, ty]
            dx, dy = tx - float(anchor[0]), ty - float(anchor[1])
            idx_axes = table.translatable_indices(handle)
            targets = np.array([base[i] + (dx if a == 0 else dy) for i, a in idx_axes])
            idxs = np.array([i for i, _ in idx_axes], dtype=int)
            def drag_fn(xfull, idxs=idxs, targets=targets):
                return DRAG_WEIGHT * (xfull[idxs] - targets)
        else:
            spec = table.point_spec(handle, role)
            if spec is None:
                raise ConstraintError(f"Drag references invalid point {handle}:{role}")
            def drag_fn(xfull, spec=spec, tx=tx, ty=ty):
                px, py = table.point_xy(xfull, spec)
                return DRAG_WEIGHT * np.array([px - tx, py - ty])

    deadline = t_begin + time_cap_ms / 1000.0
    nfev_total = 0
    reverted = False
    x_attempt = x0

    if do_solve and n_free:
        def check_deadline():
            if time.monotonic() > deadline:
                raise SolveTimeout()

        try:
            x0_free = x0[free_arr]
            def fun_a(xf):
                check_deadline()
                xfull = embed(xf)
                rows = [constraints_F(xfull), REG_WEIGHT * (xf - x0_free)]
                if drag_fn is not None:
                    rows.append(drag_fn(xfull))
                return np.concatenate(rows)

            res_a = least_squares(fun_a, x0_free, method="lm", max_nfev=MAX_NFEV)
            nfev_total += res_a.nfev

            # Stage B: constraints only (anchored at stage A) so committed
            # geometry satisfies constraints regardless of drag weights.
            xa = res_a.x
            def fun_b(xf):
                check_deadline()
                return np.concatenate([constraints_F(embed(xf)),
                                       REG_WEIGHT * (xf - xa)])

            res_b = least_squares(fun_b, xa, method="lm", max_nfev=MAX_NFEV)
            nfev_total += res_b.nfev
            x_attempt = embed(res_b.x)
        except SolveTimeout:
            x_attempt = x0
            reverted = True

    solve_ms = (time.monotonic() - t_begin) * 1000.0
    diag = _diagnostics(table, funcs, rowmap, pinned, free, x_attempt,
                        solve_ms, nfev_total)

    if reverted or not _finite_and_sane(table, x_attempt):
        return {"x": x0, "reverted": True,
                "diagnostics": {**diag, "converged": False}}
    if do_solve and not diag["converged"]:
        # Conflicting/unsatisfiable system: report the compromise solution's
        # conflicts but never move geometry away from the last valid state.
        return {"x": x0, "reverted": True, "diagnostics": diag}
    return {"x": x_attempt, "reverted": False, "diagnostics": diag}


# ---------------------------------------------------------------------------
# ezdxf boundary
# ---------------------------------------------------------------------------

def _load_solvables(doc) -> List[Dict[str, Any]]:
    """LINE/CIRCLE/ARC entity dicts straight from the modelspace (no file hop)."""
    out = []
    for ent in doc.modelspace():
        t = ent.dxftype()
        if t not in SOLVABLE_TYPES:
            continue
        d = {"handle": ent.dxf.handle, "type": t, "layer": ent.dxf.layer,
             "color": ent.dxf.color}
        if t == "LINE":
            d["start"] = [ent.dxf.start.x, ent.dxf.start.y]
            d["end"] = [ent.dxf.end.x, ent.dxf.end.y]
        elif t == "CIRCLE":
            d["center"] = [ent.dxf.center.x, ent.dxf.center.y]
            d["radius"] = ent.dxf.radius
        else:  # ARC
            d["center"] = [ent.dxf.center.x, ent.dxf.center.y]
            d["radius"] = ent.dxf.radius
            d["start_angle"] = ent.dxf.start_angle
            d["end_angle"] = ent.dxf.end_angle
        out.append(d)
    return out


def _apply_to_doc(doc, table: ParamTable, x: np.ndarray):
    for m in table.meta:
        ent = doc.entitydb[m["handle"]]
        off = m["offset"]
        if m["type"] == "LINE":
            ent.dxf.start = (float(x[off]), float(x[off + 1]))
            ent.dxf.end = (float(x[off + 2]), float(x[off + 3]))
        elif m["type"] == "CIRCLE":
            ent.dxf.center = (float(x[off]), float(x[off + 1]))
            ent.dxf.radius = float(x[off + 2])
        else:  # ARC
            ent.dxf.center = (float(x[off]), float(x[off + 1]))
            ent.dxf.radius = float(x[off + 2])
            ent.dxf.start_angle = math.degrees(float(x[off + 3])) % 360.0
            ent.dxf.end_angle = math.degrees(float(x[off + 4])) % 360.0


# ---------------------------------------------------------------------------
# Stateless ops
# ---------------------------------------------------------------------------

def op_sketch_solve(args: Dict[str, Any]) -> Dict[str, Any]:
    """Solves the constraint system and writes the result (file-in → file-out).

    On an unsatisfiable/diverged system the file keeps the last valid geometry
    and diagnostics carry the conflict ids (`reverted: true` in the response).
    """
    input_path = args.get("input")
    output_path = args.get("output")
    constraints = args.get("constraints", [])
    if not input_path:
        return {"status": "error", "message": "Input file must be specified."}
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    try:
        doc = ezdxf.readfile(input_path)
    except Exception as e:
        return {"status": "error", "message": f"Cannot read DXF: {e}"}

    table = ParamTable(_load_solvables(doc))
    try:
        res = _solve_system(table, constraints, time_cap_ms=250.0)
    except ConstraintError as e:
        return {"status": "error", "message": str(e)}

    x = res["x"]
    if not _finite_and_sane(table, x):
        return {"status": "error",
                "message": "Solver produced non-finite geometry; nothing written."}
    _apply_to_doc(doc, table, x)
    try:
        doc.saveas(output_path)
    except Exception as e:
        return {"status": "error", "message": f"Failed to write DXF: {e}"}

    changed = table.changed_handles(x, table.x0)
    return {"status": "ok", "data": {
        "entities": [table.entity_json(x, h) for h in changed],
        "constraints": constraints,
        "diagnostics": res["diagnostics"],
        "reverted": res["reverted"],
    }}


def op_sketch_diagnose(args: Dict[str, Any]) -> Dict[str, Any]:
    """Evaluates diagnostics at the current geometry without solving or writing.

    Used on project load and after undo/redo to repopulate solve-state coloring.
    """
    input_path = args.get("input")
    constraints = args.get("constraints", [])
    if not input_path:
        return {"status": "error", "message": "Input file must be specified."}
    try:
        doc = ezdxf.readfile(input_path)
    except Exception as e:
        return {"status": "error", "message": f"Cannot read DXF: {e}"}

    table = ParamTable(_load_solvables(doc))
    try:
        res = _solve_system(table, constraints, do_solve=False)
    except ConstraintError as e:
        return {"status": "error", "message": str(e)}
    return {"status": "ok", "data": {
        "constraints": constraints,
        "diagnostics": res["diagnostics"],
    }}


# ---------------------------------------------------------------------------
# Stateful sketch session (live constraint-aware dragging)
# ---------------------------------------------------------------------------

class SketchSession:
    def __init__(self, doc, constraints: List[Dict[str, Any]]):
        self.doc = doc
        self.constraints = constraints
        self.table = ParamTable(_load_solvables(doc))
        self.x_open = self.table.x0.copy()       # configuration at mouse-down
        self.x_last_valid = self.table.x0.copy()
        self.session_id = uuid.uuid4().hex


_SESSION: Optional[SketchSession] = None


def _get_session(args: Dict[str, Any]) -> Optional[SketchSession]:
    sid = args.get("session_id")
    if _SESSION is not None and sid == _SESSION.session_id:
        return _SESSION
    return None


def op_session_open(args: Dict[str, Any]) -> Dict[str, Any]:
    """Opens a sketch session: in-memory doc + constraint system, no writes."""
    global _SESSION
    input_path = args.get("input")
    constraints = args.get("constraints", [])
    if not input_path:
        return {"status": "error", "message": "Input file must be specified."}
    try:
        doc = ezdxf.readfile(input_path)
    except Exception as e:
        return {"status": "error", "message": f"Cannot read DXF: {e}"}

    sess = SketchSession(doc, constraints)
    try:
        res = _solve_system(sess.table, constraints, do_solve=False)
    except ConstraintError as e:
        return {"status": "error", "message": str(e)}
    _SESSION = sess
    return {"status": "ok", "data": {
        "session_id": sess.session_id,
        "diagnostics": res["diagnostics"],
    }}


def op_session_drag(args: Dict[str, Any]) -> Dict[str, Any]:
    """One drag frame: solve with a soft target on the grabbed point/body.

    On divergence/timeout returns the last valid configuration (`reverted`).
    50 ms wall-clock cap keeps the frame budget.
    """
    sess = _get_session(args)
    if sess is None:
        return {"status": "error", "message": "No matching sketch session (worker restarted?)."}
    drag = args.get("drag") or {}

    x_before = sess.x_last_valid
    try:
        res = _solve_system(sess.table, sess.constraints, drag=drag,
                            time_cap_ms=50.0, x_start=x_before,
                            x_body_base=sess.x_open)
    except ConstraintError as e:
        # Bad drag payload (NaN target, unknown handle): keep last valid.
        return {"status": "ok", "data": {
            "entities": [sess.table.entity_json(x_before, m["handle"])
                         for m in sess.table.meta],
            "diagnostics": _diag_at(sess, x_before),
            "reverted": True,
            "message": str(e),
        }}

    if res["reverted"]:
        x = x_before
    else:
        x = res["x"]
        sess.x_last_valid = x

    changed = set(sess.table.changed_handles(x, x_before))
    if drag.get("handle") in sess.table.by_handle:
        changed.add(drag["handle"])
    return {"status": "ok", "data": {
        "entities": [sess.table.entity_json(x, h) for h in sorted(changed)],
        "diagnostics": res["diagnostics"],
        "reverted": res["reverted"],
    }}


def _diag_at(sess: SketchSession, x: np.ndarray) -> Dict[str, Any]:
    try:
        funcs, rowmap, pinned = _compile(sess.table, sess.constraints)
        free = [i for i in range(sess.table.n) if i not in pinned]
        return _diagnostics(sess.table, funcs, rowmap, pinned, free, x, 0.0, 0)
    except ConstraintError:
        return {"converged": False, "dof": 0, "n_params": 0, "rank": 0,
                "fully_constrained": [], "conflicting_constraints": [],
                "redundant_count": 0, "residual_max": 0.0,
                "iterations": 0, "solve_ms": 0.0}


def op_session_commit(args: Dict[str, Any]) -> Dict[str, Any]:
    """Final polish solve, NaN guard, write the file, close the session."""
    global _SESSION
    sess = _get_session(args)
    if sess is None:
        return {"status": "error", "message": "No matching sketch session (worker restarted?)."}
    output_path = args.get("output")
    if not output_path:
        return {"status": "error", "message": "Output path must be specified."}

    try:
        res = _solve_system(sess.table, sess.constraints, time_cap_ms=250.0,
                            x_start=sess.x_last_valid)
    except ConstraintError as e:
        _SESSION = None
        return {"status": "error", "message": str(e)}

    x = res["x"] if not res["reverted"] else sess.x_last_valid
    if not _finite_and_sane(sess.table, x):
        x = sess.x_open  # never write garbage; fall back to the open state
    _apply_to_doc(sess.doc, sess.table, x)
    try:
        sess.doc.saveas(output_path)
    except Exception as e:
        _SESSION = None
        return {"status": "error", "message": f"Failed to write DXF: {e}"}

    diag = res["diagnostics"]
    entities = [sess.table.entity_json(x, m["handle"]) for m in sess.table.meta]
    _SESSION = None
    return {"status": "ok", "data": {
        "entities": entities,
        "diagnostics": diag,
        "reverted": res["reverted"],
    }}


def op_session_abort(args: Dict[str, Any]) -> Dict[str, Any]:
    """Closes the session without writing anything. Idempotent."""
    global _SESSION
    sess = _get_session(args)
    if sess is not None:
        _SESSION = None
    return {"status": "ok", "data": {}}


OPERATIONS = {
    "sketch_solve": op_sketch_solve,
    "sketch_diagnose": op_sketch_diagnose,
    "session_open": op_session_open,
    "session_drag": op_session_drag,
    "session_commit": op_session_commit,
    "session_abort": op_session_abort,
}


def main():
    """CLI entry mirroring dxf_ops: python -m pathstitch_core.sketch_constraints --json '...'"""
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", required=True)
    parsed = parser.parse_args()
    payload = json.loads(parsed.json)
    fn = OPERATIONS.get(payload.get("op"))
    if fn is None:
        result = {"status": "error", "message": f"Unknown operation: {payload.get('op')}"}
    else:
        try:
            result = fn(payload.get("args", {}))
        except Exception as e:
            result = {"status": "error", "message": f"Operation failed: {e}"}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
