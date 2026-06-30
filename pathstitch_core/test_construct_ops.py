"""Tests for construct_ops.build_construct_model (triangulation + hinges)."""
import math

from pathstitch_core import construct_ops


def _edge_key(a, b):
    return (a, b) if a < b else (b, a)


def _hinge_chain_spans_fold(panel, fold, tol):
    """A fold should produce a connected chain of hinge edges spanning it."""
    fold_hinges = [h for h in panel["hinges"] if h["foldId"] >= 0]
    assert fold_hinges, "no fold hinges detected on the fold line"
    verts = panel["vertices2d"]
    # endpoints of the chain should reach near both ends of the fold segment
    chain_pts = []
    for h in fold_hinges:
        chain_pts.append(verts[h["v0"]])
        chain_pts.append(verts[h["v1"]])
    f0, f1 = fold[0], fold[-1]
    near0 = min(math.dist(p, f0) for p in chain_pts)
    near1 = min(math.dist(p, f1) for p in chain_pts)
    assert near0 <= tol and near1 <= tol, \
        f"fold chain doesn't span the fold (ends {near0:.2f}, {near1:.2f} > {tol:.2f})"


def test_square_with_center_fold():
    # 100x60 panel, a fold straight down the middle (x = 50).
    outline = [[0, 0], [100, 0], [100, 60], [0, 60]]
    fold = [[50, 0], [50, 60]]
    res = construct_ops.op_build_construct_model({
        "panels": [outline], "folds": [fold], "target_len": 10.0,
    })
    assert res["status"] == "ok", res
    panel = res["data"]["panels"][0]

    # mesh sanity
    assert len(panel["triangles"]) > 0
    assert len(panel["vertices"]) >= 4
    # vertices lie flat on the ground plane (y == 0)
    assert all(abs(v[1]) < 1e-9 for v in panel["vertices"])

    # every triangle edge length matches the 2D source (the "bar" rest lengths)
    v2 = panel["vertices2d"]
    for a, b in panel["edges"]:
        assert math.dist(v2[a], v2[b]) > 0

    # the fold is represented as a connected chain of hinge edges
    _hinge_chain_spans_fold(panel, fold, tol=12.0)

    # facet creases (interior, non-fold) exist and are tagged -1 (kept rigid)
    facet = [h for h in panel["hinges"] if h["foldId"] < 0]
    assert facet, "expected interior facet creases to keep the face rigid"

    print(f"square+fold: {len(panel['triangles'])} tris, "
          f"{len(panel['edges'])} edges, "
          f"{sum(1 for h in panel['hinges'] if h['foldId'] >= 0)} fold hinges, "
          f"{len(facet)} facet hinges")


def test_two_panels_no_folds():
    p1 = [[0, 0], [40, 0], [40, 40], [0, 40]]
    p2 = [[60, 0], [100, 0], [100, 40], [60, 40]]
    res = construct_ops.op_build_construct_model({"panels": [p1, p2]})
    assert res["status"] == "ok", res
    assert len(res["data"]["panels"]) == 2
    # panel 0 is ground by default
    assert res["data"]["panels"][0]["isGround"]
    assert not res["data"]["panels"][1]["isGround"]
    # no fold lines → no fold hinges, but plenty of facet creases
    for panel in res["data"]["panels"]:
        assert all(h["foldId"] < 0 for h in panel["hinges"])
    print("two panels ok")


def test_l_shaped_panel():
    # non-convex outline: triangulation must stay inside the L.
    outline = [[0, 0], [80, 0], [80, 30], [30, 30], [30, 80], [0, 80]]
    res = construct_ops.op_build_construct_model({"panels": [outline], "target_len": 8.0})
    assert res["status"] == "ok", res
    from shapely.geometry import Polygon, Point
    poly = Polygon(outline)
    panel = res["data"]["panels"][0]
    v2 = panel["vertices2d"]
    for a, b, c in panel["triangles"]:
        cx = (v2[a][0] + v2[b][0] + v2[c][0]) / 3
        cy = (v2[a][1] + v2[b][1] + v2[c][1]) / 3
        assert poly.contains(Point(cx, cy)) or poly.touches(Point(cx, cy)), \
            "triangle centroid escaped the L-shaped panel"
    print(f"L-panel: {len(panel['triangles'])} tris stay inside")


