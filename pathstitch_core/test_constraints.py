"""Tests for the 2D geometric constraint solver (sketch_constraints.py).

Solver-math tests call the module in-process (fast, precise assertions); one
CLI round-trip verifies the op boundary. Run with the conda `pathstitch` env:

    /opt/homebrew/Caskroom/miniconda/base/envs/pathstitch/bin/python -m pathstitch_core.test_constraints
"""
import json
import math
import os
import subprocess
import tempfile
import time

import ezdxf

from pathstitch_core import sketch_constraints as sc
from pathstitch_core.dxf_ops import op_list_entities

PYTHON_BIN = "/opt/homebrew/Caskroom/miniconda/base/envs/pathstitch/bin/python"

TMP = tempfile.mkdtemp(prefix="pathstitch_constraints_")


def _new_doc():
    doc = ezdxf.new("R2010")
    return doc, doc.modelspace()


def _save(doc, name):
    path = os.path.join(TMP, name)
    doc.saveas(path)
    return path


def _pt(handle, role):
    return {"handle": handle, "role": role}


def _c(kind, points=None, entities=None, value=None, cid=None):
    c = {"id": cid or f"{kind}-{len(points or [])}-{len(entities or [])}-{id(points) % 9999}",
         "kind": kind}
    if points:
        c["points"] = points
    if entities:
        c["entities"] = entities
    if value is not None:
        c["value"] = value
    return c


def _solve_inproc(path_in, path_out, constraints):
    return sc.op_sketch_solve({"input": path_in, "output": path_out,
                               "constraints": constraints})


def _entity_map(path):
    res = op_list_entities({"input": path})
    assert res["status"] == "ok", res
    return {e["handle"]: e for e in res["data"]["entities"]}


def _dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


# ---------------------------------------------------------------------------
# Convergence per constraint kind
# ---------------------------------------------------------------------------

def test_perpendicular_corner():
    """Two lines: coincident corner + perpendicular + fixed lengths."""
    doc, msp = _new_doc()
    l1 = msp.add_line((0, 0), (10.2, 0.7)).dxf.handle
    l2 = msp.add_line((10.5, 1.1), (11.0, 9.0)).dxf.handle
    src = _save(doc, "perp_in.dxf")
    out = os.path.join(TMP, "perp_out.dxf")
    cons = [
        _c("ground", points=[_pt(l1, "start")], cid="g"),
        _c("coincident", points=[_pt(l1, "end"), _pt(l2, "start")], cid="co"),
        _c("perpendicular", entities=[l1, l2], cid="pe"),
        _c("horizontal", entities=[l1], cid="h"),
        _c("distance", points=[_pt(l1, "start"), _pt(l1, "end")], value=10.0, cid="d1"),
        _c("distance", points=[_pt(l2, "start"), _pt(l2, "end")], value=8.0, cid="d2"),
    ]
    res = _solve_inproc(src, out, cons)
    assert res["status"] == "ok", res
    d = res["data"]["diagnostics"]
    assert d["converged"], d
    assert not res["data"]["reverted"]
    ents = _entity_map(out)
    a, b = ents[l1], ents[l2]
    assert abs(a["start"][0]) < 1e-6 and abs(a["start"][1]) < 1e-6  # grounded
    assert abs(a["end"][1] - a["start"][1]) < 1e-6                  # horizontal
    assert abs(_dist(a["start"], a["end"]) - 10.0) < 1e-5
    assert abs(_dist(b["start"], b["end"]) - 8.0) < 1e-5
    assert _dist(a["end"], b["start"]) < 1e-5                        # coincident
    u1 = (a["end"][0] - a["start"][0], a["end"][1] - a["start"][1])
    u2 = (b["end"][0] - b["start"][0], b["end"][1] - b["start"][1])
    dot = u1[0] * u2[0] + u1[1] * u2[1]
    assert abs(dot) < 1e-4, f"not perpendicular: dot={dot}"
    print("  perpendicular corner ok")


