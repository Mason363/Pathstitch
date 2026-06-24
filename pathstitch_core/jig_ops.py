"""
jig_ops.py

3D Pattern / 3D-Jig export for Pathstitch: turn flat 2D panels (closed loops in
millimetres) into solid 3D bodies and write a binary STL for 3D printing — the
CAD→printer direction (the inverse of the STEP→flat unfolding in step_ops).

A panel is a dict:
    {"outer": [[x, y], ...], "holes": [[[x, y], ...], ...]}
`holes` become through-cutouts in the extruded solid (e.g. stitch holes in a
pricking template). Loops are auto-closed; winding is irrelevant.

Operations:
    extrude_to_stl    — extrude panels by a thickness, optional through-holes.
    jig_from_panels   — mode-driven wrapper (solid pattern / stitch template /
                        corner jig) over extrude_to_stl.
"""
import os
import math
import struct
from typing import Dict, List, Any, Tuple

from OCC.Core.gp import gp_Pnt, gp_Vec
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakePolygon,
    BRepBuilderAPI_MakeFace,
)
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh
from OCC.Core.StlAPI import StlAPI_Writer
from OCC.Core.BRep import BRep_Builder, BRep_Tool
from OCC.Core.TopoDS import TopoDS_Compound
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopLoc import TopLoc_Location


def _close(loop: List[List[float]]) -> List[Tuple[float, float]]:
    """Return the loop's points with any duplicate closing vertex removed."""
    pts = [(float(p[0]), float(p[1])) for p in loop]
    if len(pts) >= 2 and abs(pts[0][0] - pts[-1][0]) < 1e-9 and abs(pts[0][1] - pts[-1][1]) < 1e-9:
        pts = pts[:-1]
    return pts


def _wire(loop: List[List[float]], z: float = 0.0):
    pts = _close(loop)
    if len(pts) < 3:
        return None
    poly = BRepBuilderAPI_MakePolygon()
    for (x, y) in pts:
        poly.Add(gp_Pnt(x, y, z))
    poly.Close()
    if not poly.IsDone():
        return None
    return poly.Wire()


def _panel_solid(panel: Dict[str, Any], thickness: float):
    """Build one extruded solid from a panel (outer loop + optional hole loops)."""
    outer = panel.get("outer")
    if not outer:
        return None
    outer_wire = _wire(outer)
    if outer_wire is None:
        return None
    mk = BRepBuilderAPI_MakeFace(outer_wire, True)
    for hole in (panel.get("holes") or []):
        hw = _wire(hole)
        if hw is not None:
            mk.Add(hw)
    if not mk.IsDone():
        return None
    face = mk.Face()
    prism = BRepPrimAPI_MakePrism(face, gp_Vec(0.0, 0.0, float(thickness)))
    if not prism.IsDone():
        return None
    return prism.Shape()


def _compound(shapes):
    builder = BRep_Builder()
    comp = TopoDS_Compound()
    builder.MakeCompound(comp)
    for s in shapes:
        if s is not None:
            builder.Add(comp, s)
    return comp


def _mesh_preview(shape, deflection: float = 0.3):
    """Tessellate and return flat vertex/triangle arrays for the Three.js viewport."""
    BRepMesh_IncrementalMesh(shape, deflection, False, 0.5, True)
    vertices: List[float] = []
    triangles: List[int] = []
    base = 0
    exp = TopExp_Explorer(shape, TopAbs_FACE)
    while exp.More():
        face = exp.Current()
        loc = TopLoc_Location()
        tri = BRep_Tool.Triangulation(face, loc)
        if tri is not None:
            trsf = loc.Transformation()
            n = tri.NbNodes()
            for i in range(1, n + 1):
                p = tri.Node(i).Transformed(trsf)
                vertices.extend([p.X(), p.Y(), p.Z()])
            for i in range(1, tri.NbTriangles() + 1):
                t = tri.Triangle(i)
                a, b, c = t.Get()
                triangles.extend([base + a - 1, base + b - 1, base + c - 1])
            base += n
        exp.Next()
    return vertices, triangles


def op_extrude_to_stl(args: Dict[str, Any]) -> Dict[str, Any]:
    """Extrude `panels` by `thickness` (mm) and write a binary STL to `output`.
    Hole loops in each panel become through-cutouts. Returns a tessellated mesh
    (for preview), the triangle count, and the output path."""
    panels = args.get("panels")
    output = args.get("output")
    thickness = float(args.get("thickness", 2.0))
    deflection = float(args.get("deflection", 0.3))
    ascii_mode = bool(args.get("ascii", False))

    if not panels:
        return {"status": "error", "message": "No panels to extrude."}
    if not output:
        return {"status": "error", "message": "Output path must be specified."}
    if thickness <= 0:
        return {"status": "error", "message": "Thickness must be positive."}

    solids = []
    for panel in panels:
        s = _panel_solid(panel, thickness)
        if s is not None:
            solids.append(s)
    if not solids:
        return {"status": "error", "message": "No valid closed panels (need >= 3 points)."}

    shape = solids[0] if len(solids) == 1 else _compound(solids)

    # mesh must be built before STL write
    BRepMesh_IncrementalMesh(shape, deflection, False, 0.5, True)
    writer = StlAPI_Writer()
    writer.SetASCIIMode(ascii_mode)
    ok = writer.Write(shape, output)
    if not ok or not os.path.exists(output):
        return {"status": "error", "message": "Failed to write STL."}

    verts, tris = _mesh_preview(shape, deflection)
    return {"status": "ok", "data": {
        "output": output,
        "panels": len(solids),
        "triangle_count": len(tris) // 3,
        "vertices": verts,
        "triangles": tris,
    }}


