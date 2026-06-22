"""Tests for boolean path operations (MAS-144). Run from repo root with the
pathstitch conda env:  python pathstitch_core/test_boolean.py"""
import os
import tempfile
import ezdxf

from pathstitch_core.dxf_ops import op_boolean


def _square(msp, x0, y0, side, layer="0"):
    pts = [(x0, y0), (x0 + side, y0), (x0 + side, y0 + side), (x0, y0 + side)]
    e = msp.add_lwpolyline(pts, dxfattribs={"layer": layer, "closed": True})
    return e.dxf.handle


def _make_doc(builder):
    doc = ezdxf.new(dxfversion="R2010")
    msp = doc.modelspace()
    handles = builder(msp)
    f = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False)
    f.close()
    doc.saveas(f.name)
    return f.name, handles


def _area_of(path, handles):
    """Sum of polygon areas of the given (or all closed) handles in a saved dxf."""
    from shapely.geometry import Polygon
    doc = ezdxf.readfile(path)
    total = 0.0
    polys = 0
    for ent in doc.modelspace():
        if ent.dxftype() == "LWPOLYLINE" and (ent.closed or getattr(ent, "is_closed", False)):
            pts = [(p[0], p[1]) for p in ent.get_points()]
            total += Polygon(pts).area
            polys += 1
    return total, polys


def run():
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()

    # Two unit squares overlapping by half: [0,2]x[0,2] and [1,3]x[0,2]
    # Each area 4, overlap area 2.
    path, (a, b) = _make_doc(lambda m: (_square(m, 0, 0, 2), _square(m, 1, 0, 2)))

    # --- Union ---
    res = op_boolean({"input": path, "output": out.name, "handles": [a, b], "operation": "union"})
    assert res["status"] == "ok", res
    area, polys = _area_of(out.name, None)
    assert polys == 1, f"union should yield 1 polygon, got {polys}"
    assert abs(area - 6.0) < 1e-6, f"union area expected 6, got {area}"
    print("Union OK: area=%.3f polys=%d" % (area, polys))

    # --- Intersect ---
    res = op_boolean({"input": path, "output": out.name, "handles": [a, b], "operation": "intersect"})
    assert res["status"] == "ok", res
    area, polys = _area_of(out.name, None)
    assert polys == 1 and abs(area - 2.0) < 1e-6, f"intersect area expected 2, got {area} ({polys})"
    print("Intersect OK: area=%.3f" % area)

    # --- Subtract (base = larger; here equal, so largest-area pick is arbitrary but area is deterministic) ---
    res = op_boolean({"input": path, "output": out.name, "handles": [a, b], "operation": "subtract"})
    assert res["status"] == "ok", res
    area, polys = _area_of(out.name, None)
    assert abs(area - 2.0) < 1e-6, f"subtract area expected 2 (4-2), got {area}"
    print("Subtract OK: area=%.3f" % area)

    # --- Subtract producing a hole: big square minus a small inner square ---
    path2, (big, small) = _make_doc(lambda m: (_square(m, 0, 0, 10), _square(m, 3, 3, 4)))
    res = op_boolean({"input": path2, "output": out.name, "handles": [big, small],
                      "operation": "subtract", "base": big})
    assert res["status"] == "ok", res
    nh = res["data"]["new_handles"]
    assert len(nh) == 2, f"hole subtract should yield outer+inner = 2 loops, got {len(nh)}"
    # outer area (10x10=100) reported on the exterior loop; inner loop 4x4=16.
    area, polys = _area_of(out.name, None)
    assert polys == 2, f"expected 2 loops, got {polys}"
    assert abs(area - (100.0 + 16.0)) < 1e-6, f"loop areas expected 116, got {area}"
    print("Subtract-with-hole OK: %d loops, summed loop area=%.1f" % (polys, area))

    # --- Open path rejected ---
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    sq = _square(m, 0, 0, 2)
    openln = m.add_lwpolyline([(5, 5), (6, 6), (7, 5)], dxfattribs={"closed": False}).dxf.handle
    f = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); f.close(); doc.saveas(f.name)
    res = op_boolean({"input": f.name, "output": out.name, "handles": [sq, openln], "operation": "union"})
    assert res["status"] == "error" and "open" in res["message"].lower(), f"open path should be rejected: {res}"
    print("Open-path rejection OK")

    # --- Non-overlapping intersect is empty (error) ---
    path3, (s1, s2) = _make_doc(lambda m: (_square(m, 0, 0, 2), _square(m, 50, 50, 2)))
    res = op_boolean({"input": path3, "output": out.name, "handles": [s1, s2], "operation": "intersect"})
    assert res["status"] == "error" and "overlap" in res["message"].lower(), res
    print("Empty-intersect rejection OK")

    # --- <2 handles rejected ---
    res = op_boolean({"input": path3, "output": out.name, "handles": [s1], "operation": "union"})
    assert res["status"] == "error", res
    print("Single-handle rejection OK")

    # --- Circles union (curve flattening path) ---
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    c1 = m.add_circle(center=(0, 0), radius=5).dxf.handle
    c2 = m.add_circle(center=(4, 0), radius=5).dxf.handle
    f = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); f.close(); doc.saveas(f.name)
    res = op_boolean({"input": f.name, "output": out.name, "handles": [c1, c2], "operation": "union"})
    assert res["status"] == "ok", res
    _, polys = _area_of(out.name, None)
    assert polys == 1, f"two overlapping circles union -> 1 polygon, got {polys}"
    print("Circle union OK")

    print("\nALL BOOLEAN TESTS PASSED")


if __name__ == "__main__":
    run()