def test_parallel_equal_vertical():
    doc, msp = _new_doc()
    l1 = msp.add_line((0, 0), (0.4, 10.0)).dxf.handle
    l2 = msp.add_line((5, 0.2), (5.5, 7.0)).dxf.handle
    src = _save(doc, "par_in.dxf")
    out = os.path.join(TMP, "par_out.dxf")
    cons = [
        _c("ground", entities=[l1], cid="g"),
        _c("parallel", entities=[l1, l2], cid="pa"),
        _c("equal", entities=[l1, l2], cid="eq"),
    ]
    res = _solve_inproc(src, out, cons)
    d = res["data"]["diagnostics"]
    assert d["converged"], d
    ents = _entity_map(out)
    a, b = ents[l1], ents[l2]
    u1 = (a["end"][0] - a["start"][0], a["end"][1] - a["start"][1])
    u2 = (b["end"][0] - b["start"][0], b["end"][1] - b["start"][1])
    cross = u1[0] * u2[1] - u1[1] * u2[0]
    assert abs(cross) < 1e-3, f"not parallel: cross={cross}"
    assert abs(_dist(a["start"], a["end"]) - _dist(b["start"], b["end"])) < 1e-5

    # vertical alone (parallel-to-grounded-slanted-line would conflict)
    cons2 = [_c("ground", points=[_pt(l2, "start")], cid="g2"),
             _c("vertical", entities=[l2], cid="v")]
    res2 = _solve_inproc(src, out, cons2)
    d2 = res2["data"]["diagnostics"]
    assert d2["converged"], d2
    b2 = _entity_map(out)[l2]
    assert abs(b2["start"][0] - b2["end"][0]) < 1e-5
    print("  parallel + equal + vertical ok")


def test_tangent_line_circle_both_branches():
    for side, y_c in (("above", 5.0), ("below", -5.0)):
        doc, msp = _new_doc()
        ln = msp.add_line((0, 0), (20, 0)).dxf.handle
        ci = msp.add_circle((10, y_c), 3.0).dxf.handle
        src = _save(doc, f"tan_{side}_in.dxf")
        out = os.path.join(TMP, f"tan_{side}_out.dxf")
        cons = [
            _c("ground", entities=[ln], cid="g"),
            _c("tangent", entities=[ln, ci], cid="t"),
        ]
        res = _solve_inproc(src, out, cons)
        d = res["data"]["diagnostics"]
        assert d["converged"], (side, d)
        # Branch must be captured into the returned record.
        tan = [c for c in res["data"]["constraints"] if c["id"] == "t"][0]
        assert tan.get("branch") in (1, -1)
        c = _entity_map(out)[ci]
        # Distance from center to the (grounded, y=0) line equals radius,
        # and the center stays on its original side.
        assert abs(abs(c["center"][1]) - c["radius"]) < 1e-5
        assert (c["center"][1] > 0) == (y_c > 0), "tangency flipped sides"
    print("  tangent line-circle (both branches) ok")


def test_tangent_circle_circle():
    # External tangency
    doc, msp = _new_doc()
    c1 = msp.add_circle((0, 0), 5.0).dxf.handle
    c2 = msp.add_circle((12, 0), 4.0).dxf.handle
    src = _save(doc, "tcc_in.dxf")
    out = os.path.join(TMP, "tcc_out.dxf")
    cons = [_c("ground", entities=[c1], cid="g"),
            _c("tangent", entities=[c1, c2], cid="t")]
    res = _solve_inproc(src, out, cons)
    assert res["data"]["diagnostics"]["converged"]
    ents = _entity_map(out)
    d = _dist(ents[c1]["center"], ents[c2]["center"])
    assert abs(d - (ents[c1]["radius"] + ents[c2]["radius"])) < 1e-5

    # Internal tangency (small circle inside big one)
    doc, msp = _new_doc()
    c1 = msp.add_circle((0, 0), 10.0).dxf.handle
    c2 = msp.add_circle((5.5, 0), 3.0).dxf.handle
    src = _save(doc, "tcci_in.dxf")
    out = os.path.join(TMP, "tcci_out.dxf")
    cons = [_c("ground", entities=[c1], cid="g"),
            _c("tangent", entities=[c1, c2], cid="t")]
    res = _solve_inproc(src, out, cons)
    assert res["data"]["diagnostics"]["converged"]
    ents = _entity_map(out)
    d = _dist(ents[c1]["center"], ents[c2]["center"])
    assert abs(d - abs(ents[c1]["radius"] - ents[c2]["radius"])) < 1e-5
    print("  tangent circle-circle (external + internal) ok")


