"""Performance + correctness tests for op_add_holes (MAS-152). Run from repo
root with the pathstitch conda env:  python pathstitch_core/test_holes.py

Targets the dense-curve hang: an imported curve with thousands of points used
to make per-step interpolate/distance/project O(N) and time out the worker, and
an invalid self-touching polygon scattered holes 'all over the place'."""
import math
import time
import tempfile
import ezdxf
from shapely.geometry import LinearRing

from pathstitch_core.dxf_ops import op_add_holes


def _save(doc):
    f = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); f.close()
    doc.saveas(f.name)
    return f.name


def _holes(path):
    doc = ezdxf.readfile(path)
    return [(e.dxf.center.x, e.dxf.center.y, e.dxf.radius)
            for e in doc.modelspace()
            if e.dxftype() == "CIRCLE" and e.dxf.layer == "SEWING_HOLES"]


def run():
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()

    # --- Simple square: holes land in the offset band, not scattered ---
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    sq = m.add_lwpolyline([(0, 0), (100, 0), (100, 100), (0, 100)], dxfattribs={"closed": True})
    ring = LinearRing([(0, 0), (100, 0), (100, 100), (0, 100), (0, 0)])
    path = _save(doc)
    res = op_add_holes({"input": path, "output": out.name, "handles": [sq.dxf.handle],
                        "offset_distance": 3.0, "hole_diameter": 1.0, "hole_spacing": 5.0,
                        "side": "left"})
    assert res["status"] == "ok", res
    holes = _holes(out.name)
    assert len(holes) > 0, "square produced no holes"
    # Every hole sits ~offset from the contour; nothing flung far away.
    from shapely.geometry import Point
    # Genuine scatter flings holes far OUTSIDE the offset band; holes that sit
    # closer than the offset are just normal corner placement.
    worst = max(ring.distance(Point(h[0], h[1])) for h in holes)
    assert worst < 3.0 + 1.5, f"some holes are flung outside the offset band (worst dist {worst:.2f} mm)"
    print(f"Square OK: {len(holes)} holes, worst offset deviation {worst:.2f} mm")

    # --- Dense curve (5000-point circle): must finish fast and stay in-band ---
    R = 60.0
    n = 5000
    pts = [(R * math.cos(2 * math.pi * i / n), R * math.sin(2 * math.pi * i / n)) for i in range(n)]
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    curve = m.add_lwpolyline(pts, dxfattribs={"closed": True})
    circ_ring = LinearRing(pts + [pts[0]])
    path = _save(doc)
    t0 = time.time()
    res = op_add_holes({"input": path, "output": out.name, "handles": [curve.dxf.handle],
                        "offset_distance": 3.0, "hole_diameter": 1.0, "hole_spacing": 5.0,
                        "side": "left"})
    dt = time.time() - t0
    assert res["status"] == "ok", res
    holes = _holes(out.name)
    assert len(holes) > 0, "dense curve produced no holes"
    # On a circle, inner-side holes form a ring at radius R-offset; check radii.
    from shapely.geometry import Point
    worst = max(circ_ring.distance(Point(h[0], h[1])) for h in holes)
    assert worst < 3.0 + 1.5, f"dense-curve holes scattered (worst dist {worst:.2f} mm)"
    # Inner-side ring: every hole near radius R-offset, none at a random radius.
    radii = [math.hypot(h[0], h[1]) for h in holes]
    assert max(radii) < R and min(radii) > R - 3.0 - 2.0, f"dense-curve holes off-ring: r in [{min(radii):.1f},{max(radii):.1f}]"
    assert dt < 30.0, f"dense curve too slow: {dt:.1f}s (regression)"
    print(f"Dense 5000-pt curve OK: {len(holes)} holes in {dt:.2f}s, worst dev {worst:.2f} mm")

    print("\nALL HOLES TESTS PASSED")


if __name__ == "__main__":
    run()