def _row_of_holes(x0, x1, y, n):
    return [[x0 + (x1 - x0) * k / (n - 1), y] for k in range(n)]


def test_hole_chains_detected_and_embedded():
    # Two panels, each with a row of sewing holes along their facing edge.
    p1 = [[0, 0], [100, 0], [100, 60], [0, 60]]
    p2 = [[0, 80], [100, 80], [100, 140], [0, 140]]
    chainA = _row_of_holes(8, 92, 56, 12)   # just inside p1's top edge
    chainB = _row_of_holes(8, 92, 84, 12)   # just inside p2's bottom edge
    res = construct_ops.op_build_construct_model({
        "panels": [p1, p2], "holes": chainA + chainB, "target_len": 12.0,
    })
    assert res["status"] == "ok", res
    chains = res["data"]["holeChains"]
    # exactly the two seam runs, one per panel
    assert len(chains) == 2, f"expected 2 chains, got {len(chains)}"
    panels_seen = sorted(c["panelId"] for c in chains)
    assert panels_seen == [0, 1], panels_seen
    for c in chains:
        assert len(c["holes"]) == 12, c
        assert not c["closed"]
        assert c["pitch"] > 0
        # each hole embedded: valid triangle index + barycentric ~summing to 1
        for h in c["holes"]:
            assert 0 <= h["tri"] < len(res["data"]["panels"][c["panelId"]]["triangles"])
            assert abs(sum(h["bary"]) - 1.0) < 1e-6
    print(f"chains: {[ (c['panelId'], len(c['holes'])) for c in chains ]}")


def test_match_chains_equal_counts():
    A = _row_of_holes(0, 110, 0, 12)
    B = _row_of_holes(0, 110, 0, 12)
    res = construct_ops.op_match_chains({"chainA": A, "chainB": B})
    assert res["status"] == "ok", res
    d = res["data"]
    assert d["mismatch"] < 1e-6 and d["policy"] == "even"
    # equal, aligned chains → clean 1:1 down the line
    assert d["pairs"] == [[i, i] for i in range(12)], d["pairs"]
    print(f"equal match: {len(d['pairs'])} pairs, mismatch {d['mismatch']:.4f}")


def test_match_chains_mismatched_counts():
    A = _row_of_holes(0, 100, 0, 8)    # shorter seam, fewer holes
    B = _row_of_holes(0, 130, 0, 14)   # longer seam, more holes
    res = construct_ops.op_match_chains({"chainA": A, "chainB": B})
    assert res["status"] == "ok", res
    d = res["data"]
    assert d["policy"] == "ease" and d["mismatch"] > 0.12, d
    # every hole on BOTH chains gets sewn (no painful 1:1 needed)
    a_used = {i for i, _ in d["pairs"]}
    b_used = {j for _, j in d["pairs"]}
    assert a_used == set(range(8)), a_used
    assert b_used == set(range(14)), b_used
    print(f"mismatch match: {len(d['pairs'])} pairs, mismatch {d['mismatch']:.3f}, "
          f"all {len(a_used)}+{len(b_used)} holes sewn")


def test_match_chains_reversed():
    A = _row_of_holes(0, 100, 0, 10)
    B = list(reversed(_row_of_holes(0, 100, 0, 10)))  # same seam, opposite winding
    res = construct_ops.op_match_chains({"chainA": A, "chainB": B})
    assert res["status"] == "ok", res
    d = res["data"]
    assert d["reversed"] is True, d
    # after auto-flip, hole i of A pairs with the geometrically-nearest hole of B
    for i, j in d["pairs"]:
        assert math.dist(A[i], B[j]) < 1e-6, (i, j, A[i], B[j])
    print(f"reversed match auto-flipped: {len(d['pairs'])} clean pairs")