def test_arc_endpoint_coincident_and_wrap():
    """Arc endpoint bound to a line end; arc initially crosses 0 degrees."""
    doc, msp = _new_doc()
    # Arc from 300° to 60° (crosses 0)
    arc = msp.add_arc((0, 0), radius=5.0, start_angle=300, end_angle=60).dxf.handle
    ln = msp.add_line((8, 1), (15, 1)).dxf.handle
    src = _save(doc, "arc_in.dxf")
    out = os.path.join(TMP, "arc_out.dxf")
    cons = [
        _c("ground", entities=[arc], cid="g"),
        _c("coincident", points=[_pt(arc, "end"), _pt(ln, "start")], cid="co"),
    ]
    res = _solve_inproc(src, out, cons)
    d = res["data"]["diagnostics"]
    assert d["converged"], d
    ents = _entity_map(out)
    a, l = ents[arc], ents[ln]
    # Arc unchanged (grounded), including the 0-crossing angles.
    assert abs(a["start_angle"] - 300.0) < 1e-6 and abs(a["end_angle"] - 60.0) < 1e-6
    end_pt = (a["center"][0] + a["radius"] * math.cos(math.radians(a["end_angle"])),
              a["center"][1] + a["radius"] * math.sin(math.radians(a["end_angle"])))
    assert _dist(end_pt, l["start"]) < 1e-5
    print("  arc endpoint coincident + 0-degree wrap ok")


def test_angle_and_point_line_distance():
    doc, msp = _new_doc()
    l1 = msp.add_line((0, 0), (10, 0)).dxf.handle
    l2 = msp.add_line((0, 0), (8, 3)).dxf.handle
    ci = msp.add_circle((5, 4), 1.0).dxf.handle
    src = _save(doc, "ang_in.dxf")
    out = os.path.join(TMP, "ang_out.dxf")
    cons = [
        _c("ground", entities=[l1], cid="g"),
        _c("coincident", points=[_pt(l1, "start"), _pt(l2, "start")], cid="co"),
        _c("angle", entities=[l1, l2], value=30.0, cid="an"),
        _c("distance", points=[_pt(ci, "center")], entities=[l1], value=7.0, cid="pl"),
    ]
    res = _solve_inproc(src, out, cons)
    d = res["data"]["diagnostics"]
    assert d["converged"], d
    ents = _entity_map(out)
    b = ents[l2]
    theta = math.degrees(math.atan2(b["end"][1] - b["start"][1],
                                    b["end"][0] - b["start"][0]))
    assert abs(theta - 30.0) < 1e-3, f"angle={theta}"
    c = ents[ci]
    assert abs(c["center"][1] - 7.0) < 1e-5  # signed distance above the x-axis line
    print("  angle + point-line distance ok")


# ---------------------------------------------------------------------------
# DOF math / diagnostics
# ---------------------------------------------------------------------------

def test_dof_readout():
    doc, msp = _new_doc()
    ln = msp.add_line((0, 0), (10, 0)).dxf.handle
    src = _save(doc, "dof_in.dxf")

    res = sc.op_sketch_diagnose({"input": src, "constraints": []})
    d = res["data"]["diagnostics"]
    assert d["dof"] == 4, d
    assert d["fully_constrained"] == [], d
    assert d["converged"], d

    res = sc.op_sketch_diagnose({"input": src,
                                 "constraints": [_c("ground", entities=[ln], cid="g")]})
    d = res["data"]["diagnostics"]
    assert d["dof"] == 0, d
    assert d["fully_constrained"] == [ln], d
    print("  DOF readout (free=4, grounded=0) ok")


