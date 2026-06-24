"""Quality tests for the rewritten op_add_holes: even spacing, corner stitches
(Keep/Step), saddle row distance, and sharp-vs-rounded offset corners.

Run from repo root with the pathstitch env:
    PYTHONPATH=. python pathstitch_core/test_holes_quality.py
"""
import math
import tempfile
import ezdxf
from shapely.geometry import LinearRing, Point

from pathstitch_core.dxf_ops import op_add_holes


def _save(doc):
    f = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); f.close()
    doc.saveas(f.name)
    return f.name


def _holes(path):
    doc = ezdxf.readfile(path)
    return [(e.dxf.center.x, e.dxf.center.y)
            for e in doc.modelspace()
            if e.dxftype() == "CIRCLE" and e.dxf.layer == "SEWING_HOLES"]


def _square_doc(side=100.0):
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    sq = m.add_lwpolyline([(0, 0), (side, 0), (side, side), (0, side)],
                          dxfattribs={"closed": True})
    return doc, sq.dxf.handle


def _run(handle, path, out, **extra):
    args = {"input": path, "output": out, "handles": [handle],
            "offset_distance": 3.0, "hole_diameter": 1.0, "hole_spacing": 5.0,
            "side": "left"}
    args.update(extra)
    res = op_add_holes(args)
    assert res["status"] == "ok", res
    return _holes(out)


def _run_raw(handle, path, out, **extra):
    """Like _run but returns the raw op result (for shaped-slit tests that read the
    emitted polylines/ellipses directly rather than circle centres)."""
    args = {"input": path, "output": out, "handles": [handle],
            "offset_distance": 3.0, "hole_diameter": 1.0, "hole_spacing": 5.0,
            "side": "left"}
    args.update(extra)
    res = op_add_holes(args)
    assert res["status"] == "ok", res
    return res


def _nn_dists(pts):
    """Nearest-neighbour distance for each point."""
    out = []
    for i, p in enumerate(pts):
        best = min((math.hypot(p[0] - q[0], p[1] - q[1])
                    for j, q in enumerate(pts) if j != i), default=0.0)
        out.append(best)
    return out


def test_even_spacing():
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
    doc, h = _square_doc(100.0)
    path = _save(doc)
    holes = _run(h, path, out.name, hole_spacing=5.0, corner_holes=False)
    # Inner offset (3 mm) of a 100 mm square has perimeter ~376 mm → ~75 holes.
    assert 70 <= len(holes) <= 80, f"unexpected hole count {len(holes)}"
    nn = _nn_dists(holes)
    worst_lo = min(nn)
    worst_hi = max(nn)
    # Even placement: every gap is close to the 5 mm pitch. The OLD algorithm
    # clustered holes (nn far below pitch) — this guards that regression.
    assert worst_lo >= 5.0 * 0.8, f"holes clustered: min nn gap {worst_lo:.2f} mm"
    assert worst_hi <= 5.0 * 1.3, f"holes spread unevenly: max nn gap {worst_hi:.2f} mm"
    print(f"Even spacing OK: {len(holes)} holes, nn gap in "
          f"[{worst_lo:.2f}, {worst_hi:.2f}] mm")


def test_corner_holes_default_on():
    """Corner holes are ON by default: every corner of the square gets a stitch on
    its sharp inner apex, and the spacing flexes (variable) to stay near target."""
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
    doc, h = _square_doc(100.0)
    path = _save(doc)
    # No corner_holes arg → relies on the default being True. Pitch 7 mm does NOT
    # divide the 94 mm inner side evenly, so a hole only lands on every corner if
    # corners are genuinely detected (not by lucky even division).
    holes = _run(h, path, out.name, hole_spacing=7.0)
    apexes = [(3.0, 3.0), (97.0, 3.0), (97.0, 97.0), (3.0, 97.0)]
    for ax, ay in apexes:
        d = min(math.hypot(x - ax, y - ay) for x, y in holes)
        assert d < 0.6, f"no stitch at corner ({ax},{ay}) — nearest {d:.2f} mm"
    nn = _nn_dists(holes)
    assert max(nn) <= 7.0 * 1.35, f"corner-hole spacing too uneven (max nn {max(nn):.2f})"
    print(f"Corner holes default-on OK: stitch on all 4 corners, "
          f"{len(holes)} holes, max gap {max(nn):.2f} mm")


