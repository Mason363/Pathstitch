"""Tests for manufacture_ops (Phase 3 — BOM, DFM, hide nesting).

    PYTHONPATH=. python pathstitch_core/test_manufacture_ops.py
"""
import math
import tempfile
import ezdxf

from pathstitch_core.manufacture_ops import op_bom, op_validate_dfm, op_nest


def _tmp():
    f = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); f.close(); return f.name


def _square(msp, x, y, s, layer="ORIGINAL"):
    msp.add_lwpolyline([(x, y), (x + s, y), (x + s, y + s), (x, y + s)],
                       dxfattribs={"layer": layer, "closed": True})


def _doc_one_panel_with_holes(n=11, side=100.0):
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    _square(m, 0, 0, side)
    for k in range(n):  # a row of holes 4 mm in from the bottom edge, 8 mm pitch
        m.add_circle(center=(8 + k * 8.0, 4.0), radius=0.5, dxfattribs={"layer": "SEWING_HOLES"})
    p = _tmp(); doc.saveas(p); return p


def test_bom_area_and_thread():
    path = _doc_one_panel_with_holes(n=11, side=100.0)
    res = op_bom({"input": path, "thread_waste": 1.4, "cost_per_dm2": 5.0})
    assert res["status"] == "ok", res
    d = res["data"]
    assert d["panelCount"] == 1
    assert abs(d["areaDm2"] - 1.0) < 1e-6, d["areaDm2"]          # 100×100 mm = 1 dm²
    assert abs(d["cutLengthMm"] - 400.0) < 1e-3, d["cutLengthMm"]
    assert d["holeCount"] == 11
    assert abs(d["pitchMm"] - 8.0) < 1e-6, d["pitchMm"]
    # thread ≈ holes × pitch × waste × 2 (saddle stitch)
    assert abs(d["threadLengthMm"] - 11 * 8.0 * 1.4 * 2.0) < 1e-6
    assert abs(d["estimatedCost"] - 5.0) < 1e-6                   # 1 dm² × $5
    print(f"BOM: 1 dm², cut 400 mm, {d['holeCount']} holes, "
          f"thread {d['threadLengthMm']:.0f} mm, ${d['estimatedCost']:.2f} ✓")


def test_dfm_hole_too_close_and_oversize():
    # hole 4 mm from edge → flagged at min 5; panel 100 mm doesn't fit 60 mm stock.
    path = _doc_one_panel_with_holes(n=3, side=100.0)
    res = op_validate_dfm({"input": path, "min_hole_edge": 5.0,
                           "stock_w": 60.0, "stock_h": 60.0})
    assert res["status"] == "ok", res
    w = " ".join(res["data"]["warnings"]).lower()
    assert "tear out" in w, res["data"]["warnings"]
    assert "stock" in w, res["data"]["warnings"]
    assert not res["data"]["ok"]
    print(f"DFM: {len(res['data']['warnings'])} warnings (edge + stock) ✓")


def test_dfm_clean_passes():
    # holes 4 mm from edge, min 3 → fine; big stock → fits.
    path = _doc_one_panel_with_holes(n=3, side=100.0)
    res = op_validate_dfm({"input": path, "min_hole_edge": 3.0,
                           "stock_w": 300.0, "stock_h": 300.0})
    assert res["status"] == "ok" and res["data"]["ok"], res["data"]
    print("DFM: clean design passes ✓")


def _doc_two_panels():
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    _square(m, 0, 0, 40)
    m.add_circle(center=(20, 20), radius=1.0, dxfattribs={"layer": "SEWING_HOLES"})
    _square(m, 1000, 1000, 40)   # far away, so nesting must actually move it
    m.add_circle(center=(1020, 1020), radius=1.0, dxfattribs={"layer": "SEWING_HOLES"})
    p = _tmp(); doc.saveas(p); return p


def test_nest_places_both_within_hide():
    path = _doc_two_panels()
    res = op_nest({"input": path, "hide_w": 200, "hide_h": 200, "gap": 4, "margin": 5})
    assert res["status"] == "ok", res
    d = res["data"]
    assert d["placed"] == 2 and d["unplaced"] == 0, d
    for p in d["placements"]:
        assert p["x"] >= 5 - 1e-6 and p["y"] >= 5 - 1e-6
        assert p["x"] + p["w"] <= 200 - 5 + 1e-6 and p["y"] + p["h"] <= 200 - 5 + 1e-6
    assert abs(d["yield"] - (40 * 40 * 2) / (200 * 200)) < 1e-6, d["yield"]
    print(f"nest: 2/2 placed, yield {d['yield']*100:.1f}% ✓")


def test_nest_avoids_defect():
    path = _doc_two_panels()
    defect = {"x": 25, "y": 25, "r": 30}   # sits over the natural first slot
    res = op_nest({"input": path, "hide_w": 200, "hide_h": 200, "gap": 4,
                   "margin": 5, "defects": [defect]})
    d = res["data"]
    assert d["placed"] == 2, d
    for p in d["placements"]:
        cx = min(max(defect["x"], p["x"]), p["x"] + p["w"])
        cy = min(max(defect["y"], p["y"]), p["y"] + p["h"])
        assert math.hypot(defect["x"] - cx, defect["y"] - cy) >= defect["r"], \
            f"placement {p} overlaps the defect"
    print("nest: routed both panels around the defect ✓")


def test_nest_apply_moves_panel_with_its_hole():
    path = _doc_two_panels()
    out = _tmp()
    res = op_nest({"input": path, "output": out, "apply": True,
                   "hide_w": 200, "hide_h": 200, "gap": 4, "margin": 5})
    assert res["status"] == "ok" and res["data"]["placed"] == 2
    d = ezdxf.readfile(out)
    m = d.modelspace()
    from pathstitch_core.manufacture_ops import _panel_polys, _entity_center
    from shapely.geometry import Point
    polys = [pg for _, pg in _panel_polys(m)]
    for pg in polys:
        minx, miny, maxx, maxy = pg.bounds
        assert minx >= 0 and miny >= 0 and maxx <= 200 and maxy <= 200, "panel left the hide"
    holes = [c for e in m if (e.dxf.layer or "").upper() == "SEWING_HOLES"
             for c in [_entity_center(e)] if c]
    for c in holes:                              # each hole still sits inside a panel
        assert any(pg.contains(Point(c)) for pg in polys), f"hole {c} left its panel"
    print("nest apply: panels + their holes moved together, inside the hide ✓")


if __name__ == "__main__":
    test_bom_area_and_thread()
    test_dfm_hole_too_close_and_oversize()
    test_dfm_clean_passes()
    test_nest_places_both_within_hide()
    test_nest_avoids_defect()
    test_nest_apply_moves_panel_with_its_hole()
    print("\nALL MANUFACTURE OPS TESTS PASSED")