def test_rectangle_fully_constrained():
    doc, msp = _new_doc()
    # Four sloppy lines, roughly a rectangle.
    b = msp.add_line((0.1, -0.2), (10.3, 0.15)).dxf.handle   # bottom
    r = msp.add_line((10.4, 0.2), (10.1, 6.2)).dxf.handle    # right
    t = msp.add_line((10.0, 6.4), (-0.2, 6.0)).dxf.handle    # top
    l = msp.add_line((-0.1, 5.9), (0.05, 0.1)).dxf.handle    # left
    src = _save(doc, "rect_in.dxf")
    out = os.path.join(TMP, "rect_out.dxf")
    cons = [
        _c("ground", points=[_pt(b, "start")], cid="g"),
        _c("coincident", points=[_pt(b, "end"), _pt(r, "start")], cid="c1"),
        _c("coincident", points=[_pt(r, "end"), _pt(t, "start")], cid="c2"),
        _c("coincident", points=[_pt(t, "end"), _pt(l, "start")], cid="c3"),
        _c("coincident", points=[_pt(l, "end"), _pt(b, "start")], cid="c4"),
        _c("horizontal", entities=[b], cid="h1"),
        _c("horizontal", entities=[t], cid="h2"),
        _c("vertical", entities=[r], cid="v1"),
        _c("vertical", entities=[l], cid="v2"),
        _c("distance", points=[_pt(b, "start"), _pt(b, "end")], value=10.0, cid="d1"),
        _c("distance", points=[_pt(r, "start"), _pt(r, "end")], value=6.0, cid="d2"),
    ]
    res = _solve_inproc(src, out, cons)
    d = res["data"]["diagnostics"]
    assert d["converged"], d
    assert d["dof"] == 0, d
    assert sorted(d["fully_constrained"]) == sorted([b, r, t, l]), d
    ents = _entity_map(out)
    assert abs(_dist(ents[b]["start"], ents[b]["end"]) - 10.0) < 1e-5
    assert abs(_dist(ents[r]["start"], ents[r]["end"]) - 6.0) < 1e-5
    print("  rectangle-of-4-lines fully constrained (dof 0) ok")


def test_conflict_and_redundancy():
    doc, msp = _new_doc()
    l1 = msp.add_line((0, 0), (10, 0)).dxf.handle
    src = _save(doc, "conf_in.dxf")
    out = os.path.join(TMP, "conf_out.dxf")

    # Conflicting distances: 10 vs 12 between the same endpoints.
    cons = [
        _c("ground", points=[_pt(l1, "start")], cid="g"),
        _c("distance", points=[_pt(l1, "start"), _pt(l1, "end")], value=10.0, cid="d10"),
        _c("distance", points=[_pt(l1, "start"), _pt(l1, "end")], value=12.0, cid="d12"),
    ]
    res = _solve_inproc(src, out, cons)
    d = res["data"]["diagnostics"]
    assert not d["converged"], d
    assert res["data"]["reverted"], res["data"]
    assert set(d["conflicting_constraints"]) == {"d10", "d12"}, d
    # Geometry untouched (last valid = input).
    ents = _entity_map(out)
    assert _dist(ents[l1]["end"], (10, 0)) < 1e-9

    # Redundant (consistent duplicate): two horizontals on one line.
    cons = [
        _c("horizontal", entities=[l1], cid="h1"),
        _c("horizontal", entities=[l1], cid="h2"),
    ]
    res = _solve_inproc(src, out, cons)
    d = res["data"]["diagnostics"]
    assert d["converged"], d
    assert d["redundant_count"] >= 1, d
    assert d["conflicting_constraints"] == [], d
    print("  conflict flagging + redundancy detection ok")


def test_zero_constraints_noop():
    doc, msp = _new_doc()
    msp.add_line((1.5, 2.5), (9.25, -3.125))
    msp.add_circle((4, 4), 2.0)
    src = _save(doc, "noop_in.dxf")
    out = os.path.join(TMP, "noop_out.dxf")
    before = _entity_map(src)
    res = _solve_inproc(src, out, [])
    assert res["status"] == "ok"
    assert res["data"]["entities"] == []          # nothing changed
    after = _entity_map(out)
    for h, e in before.items():
        for k in ("start", "end", "center"):
            if k in e:
                assert _dist(e[k], after[h][k]) < 1e-12
        if "radius" in e:
            assert abs(e["radius"] - after[h]["radius"]) < 1e-12
    print("  zero-constraint solve is a geometric no-op ok")


# ---------------------------------------------------------------------------
# Session lifecycle + robustness
# ---------------------------------------------------------------------------