def test_corner_holes_off():
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
    doc, h = _square_doc(100.0)
    path = _save(doc)
    holes = _run(h, path, out.name, hole_spacing=5.0, corner_holes=False)
    # With corners off the run is continuous; a hole need not land on the apex.
    apex = (3.0, 3.0)
    d = min(math.hypot(x - apex[0], y - apex[1]) for x, y in holes)
    print(f"Corner holes off OK: nearest hole to apex {d:.2f} mm ({len(holes)} holes)")


def test_corner_holes_rounded():
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
    doc, h = _square_doc(100.0)
    path = _save(doc)
    holes = _run(h, path, out.name, offset_corner_fillet=True)
    # Filleted inner offset → the sharp apex at (3,3) becomes a rounded arc, so
    # there is no hole at the apex and the nearest corner hole sits farther out.
    apex = (3.0, 3.0)
    d_apex = min(math.hypot(x - apex[0], y - apex[1]) for x, y in holes)
    assert d_apex > 1.0, f"fillet still placed a hole at the sharp apex ({d_apex:.2f} mm)"
    near0 = min(holes, key=lambda p: math.hypot(p[0], p[1]))
    dist0 = math.hypot(*near0)
    assert dist0 > 4.5, f"rounded corner hole too close to corner {dist0:.2f} mm (not filleted)"
    print(f"Corner holes + rounded offset OK: no apex hole (>{d_apex:.2f} mm), "
          f"nearest corner hole {dist0:.2f} mm from corner")


def test_corner_threshold_45():
    """find_corners must flag a turn sharper than 45 deg and ignore a gentler one."""
    from pathstitch_core.dxf_ops import find_corners
    # ~90 deg turn at (10,0): detected.
    sharp = find_corners([(0, 0), (10, 0), (10, 10)], angle_threshold_deg=45.0)
    assert any(abs(px - 10) < 1e-6 and abs(py) < 1e-6 for px, py in sharp), \
        f"45 deg threshold missed a 90 deg corner: {sharp}"
    # ~30 deg turn at (10,0): below threshold, ignored.
    import math as _m
    dx, dy = math.cos(_m.radians(30)), math.sin(_m.radians(30))
    gentle = find_corners([(0, 0), (10, 0), (10 + 10 * dx, 10 * dy)],
                          angle_threshold_deg=45.0)
    assert not gentle, f"45 deg threshold wrongly flagged a 30 deg bend: {gentle}"
    print("Corner threshold 45 deg OK: 90 deg flagged, 30 deg ignored")


def test_saddle_rows():
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
    doc, h = _square_doc(100.0)
    ring = LinearRing([(0, 0), (100, 0), (100, 100), (0, 100), (0, 0)])
    path = _save(doc)
    saddle = 4.0
    holes = _run(h, path, out.name, offset_distance=5.0, pattern="saddle",
                 saddle_spacing=saddle, corner_holes=False)
    # Two rows straddle the 5 mm offset → bands at ~3 mm and ~7 mm from contour.
    devs = sorted(ring.distance(Point(x, y)) for x, y in holes)
    lo_band = [d for d in devs if d < 5.0]
    hi_band = [d for d in devs if d >= 5.0]
    assert lo_band and hi_band, "saddle did not produce two rows"
    lo_mean = sum(lo_band) / len(lo_band)
    hi_mean = sum(hi_band) / len(hi_band)
    gap = hi_mean - lo_mean
    assert abs(gap - saddle) < 1.0, f"saddle row distance {gap:.2f} != {saddle}"
    print(f"Saddle OK: rows at {lo_mean:.2f} & {hi_mean:.2f} mm "
          f"(distance {gap:.2f} mm, target {saddle})")


def test_open_path_even():
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    ln = m.add_lwpolyline([(0, 0), (100, 0)], dxfattribs={"closed": False})
    path = _save(doc)
    holes = _run(ln.dxf.handle, path, out.name, hole_spacing=10.0, side="left")
    assert len(holes) >= 9, f"open line produced too few holes ({len(holes)})"
    xs = sorted(x for x, _ in holes)
    gaps = [xs[i + 1] - xs[i] for i in range(len(xs) - 1)]
    assert max(gaps) - min(gaps) < 0.5, f"open-line spacing uneven: {gaps}"
    print(f"Open path OK: {len(holes)} holes, even gaps ~{sum(gaps)/len(gaps):.2f} mm")


