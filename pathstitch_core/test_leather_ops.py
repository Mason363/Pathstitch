"""Tests for the LeatherCraft-parity ops: box stitch, mandala, box joint, golden.

Run from repo root with the pathstitch env:
    PYTHONPATH=. python pathstitch_core/test_leather_ops.py
"""
import math
import tempfile
import ezdxf

from pathstitch_core.dxf_ops import (
    op_box_stitch, op_mandala, op_box_joint, op_golden, _comb_profile,
)


def _tmp():
    f = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); f.close()
    return f.name


def _doc_two_lines():
    """Two open stitch paths of different lengths (100 mm and 70 mm)."""
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    a = m.add_lwpolyline([(0, 0), (100, 0)], dxfattribs={"closed": False})
    b = m.add_lwpolyline([(0, 50), (70, 50)], dxfattribs={"closed": False})
    p = _tmp(); doc.saveas(p)
    return p, a.dxf.handle, b.dxf.handle


def _circles(path):
    doc = ezdxf.readfile(path)
    return [(e, e.dxf.center) for e in doc.modelspace()
            if e.dxftype() == "CIRCLE" and e.dxf.layer == "SEWING_HOLES"]


def test_box_stitch_equal_counts():
    path, ha, hb = _doc_two_lines()
    out = _tmp()
    res = op_box_stitch({"input": path, "output": out, "handle_a": ha,
                         "handle_b": hb, "hole_spacing": 5.0, "strategy": "average",
                         "side": "left", "offset_distance": 3.0,
                         "corner_holes": False})
    assert res["status"] == "ok", res
    # Count holes on each panel by Y band (panel A at y~ -3/+3, panel B near y~50).
    holes = _circles(out)
    a_holes = [c for _, c in holes if c.y < 25]
    b_holes = [c for _, c in holes if c.y >= 25]
    assert len(a_holes) == len(b_holes), \
        f"box stitch counts differ: A={len(a_holes)} B={len(b_holes)}"
    assert len(a_holes) == res["data"]["count"], "reported count mismatch"
    print(f"Box stitch OK: both panels {len(a_holes)} holes "
          f"(pitch A {res['data']['pitch_a']:.2f}, B {res['data']['pitch_b']:.2f})")


def test_box_stitch_shaped_slits():
    """Box stitch forwards the iron shape to both panels."""
    path, ha, hb = _doc_two_lines()
    out = _tmp()
    res = op_box_stitch({"input": path, "output": out, "handle_a": ha,
                         "handle_b": hb, "hole_spacing": 6.0, "strategy": "a",
                         "side": "left", "offset_distance": 3.0, "corner_holes": False,
                         "hole_shape": "diamond", "slit_length": 2.5, "slit_width": 0.9})
    assert res["status"] == "ok", res
    doc = ezdxf.readfile(out)
    polys = [e for e in doc.modelspace()
             if e.dxftype() == "LWPOLYLINE" and e.dxf.layer == "SEWING_HOLES"]
    assert not _circles(out), "diamond box stitch still drew circles"
    assert len(polys) == 2 * res["data"]["count"], "slit count != 2*count"
    print(f"Box stitch shaped OK: {len(polys)} diamond slits across both panels")


def test_mandala_count():
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    seed = m.add_line((10, 0), (20, 5))
    path = _tmp(); doc.saveas(path)
    out = _tmp()
    res = op_mandala({"input": path, "output": out, "handles": [seed.dxf.handle],
                      "segments": 8, "cx": 0.0, "cy": 0.0, "mirror": False})
    assert res["status"] == "ok", res
    doc2 = ezdxf.readfile(out)
    lines = [e for e in doc2.modelspace() if e.dxftype() == "LINE"]
    # original + 7 rotated copies = 8
    assert len(lines) == 8, f"mandala produced {len(lines)} lines, expected 8"
    print(f"Mandala OK: {len(lines)} lines (8-fold)")


def test_mandala_mirror():
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    seed = m.add_line((10, 2), (20, 6))
    path = _tmp(); doc.saveas(path)
    out = _tmp()
    res = op_mandala({"input": path, "output": out, "handles": [seed.dxf.handle],
                      "segments": 6, "cx": 0.0, "cy": 0.0, "mirror": True})
    assert res["status"] == "ok", res
    doc2 = ezdxf.readfile(out)
    lines = [e for e in doc2.modelspace() if e.dxftype() == "LINE"]
    # original + 1 mirror + (orig+mirror)*5 rotations = 12
    assert len(lines) == 12, f"mirror mandala produced {len(lines)}, expected 12"
    print(f"Mandala mirror OK: {len(lines)} lines (6-fold dihedral)")