def test_session_lifecycle():
    doc, msp = _new_doc()
    l1 = msp.add_line((0, 0), (10, 0)).dxf.handle
    l2 = msp.add_line((10, 0), (10, 8)).dxf.handle
    src = _save(doc, "sess_in.dxf")
    out = os.path.join(TMP, "sess_out.dxf")
    cons = [
        _c("coincident", points=[_pt(l1, "end"), _pt(l2, "start")], cid="co"),
        _c("perpendicular", entities=[l1, l2], cid="pe"),
    ]
    res = sc.op_session_open({"input": src, "constraints": cons})
    assert res["status"] == "ok", res
    sid = res["data"]["session_id"]

    # Bad session id is rejected.
    bad = sc.op_session_drag({"session_id": "nope", "drag": {}})
    assert bad["status"] == "error"

    # 20 drag frames of l2's free end; perpendicularity must hold each frame.
    for i in range(1, 21):
        tx, ty = 10 + i * 0.3, 8 + i * 0.2
        res = sc.op_session_drag({"session_id": sid, "drag": {
            "handle": l2, "role": "end", "target": [tx, ty]}})
        assert res["status"] == "ok", res
        assert not res["data"]["reverted"], res["data"]
        ents = {e["handle"]: e for e in res["data"]["entities"]}
        assert l2 in ents
        a = ents.get(l1) or None
        b = ents[l2]
        if a is not None:
            u1 = (a["end"][0] - a["start"][0], a["end"][1] - a["start"][1])
        else:
            u1 = (10, 0)  # l1 unchanged this frame
        u2 = (b["end"][0] - b["start"][0], b["end"][1] - b["start"][1])
        dot = u1[0] * u2[0] + u1[1] * u2[1]
        L = math.hypot(*u1) * math.hypot(*u2)
        assert abs(dot / L) < 1e-5, f"frame {i}: perpendicularity lost ({dot / L})"

    res = sc.op_session_commit({"session_id": sid, "output": out})
    assert res["status"] == "ok", res
    assert res["data"]["diagnostics"]["converged"]
    ents = _entity_map(out)
    assert set(ents.keys()) == {l1, l2}, "handles changed across commit"
    # A second commit fails (session closed).
    res = sc.op_session_commit({"session_id": sid, "output": out})
    assert res["status"] == "error"
    print("  session lifecycle (open -> 20 drags -> commit) ok")


def test_session_nan_and_divergence_safety():
    doc, msp = _new_doc()
    l1 = msp.add_line((0, 0), (10, 0)).dxf.handle
    src = _save(doc, "nan_in.dxf")
    out = os.path.join(TMP, "nan_out.dxf")
    cons = [_c("distance", points=[_pt(l1, "start"), _pt(l1, "end")],
               value=10.0, cid="d")]
    res = sc.op_session_open({"input": src, "constraints": cons})
    sid = res["data"]["session_id"]

    # One valid drag to establish a last-valid state away from the origin.
    res = sc.op_session_drag({"session_id": sid, "drag": {
        "handle": l1, "role": "end", "target": [9.0, 3.0]}})
    assert not res["data"]["reverted"]
    good = {e["handle"]: e for e in res["data"]["entities"]}[l1]

    # NaN target → reverted, all coordinates finite and equal to last valid.
    res = sc.op_session_drag({"session_id": sid, "drag": {
        "handle": l1, "role": "end", "target": [float("nan"), 0.0]}})
    assert res["status"] == "ok"
    assert res["data"]["reverted"] is True
    ents = {e["handle"]: e for e in res["data"]["entities"]}
    e = ents[l1]
    for k in ("start", "end"):
        assert all(math.isfinite(v) for v in e[k])
        assert _dist(e[k], good[k]) < 1e-9, "revert did not return last valid"

    # Commit after the bad frame writes last valid.
    res = sc.op_session_commit({"session_id": sid, "output": out})
    assert res["status"] == "ok"
    ents = _entity_map(out)
    assert _dist(ents[l1]["end"], good["end"]) < 1e-6
    assert abs(_dist(ents[l1]["start"], ents[l1]["end"]) - 10.0) < 1e-5
    print("  NaN-target revert + commit-last-valid ok")