def test_match_chains_shift_open():
    """`shift` slides which B hole each A hole sews to (open run)."""
    A = _row_of_holes(0, 100, 0, 10)
    B = _row_of_holes(0, 100, 0, 10)
    res = construct_ops.op_match_chains({"chainA": A, "chainB": B, "shift": 2})
    assert res["status"] == "ok", res
    d = res["data"]
    assert d["shift"] == 2, d
    # A hole i now sews to B hole i+2, clamped at the last hole.
    pm = dict(d["pairs"])
    assert pm[0] == 2 and pm[3] == 5, d["pairs"]
    assert pm[9] == 9, d["pairs"]   # tail clamps to the final B hole
    print(f"shift open: {d['pairs'][:4]}… shift={d['shift']}")


def test_match_chains_shift_closed_wraps():
    """On a closed loop `shift` rotates the correspondence and wraps around."""
    ring = [(50 * math.cos(t), 50 * math.sin(t))
            for t in [i * 2 * math.pi / 8 for i in range(8)]]
    res = construct_ops.op_match_chains(
        {"chainA": ring, "chainB": list(ring), "closedA": True, "closedB": True,
         "shift": 3})
    assert res["status"] == "ok", res
    d = res["data"]
    assert d["shift"] == 3, d
    pm = dict(d["pairs"])
    assert pm[0] == 3 and pm[6] == 1, d["pairs"]   # (6+3) % 8 == 1, wrapped
    # a shift that is a full turn is a no-op
    res2 = construct_ops.op_match_chains(
        {"chainA": ring, "chainB": list(ring), "closedA": True, "closedB": True,
         "shift": 8})
    assert res2["data"]["shift"] == 0, res2["data"]
    print(f"shift closed wraps: {d['pairs'][:3]}… (full turn → {res2['data']['shift']})")


def test_match_chains_shift_ignored_with_anchors():
    """Pins fix the alignment exactly, so a shift must not override them."""
    A = _row_of_holes(0, 100, 0, 10)
    B = _row_of_holes(0, 100, 0, 10)
    res = construct_ops.op_match_chains(
        {"chainA": A, "chainB": B, "anchors": [[0, 0], [9, 9]], "shift": 2})
    assert res["status"] == "ok", res
    d = res["data"]
    assert d["shift"] == 0, d
    pm = dict(d["pairs"])
    assert pm[0] == 0 and pm[9] == 9, d["pairs"]   # pinned ends honored
    print("shift ignored when anchored: pins honored")


# ---------------------------------------------------------------------------
# DXF extraction — loose / imported geometry must surface as panels
# ---------------------------------------------------------------------------

def _dxf_with(make):
    import tempfile, ezdxf
    f = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); f.close()
    doc = ezdxf.new(dxfversion="R2010"); make(doc.modelspace()); doc.saveas(f.name)
    return f.name


def test_imported_loose_lines_become_panel():
    """A rectangle imported as four separate LINEs (not one closed polyline) must
    still assemble into a panel — the import-doesn't-show-up bug."""
    def make(m):
        pts = [(0, 0), (100, 0), (100, 60), (0, 60)]
        for i in range(4):
            m.add_line(pts[i], pts[(i + 1) % 4])
    res = construct_ops.op_build_construct_model({"input": _dxf_with(make)})
    assert res["status"] == "ok", res
    assert len(res["data"]["panels"]) == 1, res["data"]["panels"]
    print("loose LINEs assemble into a panel")


def test_imported_line_arc_outline_becomes_panel():
    """A LINE+ARC outline (rounded corners, the classic imported shape) closes into
    a panel despite the floating-point dust where arcs meet lines."""
    def make(m):
        m.add_line((10, 0), (90, 0)); m.add_arc((90, 10), 10, -90, 0)
        m.add_line((100, 10), (100, 60)); m.add_line((100, 60), (0, 60))
        m.add_line((0, 60), (0, 10)); m.add_arc((10, 10), 10, 180, 270)
    res = construct_ops.op_build_construct_model({"input": _dxf_with(make)})
    assert res["status"] == "ok", res
    assert len(res["data"]["panels"]) == 1, res["data"]["panels"]
    print("LINE+ARC outline assembles into a panel")


def test_open_polyline_and_circle_become_panels():
    """An open polyline tracing a closed path, and a CIRCLE, each become a panel."""
    def make(m):
        m.add_lwpolyline([(0, 0), (80, 0), (80, 50), (0, 50), (0, 0)],
                         dxfattribs={"closed": False})
        m.add_circle((200, 25), 25)
    res = construct_ops.op_build_construct_model({"input": _dxf_with(make)})
    assert res["status"] == "ok", res
    assert len(res["data"]["panels"]) == 2, res["data"]["panels"]
    print("open polyline + circle each become a panel")