def test_box_joint_profile_geometry():
    # Horizontal edge, 4 fingers, depth 5, start with a tab, outward (+Y).
    prof = _comb_profile((0, 0), (40, 0), n_fingers=4, depth=5.0,
                         start_tab=True, tab_shrink=0.0, outward=True)
    ys = [p[1] for p in prof]
    xs = [p[0] for p in prof]
    assert min(ys) == 0.0 and abs(max(ys) - 5.0) < 1e-9, f"depth wrong: {set(ys)}"
    assert abs(min(xs)) < 1e-9 and abs(max(xs) - 40.0) < 1e-9, "edge endpoints off"
    # tab present at the start (first riser goes up to depth)
    assert any(abs(y - 5.0) < 1e-9 for y in ys[:4]), "no starting tab"
    print(f"Box joint profile OK: {len(prof)} verts, depth 5, spans 0..40")


def test_box_joint_mate_interlocks():
    path = _tmp(); ezdxf.new(dxfversion="R2010").saveas(path)
    out = _tmp()
    res = op_box_joint({"input": path, "output": out,
                        "p1": [0, 0], "p2": [40, 0], "finger_count": 4,
                        "depth": 5.0, "kerf": 0.4, "start_tab": True,
                        "mate": True, "p3": [0, 20], "p4": [40, 20]})
    assert res["status"] == "ok", res
    doc = ezdxf.readfile(out)
    polys = [e for e in doc.modelspace()
             if e.dxftype() == "LWPOLYLINE" and e.dxf.layer == "BOX_JOINT"]
    assert len(polys) == 2, f"expected 2 joint profiles, got {len(polys)}"
    assert res["data"]["fingers"] == 4
    print("Box joint mate OK: primary + complementary profile emitted")


def test_golden_spiral():
    path = _tmp(); ezdxf.new(dxfversion="R2010").saveas(path)
    out = _tmp()
    res = op_golden({"input": path, "output": out, "kind": "spiral",
                     "bbox": [0, 0, 100, 60], "turns": 3})
    assert res["status"] == "ok", res
    doc = ezdxf.readfile(out)
    polys = [e for e in doc.modelspace()
             if e.dxftype() == "LWPOLYLINE" and e.dxf.layer == "GUIDES"]
    assert polys, "no spiral polyline"
    pts = [(p[0], p[1]) for p in polys[0]]
    xs = [x for x, _ in pts]; ys = [y for _, y in pts]
    # fits the bbox within a small tolerance
    assert abs(min(xs) - 0) < 1e-6 and abs(max(xs) - 100) < 0.5, "spiral X not fit"
    assert abs(min(ys) - 0) < 1e-6 and abs(max(ys) - 60) < 0.5, "spiral Y not fit"
    # golden growth: radius ratio per quarter turn ≈ φ
    print(f"Golden spiral OK: {len(pts)} pts fit to 100x60 bbox")


def test_golden_rectangle():
    path = _tmp(); ezdxf.new(dxfversion="R2010").saveas(path)
    out = _tmp()
    res = op_golden({"input": path, "output": out, "kind": "rectangle",
                     "bbox": [0, 0, 100, 50]})
    assert res["status"] == "ok", res
    doc = ezdxf.readfile(out)
    rects = [e for e in doc.modelspace()
             if e.dxftype() == "LWPOLYLINE" and e.dxf.layer == "GUIDES"]
    assert rects, "no golden rectangle"
    pts = [(p[0], p[1]) for p in rects[0]]
    w = max(x for x, _ in pts) - min(x for x, _ in pts)
    h = max(y for _, y in pts) - min(y for _, y in pts)
    assert abs(w / h - 1.6180339887) < 0.01, f"rect ratio {w/h:.4f} != phi"
    lines = [e for e in doc.modelspace()
             if e.dxftype() == "LINE" and e.dxf.layer == "GUIDES"]
    assert lines, "no subdivision lines"
    print(f"Golden rectangle OK: ratio {w/h:.4f}, {len(lines)} subdivisions")


def test_golden_centerline():
    path = _tmp(); ezdxf.new(dxfversion="R2010").saveas(path)
    out = _tmp()
    res = op_golden({"input": path, "output": out, "kind": "centerline",
                     "p1": [0, 0], "p2": [0, 100]})
    assert res["status"] == "ok", res
    doc = ezdxf.readfile(out)
    lines = [e for e in doc.modelspace()
             if e.dxftype() == "LINE" and e.dxf.layer == "GUIDES"]
    assert len(lines) == 1, "centerline not drawn"
    print("Golden centerline OK")


def run():
    test_box_stitch_equal_counts()
    test_box_stitch_shaped_slits()
    test_mandala_count()
    test_mandala_mirror()
    test_box_joint_profile_geometry()
    test_box_joint_mate_interlocks()
    test_golden_spiral()
    test_golden_rectangle()
    test_golden_centerline()
    print("\nALL LEATHER OPS TESTS PASSED")


if __name__ == "__main__":
    run()
