"""Tests for export options (MAS-156): SVG precision/stroke-width and DXF
version. Run from repo root with the pathstitch conda env:
    python pathstitch_core/test_export_options.py"""
import re
import tempfile
import ezdxf

from pathstitch_core.dxf_ops import op_export_svg, op_export_dxf


def _src():
    doc = ezdxf.new("R2010"); m = doc.modelspace()
    m.add_lwpolyline([(0.123456, 0.987654), (10.555, 0.0), (10.0, 10.314159)],
                     dxfattribs={"closed": True})
    f = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); f.close()
    doc.saveas(f.name)
    return f.name


def run():
    src = _src()

    # --- SVG precision: coordinates rounded to N decimals ---
    out = tempfile.NamedTemporaryFile(suffix=".svg", delete=False); out.close()
    res = op_export_svg({"input": src, "output": out.name, "precision": 2, "stroke_width": 1.5})
    assert res["status"] == "ok", res
    svg = open(out.name).read()
    # Every numeric token in points/coords has <= 2 decimals.
    nums = re.findall(r"-?\d+\.(\d+)", svg)
    assert nums, "no decimal coordinates found in SVG"
    assert all(len(frac) <= 2 for frac in nums), f"precision not applied: {[n for n in nums if len(n) > 2][:5]}"
    assert 'stroke-width="1.5"' in svg or "stroke-width:1.5" in svg or "1.5" in svg, "stroke width not applied"
    print("SVG precision=2 + stroke_width OK")

    # --- SVG without precision keeps full floats (some token has >2 decimals) ---
    res = op_export_svg({"input": src, "output": out.name})
    svg = open(out.name).read()
    nums = re.findall(r"-?\d+\.(\d+)", svg)
    assert any(len(frac) > 2 for frac in nums), "expected full-precision floats by default"
    print("SVG default full-precision OK")

    # --- DXF version: requested release is written into the header ---
    outd = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); outd.close()
    res = op_export_dxf({"input": src, "output": outd.name, "version": "R2018"})
    assert res["status"] == "ok", res
    doc = ezdxf.readfile(outd.name)
    assert doc.dxfversion == "AC1032", f"expected AC1032 (R2018), got {doc.dxfversion}"
    print("DXF version R2018 OK:", doc.dxfversion)

    res = op_export_dxf({"input": src, "output": outd.name, "version": "R2000"})
    assert res["status"] == "ok", res
    doc = ezdxf.readfile(outd.name)
    assert doc.dxfversion == "AC1015", f"expected AC1015 (R2000), got {doc.dxfversion}"
    print("DXF version R2000 OK:", doc.dxfversion)

    # --- DXF with no version still works ---
    res = op_export_dxf({"input": src, "output": outd.name})
    assert res["status"] == "ok", res
    print("DXF default version OK")

    print("\nALL EXPORT-OPTION TESTS PASSED")


if __name__ == "__main__":
    run()