def test_iteration_cap():
    """A pathological system must terminate within the caps, not hang."""
    doc, msp = _new_doc()
    handles = [msp.add_line((i, 0), (i + 1, 1)).dxf.handle for i in range(6)]
    src = _save(doc, "cap_in.dxf")
    out = os.path.join(TMP, "cap_out.dxf")
    # Chain of contradictory distances.
    cons = [_c("ground", points=[_pt(handles[0], "start")], cid="g")]
    for i, h in enumerate(handles):
        cons.append(_c("distance", points=[_pt(h, "start"), _pt(h, "end")],
                       value=5.0, cid=f"a{i}"))
        cons.append(_c("distance", points=[_pt(h, "start"), _pt(h, "end")],
                       value=50.0, cid=f"b{i}"))
    t0 = time.monotonic()
    res = _solve_inproc(src, out, cons)
    elapsed = time.monotonic() - t0
    assert res["status"] == "ok"
    assert elapsed < 5.0, f"solve did not respect caps ({elapsed:.1f}s)"
    d = res["data"]["diagnostics"]
    assert not d["converged"]
    assert res["data"]["reverted"]
    print(f"  iteration/time caps ok ({elapsed * 1000:.0f} ms)")


def test_invalid_constraints_are_structured_errors():
    doc, msp = _new_doc()
    msp.add_line((0, 0), (10, 0))
    src = _save(doc, "bad_in.dxf")
    out = os.path.join(TMP, "bad_out.dxf")
    for cons in (
        [_c("frobnicate", entities=["FF"], cid="x1")],
        [_c("coincident", points=[_pt("DEADBEEF", "start"), _pt("DEADBEEF", "end")], cid="x2")],
        [_c("distance", points=[], cid="x3")],
    ):
        res = _solve_inproc(src, out, cons)
        assert res["status"] == "error", res
        assert cons[0]["id"] in res["message"] or "Constraint" in res["message"]
    print("  invalid constraints return structured errors ok")


# ---------------------------------------------------------------------------
# Wire boundary + benchmark
# ---------------------------------------------------------------------------