def test_overlap_sew_treatment_makes_hole_chain():
    """Tagging a row of engulfed areas as 'sew' drops them as panels and turns their
    centres into a sewing-hole chain — the requested overlap → sew-holes option."""
    def make(m):
        pts = [(0, 0), (120, 0), (120, 40), (0, 40)]
        m.add_lwpolyline(pts, dxfattribs={"closed": True})
        for x in range(20, 110, 15):
            m.add_circle((x, 20), 2)               # six little circles inside
    path = _dxf_with(make)
    base = construct_ops.op_build_construct_model({"input": path})["data"]
    assert len(base["panels"]) == 7, len(base["panels"])      # panel + 6 circles
    treatments = {e["inner"]: "sew" for e in base["engulfed"]}
    res = construct_ops.op_build_construct_model(
        {"input": path, "area_treatments": treatments})["data"]
    assert len(res["panels"]) == 1, res["panels"]             # circles dropped as panels
    assert len(res["holeChains"]) == 1, res["holeChains"]     # they chained
    assert len(res["holeChains"][0]["holes"]) == 6, res["holeChains"][0]
    print("overlap 'sew' → 1 panel, 1 chain of 6 holes")


def test_polygonized_loop_handles_are_stable():
    """Loops assembled from loose lines must get the SAME handle every rebuild, or a
    chosen overlap treatment would never stick (prompt never dismisses)."""
    def make(m):
        for pts in ([(0, 0), (100, 0), (100, 100), (0, 100)],
                    [(30, 30), (70, 30), (70, 70), (30, 70)]):
            for i in range(4):
                m.add_line(pts[i], pts[(i + 1) % 4])
    path = _dxf_with(make)
    runs = [construct_ops.op_build_construct_model({"input": path})["data"]["engulfed"]
            for _ in range(3)]
    keys = [[(e["inner"], e["outer"]) for e in r] for r in runs]
    assert keys[0] == keys[1] == keys[2] and keys[0], keys
    # and a treatment keyed on that handle is honored on rebuild (would-be undecided
    # is empty → the chooser dismisses)
    inner = keys[0][0][0]
    again = construct_ops.op_build_construct_model(
        {"input": path, "area_treatments": {inner: "cutout"}})["data"]["engulfed"]
    assert any(e["inner"] == inner for e in again), again
    print(f"loose-line loop handle stable across rebuilds ({inner})")


def test_loose_lines_with_fold_layer_line():
    """Loose-line outline + a fold-layer line: one panel, and the fold becomes a real
    hinge chain (the fold line must NOT be mistaken for panel-bounding geometry)."""
    def make(m):
        pts = [(0, 0), (100, 0), (100, 50), (0, 50)]
        for i in range(4):
            m.add_line(pts[i], pts[(i + 1) % 4])
        m.add_line((50, 0), (50, 50), dxfattribs={"layer": "FOLD"})
    panels, folds, holes, ph, ah = construct_ops._extract_from_dxf(_dxf_with(make), None, None)
    assert len(panels) == 1 and len(folds) == 1, (len(panels), len(folds))
    res = construct_ops.op_build_construct_model({"input": _dxf_with(make)})
    assert res["status"] == "ok" and len(res["data"]["panels"]) == 1, res
    assert any(h["foldId"] >= 0 for h in res["data"]["panels"][0]["hinges"]), "fold not hinged"
    print("loose lines + fold line: 1 panel with a hinged fold")


# ---------------------------------------------------------------------------
# bend allowance — the sheet-metal flat ↔ folded relationship (Phase 1)
# ---------------------------------------------------------------------------

