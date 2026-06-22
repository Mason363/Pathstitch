"""Tests for the fill primitive + stroke<->fill conversion + SVG fill import
(MAS-146). Run from repo root with the pathstitch conda env:
    python pathstitch_core/test_fill.py"""
import os
import tempfile
import ezdxf

from pathstitch_core.dxf_ops import (
    op_convert_to_fill, op_convert_to_stroke, op_list_entities, op_import_svg,
)


def _tmp(suffix=".dxf"):
    f = tempfile.NamedTemporaryFile(suffix=suffix, delete=False); f.close()
    return f.name


def _types(path):
    doc = ezdxf.readfile(path)
    from collections import Counter
    return Counter(e.dxftype() for e in doc.modelspace())


def run():
    out = _tmp()

    # --- Stroke -> Fill: closed square LWPOLYLINE becomes a HATCH ---
    doc = ezdxf.new("R2010"); m = doc.modelspace()
    sq = m.add_lwpolyline([(0, 0), (10, 0), (10, 10), (0, 10)], dxfattribs={"closed": True})
    src = _tmp(); doc.saveas(src)
    res = op_convert_to_fill({"input": src, "output": out, "handles": [sq.dxf.handle]})
    assert res["status"] == "ok", res
    t = _types(out)
    assert t.get("HATCH") == 1 and t.get("LWPOLYLINE", 0) == 0, f"expected 1 HATCH, 0 polyline: {t}"
    print("Stroke->Fill OK:", dict(t))

    # --- The HATCH survives a save/load round-trip and is surfaced by list ---
    res = op_list_entities({"input": out})
    ents = res["data"]["entities"]
    hatches = [e for e in ents if e["type"] == "HATCH"]
    assert len(hatches) == 1, f"list_entities should surface the HATCH: {[e['type'] for e in ents]}"
    h = hatches[0]
    assert h.get("filled") is True and h.get("closed") is True
    assert len(h.get("vertices", [])) >= 4, "HATCH must expose boundary vertices for rendering"
    print("Fill round-trip + list OK: vertices=%d" % len(h["vertices"]))

    # --- Fill -> Stroke: HATCH back to a closed LWPOLYLINE ---
    hatch_handle = hatches[0]["handle"]
    out2 = _tmp()
    res = op_convert_to_stroke({"input": out, "output": out2, "handles": [hatch_handle]})
    assert res["status"] == "ok", res
    t = _types(out2)
    assert t.get("LWPOLYLINE") == 1 and t.get("HATCH", 0) == 0, f"expected 1 polyline, 0 hatch: {t}"
    # Area preserved (10x10 = 100).
    from shapely.geometry import Polygon
    doc2 = ezdxf.readfile(out2)
    poly = [e for e in doc2.modelspace() if e.dxftype() == "LWPOLYLINE"][0]
    area = Polygon([(p[0], p[1]) for p in poly.get_points()]).area
    assert abs(area - 100.0) < 1e-6, f"area should round-trip to 100, got {area}"
    print("Fill->Stroke OK: area=%.1f" % area)

    # --- Open path is rejected by convert_to_fill ---
    doc = ezdxf.new("R2010"); m = doc.modelspace()
    op = m.add_lwpolyline([(0, 0), (5, 0), (5, 5)], dxfattribs={"closed": False})
    src = _tmp(); doc.saveas(src)
    res = op_convert_to_fill({"input": src, "output": out, "handles": [op.dxf.handle]})
    assert res["status"] == "error" and "closed" in res["message"].lower(), res
    print("Open-path fill rejection OK")

    # --- Fill with a hole round-trips to outer + inner loops ---
    doc = ezdxf.new("R2010"); m = doc.modelspace()
    big = m.add_lwpolyline([(0, 0), (20, 0), (20, 20), (0, 20)], dxfattribs={"closed": True})
    small = m.add_lwpolyline([(6, 6), (14, 6), (14, 14), (6, 14)], dxfattribs={"closed": True})
    src = _tmp(); doc.saveas(src)
    # Build the hole via boolean subtract is covered elsewhere; here just confirm
    # convert_to_stroke yields >=2 loops from a hatch-with-hole created directly.
    doc = ezdxf.new("R2010"); m = doc.modelspace()
    hh = m.add_hatch()
    hh.paths.add_polyline_path([(0, 0), (20, 0), (20, 20), (0, 20)], is_closed=True, flags=1)
    hh.paths.add_polyline_path([(6, 6), (14, 6), (14, 14), (6, 14)], is_closed=True, flags=0)
    hh.set_solid_fill(color=7)
    src = _tmp(); doc.saveas(src)
    res = op_convert_to_stroke({"input": src, "output": out, "handles": [hh.dxf.handle]})
    assert res["status"] == "ok", res
    t = _types(out)
    assert t.get("LWPOLYLINE") == 2, f"hatch-with-hole should give 2 loops: {t}"
    print("Hatch-with-hole -> 2 stroke loops OK")

    # --- SVG fill mode: "preserve" turns a filled rect into a HATCH ---
    svg = '<svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="10" height="10" fill="#ff0000"/><rect x="20" y="0" width="10" height="10" fill="none" stroke="black"/></svg>'
    sf = _tmp(".svg"); open(sf, "w").write(svg)
    res = op_import_svg({"input": sf, "output": out, "svg_fill_mode": "preserve"})
    assert res["status"] == "ok", res
    t = _types(out)
    assert t.get("HATCH") == 1, f"filled rect should import as HATCH: {t}"
    assert t.get("LWPOLYLINE") == 1, f"stroke-only rect should stay a polyline: {t}"
    print("SVG preserve-fill OK:", dict(t))

    # --- SVG default mode: everything is a stroke (legacy behaviour) ---
    res = op_import_svg({"input": sf, "output": out})  # default strokes
    t = _types(out)
    assert t.get("HATCH", 0) == 0 and t.get("LWPOLYLINE") == 2, f"strokes mode: {t}"
    print("SVG strokes-mode (default) OK:", dict(t))

    print("\nALL FILL TESTS PASSED")


if __name__ == "__main__":
    run()