def test_concave_in_band_even():
    """An L-shaped (concave) contour must keep holes in the offset band and evenly
    spaced — the old side-flip/scatter bug hit concave shapes hardest."""
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    pts = [(0, 0), (80, 0), (80, 40), (40, 40), (40, 80), (0, 80)]
    poly = m.add_lwpolyline(pts, dxfattribs={"closed": True})
    ring = LinearRing(pts + [pts[0]])
    path = _save(doc)
    holes = _run(poly.dxf.handle, path, out.name, offset_distance=3.0,
                 hole_spacing=5.0, side="left", corner_holes=False)
    assert len(holes) > 0
    worst = max(ring.distance(Point(x, y)) for x, y in holes)
    assert worst < 3.0 + 1.5, f"concave holes flung out of band (worst {worst:.2f} mm)"
    nn = _nn_dists(holes)
    assert min(nn) >= 5.0 * 0.8, f"concave holes clustered (min nn {min(nn):.2f})"
    assert max(nn) <= 5.0 * 1.3, f"concave holes uneven (max nn {max(nn):.2f})"
    print(f"Concave OK: {len(holes)} holes, in-band (<{worst:.2f} mm), even gaps")


def test_screenshot_rectangle():
    """Reproduce the reported case: a ~110x58 mm rectangle, small offset, 4 mm
    pitch, single row, Keep — must be one clean even row per side, no scatter."""
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    W, H = 109.98, 58.30
    rect = m.add_lwpolyline([(0, 0), (W, 0), (W, H), (0, H)], dxfattribs={"closed": True})
    ring = LinearRing([(0, 0), (W, 0), (W, H), (0, H), (0, 0)])
    path = _save(doc)
    holes = _run(rect.dxf.handle, path, out.name, offset_distance=2.0,
                 hole_spacing=4.0, side="left", corner_holes=False)
    # Inner perimeter ~ 2*((W-4)+(H-4)) = ~320 mm → ~80 holes, single even row.
    assert 72 <= len(holes) <= 88, f"rectangle hole count off: {len(holes)}"
    worst = max(ring.distance(Point(x, y)) for x, y in holes)
    assert worst < 2.0 + 1.5, f"rectangle holes scattered (worst {worst:.2f} mm)"
    nn = _nn_dists(holes)
    assert max(nn) <= 4.0 * 1.4, f"rectangle row uneven (max nn {max(nn):.2f})"
    print(f"Screenshot rectangle OK: {len(holes)} holes, even single row, "
          f"in-band (<{worst:.2f} mm)")


def _slits(path, dxftype):
    doc = ezdxf.readfile(path)
    return [e for e in doc.modelspace()
            if e.dxftype() == dxftype and e.dxf.layer == "SEWING_HOLES"]


def test_iron_shapes_emit_closed_paths():
    """Each non-round iron shape emits real, closed cut-paths (or a native ellipse),
    one per hole — not circles — so the slit exports to DXF/SVG/laser."""
    expectations = {
        "diamond": ("LWPOLYLINE", 4),
        "flat":    ("LWPOLYLINE", 4),
        "french":  ("LWPOLYLINE", None),   # capsule → many vertices, all closed
    }
    for shape, (dxftype, nverts) in expectations.items():
        out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
        doc, h = _square_doc(100.0)
        path = _save(doc)
        # circles for the baseline count, then the shaped run.
        base = _run(h, path, out.name, hole_spacing=7.0)
        n_round = len(base)
        ents = _run_raw(h, path, out.name, hole_spacing=7.0, hole_shape=shape,
                        slit_length=2.0, slit_width=0.8)
        polys = _slits(out.name, dxftype)
        assert not _slits(out.name, "CIRCLE"), f"{shape} still emitted circles"
        assert len(polys) == n_round, \
            f"{shape}: {len(polys)} slits != {n_round} placements"
        for p in polys:
            assert p.closed, f"{shape} slit not closed"
            if nverts is not None:
                assert len(p) == nverts, f"{shape} slit has {len(p)} verts != {nverts}"
        print(f"Iron shape '{shape}' OK: {len(polys)} closed {dxftype} slits "
              f"(matches {n_round} round placements)")


