"""Tests for op_edge_treatment (Phase 2 — pattern-changing edge finishes).

    PYTHONPATH=. python pathstitch_core/test_edge_ops.py
"""
import tempfile
import ezdxf

from pathstitch_core.dxf_ops import op_edge_treatment, op_insert_net


def _tmp():
    f = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); f.close(); return f.name


def _blank():
    p = _tmp(); ezdxf.new(dxfversion="R2010").saveas(p); return p


def _by_layer(path, dxftype, layer):
    d = ezdxf.readfile(path)
    return [e for e in d.modelspace() if e.dxftype() == dxftype and e.dxf.layer == layer]


def _bbox(poly):
    pts = [(p[0], p[1]) for p in poly]
    xs = [x for x, _ in pts]; ys = [y for _, y in pts]
    return max(xs) - min(xs), max(ys) - min(ys)


def test_turn_adds_hem_and_crease():
    out = _tmp()
    res = op_edge_treatment({"input": _blank(), "output": out,
                             "edge": [[0, 0], [100, 0]], "mode": "turn",
                             "allowance": 8.0, "outward": [0, 1]})
    assert res["status"] == "ok", res
    hems = _by_layer(out, "LWPOLYLINE", "EDGE_TURN")
    assert len(hems) == 1 and hems[0].closed, "expected one closed hem flange"
    w, h = _bbox(hems[0])
    assert abs(w - 100.0) < 1e-6 and abs(h - 8.0) < 1e-6, f"hem bbox {w:.2f}x{h:.2f}"
    creases = _by_layer(out, "LINE", "FOLD")
    assert len(creases) == 1, "turned edge should add exactly one fold crease"
    assert abs(res["data"]["edgeLength"] - 100.0) < 1e-9
    print("turn: 100x8 hem flange + 1 FOLD crease ✓")


def test_bind_emits_strip_and_two_creases():
    out = _tmp()
    res = op_edge_treatment({"input": _blank(), "output": out,
                             "edge": [[0, 0], [100, 0]], "mode": "bind",
                             "allowance": 8.0, "thickness": 2.0, "outward": [0, 1]})
    assert res["status"] == "ok", res
    strips = _by_layer(out, "LWPOLYLINE", "BINDING")
    assert len(strips) == 1 and strips[0].closed, "expected one closed binding strip"
    w, h = _bbox(strips[0])
    # width = 2*allowance + thickness = 18
    assert abs(w - 100.0) < 1e-6 and abs(h - 18.0) < 1e-6, f"strip bbox {w:.2f}x{h:.2f}"
    creases = _by_layer(out, "LINE", "FOLD")
    assert len(creases) == 2, "binding strip should add two wrap creases"
    print("bind: 100x18 strip + 2 FOLD wrap creases ✓")


def test_unknown_mode_errors():
    res = op_edge_treatment({"input": _blank(), "output": _tmp(),
                             "edge": [[0, 0], [10, 0]], "mode": "scallop"})
    assert res["status"] == "error" and "scallop" in res["message"], res
    print("unknown treatment rejected ✓")


# --- parametric assembly templates: fold-up nets ---

def test_insert_net_sleeve():
    """A one-fold sleeve net → one closed panel + one FOLD crease."""
    out = _tmp()
    res = op_insert_net({"input": _blank(), "output": out,
                         "panels": [[[0, 0], [140, 0], [140, 100], [0, 100]]],
                         "folds": [[[70, 0], [70, 100]]]})
    assert res["status"] == "ok", res
    assert res["data"]["panels"] == 1 and res["data"]["folds"] == 1
    d = ezdxf.readfile(out)
    panels = [e for e in d.modelspace() if e.dxftype() == "LWPOLYLINE" and e.dxf.layer == "ORIGINAL"]
    creases = [e for e in d.modelspace() if e.dxftype() == "LINE" and e.dxf.layer == "FOLD"]
    assert len(panels) == 1 and panels[0].closed, "expected one closed panel"
    assert len(creases) == 1, "expected one fold crease"
    print("net sleeve: 1 closed panel + 1 FOLD crease ✓")


def test_insert_net_tray_four_folds():
    """A tray cross-net carries four fold creases (the four wall bends)."""
    out = _tmp()
    res = op_insert_net({"input": _blank(), "output": out,
                         "panels": [[[0, 0], [10, 0], [10, 10], [0, 10]]],  # placeholder cross
                         "folds": [[[2, 2], [8, 2]], [[2, 8], [8, 8]],
                                   [[2, 2], [2, 8]], [[8, 2], [8, 8]]]})
    assert res["status"] == "ok", res
    creases = [e for e in ezdxf.readfile(out).modelspace()
               if e.dxftype() == "LINE" and e.dxf.layer == "FOLD"]
    assert len(creases) == 4, f"expected 4 wall folds, got {len(creases)}"
    print("net tray: 4 FOLD creases ✓")


def test_insert_net_requires_panel():
    res = op_insert_net({"input": _blank(), "output": _tmp(), "panels": [], "folds": []})
    assert res["status"] == "error", res
    print("empty net rejected ✓")


if __name__ == "__main__":
    test_turn_adds_hem_and_crease()
    test_bind_emits_strip_and_two_creases()
    test_unknown_mode_errors()
    test_insert_net_sleeve()
    test_insert_net_tray_four_folds()
    test_insert_net_requires_panel()
    print("\nALL EDGE + NET OPS TESTS PASSED")