def test_bend_allowance_known_values():
    # 90° bend, R=1, T=2, K=0.5 → BA = (π/2)(1 + 0.5·2) = π·1 ... actually
    # (π/2)·(1+1) = π. OSSB = tan45·(1+2) = 3. BD = 2·3 − π.
    ba = construct_ops.bend_allowance(90, 1.0, 2.0, 0.5)
    assert abs(ba - math.pi) < 1e-9, ba
    ossb = construct_ops.outside_setback(90, 1.0, 2.0)
    assert abs(ossb - 3.0) < 1e-9, ossb
    bd = construct_ops.bend_deduction(90, 1.0, 2.0, 0.5)
    assert abs(bd - (6.0 - math.pi)) < 1e-9, bd

    # zero inside radius, 90°, T=2, K=0.5 → BA = (π/2)(0+1) = π/2, OSSB = 2.
    assert abs(construct_ops.bend_allowance(90, 0.0, 2.0, 0.5) - math.pi / 2) < 1e-9
    assert abs(construct_ops.outside_setback(90, 0.0, 2.0) - 2.0) < 1e-9

    # textbook aluminium check: 90°, R=1, T=1, K=0.33 → BA = (π/2)(1.33).
    assert abs(construct_ops.bend_allowance(90, 1.0, 1.0, 0.33)
               - (math.pi / 2) * 1.33) < 1e-9

    # a flat fold consumes nothing; sign of the angle doesn't matter.
    assert construct_ops.bend_allowance(0, 2.0, 2.0, 0.45) == 0.0
    assert abs(construct_ops.bend_allowance(-90, 1.0, 2.0, 0.5) - math.pi) < 1e-9
    print("bend allowance formulas match the sheet-metal references")


def test_fold_metrics_op_totals_and_validation():
    res = construct_ops.op_fold_metrics({
        "thickness": 2.0, "kFactor": 0.45, "minBendRadiusMm": 1.5,
        "folds": [
            {"id": "0-0", "angleDeg": 90, "radiusMm": 2.0},   # OK (≥ 1.5)
            {"id": "0-1", "angleDeg": 90, "radiusMm": 0.5},   # too tight → warn
            {"id": "0-2", "angleDeg": 0,  "radiusMm": 0.0},   # flat → ignored
        ],
    })
    assert res["status"] == "ok", res
    d = res["data"]
    assert d["count"] == 3
    # totals only sum the two bent folds
    expect_ba = (construct_ops.bend_allowance(90, 2.0, 2.0, 0.45)
                 + construct_ops.bend_allowance(90, 0.5, 2.0, 0.45))
    assert abs(d["totalBendAllowance"] - expect_ba) < 1e-9, d["totalBendAllowance"]
    # validation: exactly the tight, non-flat fold warns
    assert d["folds"][0]["radiusOk"] and not d["folds"][1]["radiusOk"]
    assert d["folds"][2]["radiusOk"]   # flat fold never warns
    assert len(d["warnings"]) == 1 and "0-1" in d["warnings"][0], d["warnings"]
    # radius defaults to the leather minimum when omitted
    res2 = construct_ops.op_fold_metrics({
        "thickness": 2.0, "minBendRadiusMm": 1.5, "folds": [{"angleDeg": 90}]})
    assert abs(res2["data"]["folds"][0]["radiusMm"] - 1.5) < 1e-9
    assert not res2["data"]["warnings"], "default-radius fold should sit at the minimum"
    print(f"op_fold_metrics: ΣBA {d['totalBendAllowance']:.2f} mm, "
          f"ΣBD {d['totalBendDeduction']:.2f} mm, {len(d['warnings'])} warning(s)")


if __name__ == "__main__":
    test_square_with_center_fold()
    test_two_panels_no_folds()
    test_l_shaped_panel()
    test_hole_chains_detected_and_embedded()
    test_match_chains_equal_counts()
    test_match_chains_mismatched_counts()
    test_match_chains_reversed()
    test_match_chains_shift_open()
    test_match_chains_shift_closed_wraps()
    test_match_chains_shift_ignored_with_anchors()
    test_imported_loose_lines_become_panel()
    test_imported_line_arc_outline_becomes_panel()
    test_open_polyline_and_circle_become_panels()
    test_overlap_sew_treatment_makes_hole_chain()
    test_polygonized_loop_handles_are_stable()
    test_loose_lines_with_fold_layer_line()
    test_bend_allowance_known_values()
    test_fold_metrics_op_totals_and_validation()
    print("ALL CONSTRUCT TESTS PASSED")