def test_cli_roundtrip():
    doc, msp = _new_doc()
    ln = msp.add_line((0, 0), (10, 1)).dxf.handle
    src = _save(doc, "cli_in.dxf")
    out = os.path.join(TMP, "cli_out.dxf")
    payload = json.dumps({"op": "sketch_solve", "args": {
        "input": src, "output": out,
        "constraints": [{"id": "h", "kind": "horizontal", "entities": [ln]}],
    }})
    proc = subprocess.run(
        [PYTHON_BIN, "-m", "pathstitch_core.sketch_constraints", "--json", payload],
        capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    res = json.loads(proc.stdout)
    assert res["status"] == "ok", res
    assert res["data"]["diagnostics"]["converged"]
    ents = _entity_map(out)
    assert abs(ents[ln]["start"][1] - ents[ln]["end"][1]) < 1e-6
    print("  CLI round-trip ok")


def test_drag_benchmark():
    """p95 session_drag solve time for a 10-entity / 12-constraint sketch."""
    doc, msp = _new_doc()
    lines = [msp.add_line((i * 10.0, 0), (i * 10.0 + 10.0, 0.5)).dxf.handle
             for i in range(8)]
    circles = [msp.add_circle((5 + i * 30.0, 8), 3.0).dxf.handle for i in range(2)]
    src = _save(doc, "bench_in.dxf")
    cons = [_c("ground", points=[_pt(lines[0], "start")], cid="g")]
    for i in range(7):
        cons.append(_c("coincident",
                       points=[_pt(lines[i], "end"), _pt(lines[i + 1], "start")],
                       cid=f"c{i}"))
    cons.append(_c("horizontal", entities=[lines[0]], cid="h0"))
    cons.append(_c("parallel", entities=[lines[0], lines[4]], cid="p0"))
    cons.append(_c("equal", entities=[circles[0], circles[1]], cid="eq"))
    cons.append(_c("tangent", entities=[lines[1], circles[0]], cid="t0"))
    assert len(cons) == 12

    res = sc.op_session_open({"input": src, "constraints": cons})
    assert res["status"] == "ok", res
    sid = res["data"]["session_id"]
    times = []
    for i in range(500):
        t = [75.0 + math.sin(i / 20.0) * 8.0, 2.0 + math.cos(i / 17.0) * 5.0]
        r = sc.op_session_drag({"session_id": sid, "drag": {
            "handle": lines[7], "role": "end", "target": t}})
        assert r["status"] == "ok"
        times.append(r["data"]["diagnostics"]["solve_ms"])
    sc.op_session_abort({"session_id": sid})
    times.sort()
    p50, p95 = times[len(times) // 2], times[int(len(times) * 0.95)]
    print(f"  drag benchmark: p50={p50:.1f} ms  p95={p95:.1f} ms (500 frames)")
    assert p95 < 15.0, f"p95 solve time {p95:.1f} ms exceeds 15 ms budget"


# ---------------------------------------------------------------------------
# Phase 2: inference + explode-to-lines
# ---------------------------------------------------------------------------

def _infer(path, handles, constraints=None):
    res = sc.op_infer_constraints({"input": path, "handles": handles,
                                   "constraints": constraints or []})
    assert res["status"] == "ok", res
    return res["data"]["proposed"]


def test_inference_chain_and_hv():
    """Snapped chain + axis-aligned line → coincident + horizontal/vertical."""
    doc, msp = _new_doc()
    l1 = msp.add_line((0, 0), (10, 0)).dxf.handle          # exactly horizontal
    l2 = msp.add_line((10, 0), (10, 8)).dxf.handle         # snapped to l1.end, vertical
    l3 = msp.add_line((3, 2), (9, 7.5)).dxf.handle         # sloppy, touches nothing
    src = _save(doc, "inf_in.dxf")

    props = _infer(src, [l2])
    kinds = sorted(p["kind"] for p in props)
    assert kinds == ["coincident", "vertical"], props
    co = [p for p in props if p["kind"] == "coincident"][0]
    refs = {(p["handle"], p["role"]) for p in co["points"]}
    assert refs == {(l2, "start"), (l1, "end")}, co

    props = _infer(src, [l1])
    assert sorted(p["kind"] for p in props) == ["coincident", "horizontal"], props

    # The sloppy line proposes nothing (no false positives).
    assert _infer(src, [l3]) == []

    # Dedupe: with the constraints already present, nothing is re-proposed.
    existing = [
        {"id": "c1", "kind": "coincident",
         "points": [{"handle": l2, "role": "start"}, {"handle": l1, "role": "end"}]},
        {"id": "v1", "kind": "vertical", "entities": [l2]},
    ]
    assert _infer(src, [l2], existing) == []
    print("  inference: chain coincident + H/V + no false positives + dedupe ok")


def test_inference_unionfind():
    """Three endpoints meeting at one corner → 2 coincidents, never 3."""
    doc, msp = _new_doc()
    l1 = msp.add_line((0, 0), (5, 5)).dxf.handle
    l2 = msp.add_line((5, 5), (10, 0)).dxf.handle
    l3 = msp.add_line((5, 5), (5, 12)).dxf.handle
    src = _save(doc, "inf_uf_in.dxf")
    props = _infer(src, [l1, l2, l3])
    co = [p for p in props if p["kind"] == "coincident"]
    assert len(co) == 2, props
    print("  inference: union-find keeps 3-way corner at 2 coincidents ok")


def test_inference_tangent():
    doc, msp = _new_doc()
    ci = msp.add_circle((5, 3), 3.0).dxf.handle
    tan = msp.add_line((0, 0), (10, 0)).dxf.handle          # tangent (dist 3 = r)
    far = msp.add_line((0, -5), (10, -5)).dxf.handle        # not tangent
    off_seg = msp.add_line((40, 0), (50, 0)).dxf.handle     # tangent line, wrong span
    c2 = msp.add_circle((11, 3), 3.0).dxf.handle            # externally tangent to ci
    src = _save(doc, "inf_tan_in.dxf")

    props = _infer(src, [tan])
    assert any(p["kind"] == "tangent" and set(p["entities"]) == {tan, ci} for p in props), props
    assert all(p["kind"] != "tangent" or set(p["entities"]) == {tan, ci} for p in props)
    assert not any(p["kind"] == "tangent" for p in _infer(src, [far]))
    assert not any(p["kind"] == "tangent" for p in _infer(src, [off_seg]))

    props = _infer(src, [c2])
    assert any(p["kind"] == "tangent" and set(p["entities"]) == {c2, ci} for p in props), props
    print("  inference: tangent (line-circle span-guarded + circle-circle) ok")


def test_explode_to_lines_and_constrain():
    """Rounded-rect polyline → 4 LINEs + 4 ARCs; plain rect explodes then
    infers into a fully stitched, solvable frame."""
    doc, msp = _new_doc()
    # Plain rectangle.
    rect = msp.add_lwpolyline([(0, 0), (20, 0), (20, 10), (0, 10)], close=True).dxf.handle
    # Rounded rectangle: bulge = tan(90°/4) on alternating corner segments.
    b = math.tan(math.radians(90) / 4)
    rounded = msp.add_lwpolyline(
        [(32, 0, 0, 0, 0), (40, 0, 0, 0, b), (42, 2, 0, 0, 0), (42, 8, 0, 0, b),
         (40, 10, 0, 0, 0), (32, 10, 0, 0, b), (30, 8, 0, 0, 0), (30, 2, 0, 0, b)],
        format="xyseb", close=True).dxf.handle
    src = _save(doc, "expl_in.dxf")
    out = os.path.join(TMP, "expl_out.dxf")

    res = sc.op_explode_to_lines({"input": src, "output": out,
                                  "handles": [rect, rounded]})
    assert res["status"] == "ok", res
    new = res["data"]["new_handles"]
    assert len(new[rect]) == 4
    assert len(new[rounded]) == 8
    ents = _entity_map(out)
    assert sorted(ents[h]["type"] for h in new[rect]) == ["LINE"] * 4
    assert sorted(ents[h]["type"] for h in new[rounded]) == ["ARC"] * 4 + ["LINE"] * 4
    assert rect not in ents and rounded not in ents

    # Arc endpoints must land exactly on their neighbouring line endpoints
    # (bulge conversion correctness) — inference will find the coincidences.
    props = _infer(out, new[rounded])
    co = [p for p in props if p["kind"] == "coincident"]
    assert len(co) == 8, f"expected 8 stitched corners, got {len(co)}"

    # Plain rectangle: explode + infer + ground → solves to dof 0 leaves
    # geometry unchanged (already consistent).
    props = _infer(out, new[rect])
    kinds = sorted(p["kind"] for p in props)
    assert kinds.count("coincident") == 4 and kinds.count("horizontal") == 2 \
        and kinds.count("vertical") == 2, kinds
    cons = props + [{"id": "g", "kind": "ground",
                     "points": [{"handle": new[rect][0], "role": "start"}]},
                    {"id": "d1", "kind": "distance", "value": 20.0,
                     "points": [{"handle": new[rect][0], "role": "start"},
                                {"handle": new[rect][0], "role": "end"}]},
                    {"id": "d2", "kind": "distance", "value": 10.0,
                     "points": [{"handle": new[rect][1], "role": "start"},
                                {"handle": new[rect][1], "role": "end"}]}]
    out2 = os.path.join(TMP, "expl_solved.dxf")
    res = _solve_inproc(out, out2, cons)
    d = res["data"]["diagnostics"]
    assert d["converged"], d
    # DOF counts the whole sketch: the rect is pinned, the 8 unconstrained
    # rounded-rect pieces stay free (4 lines x 4 + 4 arcs x 5 = 36).
    assert d["dof"] == 36, d
    assert sorted(d["fully_constrained"]) == sorted(new[rect]), d
    print("  explode-to-lines (bulge arcs) + infer -> fully constrained rect ok")


def run_all():
    tests = [
        test_perpendicular_corner,
        test_parallel_equal_vertical,
        test_tangent_line_circle_both_branches,
        test_tangent_circle_circle,
        test_arc_endpoint_coincident_and_wrap,
        test_angle_and_point_line_distance,
        test_dof_readout,
        test_rectangle_fully_constrained,
        test_conflict_and_redundancy,
        test_zero_constraints_noop,
        test_session_lifecycle,
        test_session_nan_and_divergence_safety,
        test_iteration_cap,
        test_invalid_constraints_are_structured_errors,
        test_cli_roundtrip,
        test_inference_chain_and_hv,
        test_inference_unionfind,
        test_inference_tangent,
        test_explode_to_lines_and_constrain,
        test_drag_benchmark,
    ]
    print(f"Running {len(tests)} constraint-solver tests (tmp: {TMP})")
    for t in tests:
        print(f"{t.__name__}:")
        t()
    print("All constraint tests passed.")


if __name__ == "__main__":
    run_all()