def test_iron_oval_is_ellipse():
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
    doc, h = _square_doc(100.0)
    path = _save(doc)
    _run_raw(h, path, out.name, hole_spacing=7.0, hole_shape="oval",
             slit_length=2.0, slit_width=1.0)
    ells = _slits(out.name, "ELLIPSE")
    assert ells, "oval iron emitted no ellipses"
    assert not _slits(out.name, "CIRCLE"), "oval iron also emitted circles"
    print(f"Iron shape 'oval' OK: {len(ells)} ellipses")


def test_iron_slit_orientation():
    """On a straight open line the diamond's long axis follows the tangent: its two
    far vertices are spread along X (the line direction), span ~= slit_length."""
    out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
    doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
    ln = m.add_lwpolyline([(0, 0), (100, 0)], dxfattribs={"closed": False})
    path = _save(doc)
    _run_raw(ln.dxf.handle, path, out.name, hole_spacing=10.0, side="left",
             hole_shape="diamond", slit_length=3.0, slit_width=1.0, corner_holes=False)
    polys = _slits(out.name, "LWPOLYLINE")
    assert polys, "no diamond slits on open line"
    pts = [(p[0], p[1]) for p in polys[0]]
    span_x = max(x for x, _ in pts) - min(x for x, _ in pts)
    span_y = max(y for _, y in pts) - min(y for _, y in pts)
    assert abs(span_x - 3.0) < 0.2, f"long axis not along tangent (span_x {span_x:.2f})"
    assert abs(span_y - 1.0) < 0.2, f"short axis wrong (span_y {span_y:.2f})"
    print(f"Iron orientation OK: long axis {span_x:.2f} mm along tangent, "
          f"short {span_y:.2f} mm")


def test_iron_inverted_flips_slant():
    """With a 30 deg iron angle, inverted mirrors the slit about the tangent: the
    top-right vertex of the diamond moves to the bottom-right."""
    def _far_vertex(inverted):
        out = tempfile.NamedTemporaryFile(suffix=".dxf", delete=False); out.close()
        doc = ezdxf.new(dxfversion="R2010"); m = doc.modelspace()
        ln = m.add_lwpolyline([(0, 0), (100, 0)], dxfattribs={"closed": False})
        path = _save(doc)
        _run_raw(ln.dxf.handle, path, out.name, hole_spacing=20.0, side="left",
                 hole_shape="diamond", slit_length=4.0, slit_width=1.0,
                 slit_angle=30.0, inverted=inverted, corner_holes=False)
        p = _slits(out.name, "LWPOLYLINE")[0]
        verts = [(v[0], v[1]) for v in p]
        cx = sum(x for x, _ in verts) / len(verts)
        cy = sum(y for _, y in verts) / len(verts)
        # long-axis tip, measured relative to the slit's own centre.
        tip = max(verts, key=lambda q: q[0] - cx)
        return tip[1] - cy
    tip_n = _far_vertex(False)
    tip_i = _far_vertex(True)
    # 30 deg up vs 30 deg down → tip on opposite sides of the tangent in Y.
    assert tip_n * tip_i < 0, f"inverted did not flip slant: {tip_n:.2f} vs {tip_i:.2f}"
    print(f"Iron inverted OK: tip dy {tip_n:.2f} -> {tip_i:.2f} (slant flipped)")


def run():
    test_even_spacing()
    test_concave_in_band_even()
    test_screenshot_rectangle()
    test_corner_holes_default_on()
    test_corner_holes_off()
    test_corner_holes_rounded()
    test_corner_threshold_45()
    test_saddle_rows()
    test_open_path_even()
    test_iron_shapes_emit_closed_paths()
    test_iron_oval_is_ellipse()
    test_iron_slit_orientation()
    test_iron_inverted_flips_slant()
    print("\nALL HOLE QUALITY TESTS PASSED")


if __name__ == "__main__":
    run()