def op_jig_from_panels(args: Dict[str, Any]) -> Dict[str, Any]:
    """Mode-driven 3D jig builder over extrude_to_stl.
      mode='solid'          : 3D pattern — extrude each panel by `thickness`.
      mode='stitch_template': thin plate (`plate_thickness`) with stitch holes as
                              through-cutouts (panel `holes`).
      mode='corner_jig'     : extrude each panel by `block_thickness` to form
                              forming/holding blocks.
    All modes delegate to extrude_to_stl."""
    mode = str(args.get("mode", "solid")).lower()
    panels = args.get("panels")
    if not panels:
        return {"status": "error", "message": "No panels selected."}

    if mode == "stitch_template":
        thickness = float(args.get("plate_thickness", 3.0))
    elif mode == "corner_jig":
        thickness = float(args.get("block_thickness", 15.0))
    else:
        thickness = float(args.get("thickness", 2.0))

    call = dict(args)
    call["thickness"] = thickness
    res = op_extrude_to_stl(call)
    if res.get("status") == "ok":
        res["data"]["mode"] = mode
    return res


def op_extrude_handles_to_stl(args: Dict[str, Any]) -> Dict[str, Any]:
    """Read a DXF, build panels from the selected closed `handles`, and extrude to
    STL. In `stitch_template` mode, any SEWING_HOLES entities whose centre lies
    inside a panel become through-holes (a printable pricking guide).

    args: input (dxf), handles, output (stl), mode, thickness/plate_thickness."""
    import os as _os
    input_path = args.get("input")
    handles = args.get("handles", [])
    output = args.get("output")
    mode = str(args.get("mode", "solid")).lower()

    if not input_path or not _os.path.exists(input_path):
        return {"status": "error", "message": f"Input file not found: {input_path}"}
    if not handles:
        return {"status": "error", "message": "Select one or more closed regions."}
    if not output:
        return {"status": "error", "message": "Output path must be specified."}

    try:
        import ezdxf
        from ezdxf.path import make_path
    except Exception as e:
        return {"status": "error", "message": f"ezdxf unavailable: {e}"}

    doc = ezdxf.readfile(input_path)
    msp = doc.modelspace()

    def loop_of(ent):
        try:
            p = make_path(ent)
            pts = [[v.x, v.y] for v in p.flattening(distance=0.2)]
            return pts if len(pts) >= 3 else None
        except Exception:
            return None

    panels: List[Dict[str, Any]] = []
    panel_loops = []
    for h in handles:
        try:
            ent = doc.entitydb[h]
        except KeyError:
            continue
        outer = loop_of(ent)
        if outer:
            panels.append({"outer": outer, "holes": []})
            panel_loops.append(outer)

    if not panels:
        return {"status": "error", "message": "No valid closed regions in the selection."}

    if mode == "stitch_template":
        # bucket each SEWING_HOLES entity into the panel that contains its centroid
        def centroid(pts):
            n = len(pts)
            return (sum(p[0] for p in pts) / n, sum(p[1] for p in pts) / n)

        def inside(pt, loop):
            # ray casting
            x, y = pt
            inside = False
            n = len(loop)
            j = n - 1
            for i in range(n):
                xi, yi = loop[i]; xj, yj = loop[j]
                if ((yi > y) != (yj > y)) and \
                   (x < (xj - xi) * (y - yi) / ((yj - yi) or 1e-12) + xi):
                    inside = not inside
                j = i
            return inside

        for ent in msp:
            if ent.dxf.layer != "SEWING_HOLES":
                continue
            hole = loop_of(ent) if ent.dxftype() != "CIRCLE" else None
            if ent.dxftype() == "CIRCLE":
                cx, cy, r = ent.dxf.center.x, ent.dxf.center.y, ent.dxf.radius
                hole = [[cx + r * math.cos(a), cy + r * math.sin(a)]
                        for a in [i * 2.0 * math.pi / 16 for i in range(16)]]
            if not hole:
                continue
            c = centroid(hole)
            for idx, lp in enumerate(panel_loops):
                if inside(c, lp):
                    panels[idx]["holes"].append(hole)
                    break

    call = dict(args)
    call["panels"] = panels
    return op_jig_from_panels(call)


OPERATIONS = {
    "extrude_to_stl": op_extrude_to_stl,
    "jig_from_panels": op_jig_from_panels,
    "extrude_handles_to_stl": op_extrude_handles_to_stl,
}
