import subprocess
import json
import os

PYTHON_BIN = "/opt/homebrew/Caskroom/miniconda/base/envs/pathstitch/bin/python"

def run_cli(op, args):
    payload = json.dumps({"op": op, "args": args})
    # Run python -m pathstitch_core.dxf_ops
    cmd = [PYTHON_BIN, "-m", "pathstitch_core.dxf_ops", "--json", payload]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"CLI process crashed: {res.stderr}")
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"Failed to decode CLI stdout: {res.stdout}")

def test_dxf_ops():
    input_dxf = "TestFiles/test.dxf"
    
    # 1. Test list_entities
    print("Testing list_entities...")
    res = run_cli("list_entities", {"input": input_dxf})
    assert res["status"] == "ok", f"list_entities failed: {res}"
    entities = res["data"]["entities"]
    print(f"Found {len(entities)} entities in test.dxf")
    assert len(entities) == 3, f"Expected 3 entities, got {len(entities)}"
    
    # 2. Test offset_lines
    print("Testing offset_lines...")
    offset_dxf = "TestFiles/test_offset.dxf"
    res = run_cli("offset_lines", {
        "input": input_dxf,
        "output": offset_dxf,
        "distance": 3.0,
        "side": "left",
        "layer": "OFFSET"
    })
    assert res["status"] == "ok", f"offset_lines failed: {res}"
    assert os.path.exists(offset_dxf), "Offset DXF file not created"
    
    # Verify offset file has entities
    res = run_cli("list_entities", {"input": offset_dxf})
    entities = res["data"]["entities"]
    offset_count = sum(1 for e in entities if e["layer"] == "OFFSET")
    print(f"Found {offset_count} entities on OFFSET layer")
    assert offset_count > 0, "No offset entities generated"
    
    # 3. Test add_holes
    print("Testing add_holes (single row)...")
    holes_dxf = "TestFiles/test_holes.dxf"
    res = run_cli("add_holes", {
        "input": input_dxf,
        "output": holes_dxf,
        "offset_distance": 5.0,
        "hole_diameter": 1.5,
        "hole_spacing": 6.0,
        "pattern": "single",
        "corner_behavior": "skip",
        "side": "left"
    })
    assert res["status"] == "ok", f"add_holes failed: {res}"
    assert os.path.exists(holes_dxf), "Holes DXF file not created"
    
    res = run_cli("list_entities", {"input": holes_dxf})
    entities = res["data"]["entities"]
    hole_count = sum(1 for e in entities if e["layer"] == "SEWING_HOLES")
    print(f"Generated {hole_count} sewing holes (single row)")
    assert hole_count > 0, "No sewing holes generated"

    # Test add_holes (saddle stitching)
    print("Testing add_holes (saddle staggered pattern)...")
    saddle_dxf = "TestFiles/test_saddle.dxf"
    res = run_cli("add_holes", {
        "input": input_dxf,
        "output": saddle_dxf,
        "offset_distance": 5.0,
        "hole_diameter": 1.5,
        "hole_spacing": 6.0,
        "pattern": "saddle",
        "corner_behavior": "skip",
        "side": "left",
        "row_spacing": 3.0
    })
    assert res["status"] == "ok", f"add_holes (saddle) failed: {res}"
    
    res = run_cli("list_entities", {"input": saddle_dxf})
    entities = res["data"]["entities"]
    saddle_hole_count = sum(1 for e in entities if e["layer"] == "SEWING_HOLES")
    print(f"Generated {saddle_hole_count} sewing holes (saddle stitching)")
    assert saddle_hole_count > hole_count, "Saddle stitch should produce more holes than single stitch"

    # 4. Test export_svg
    print("Testing export_svg...")
    output_svg = "TestFiles/test.svg"
    res = run_cli("export_svg", {
        "input": input_dxf,
        "output": output_svg
    })
    assert res["status"] == "ok", f"export_svg failed: {res}"
    assert os.path.exists(output_svg), "SVG file not created"
    print(f"SVG successfully exported to: {output_svg}")
    
    # 5. Test cleanup
    print("Testing cleanup...")
    cleanup_dxf = "TestFiles/test_cleanup.dxf"
    res = run_cli("cleanup", {
        "input": input_dxf,
        "output": cleanup_dxf,
        "tolerance": 0.5
    })
    assert res["status"] == "ok", f"cleanup failed: {res}"
    assert os.path.exists(cleanup_dxf), "Cleanup DXF file not created"
    print(f"Cleanup stats: {res['data']}")

    # 6. Test new_dxf creates a valid blank document
    print("Testing new_dxf (blank document)...")
    blank_dxf = "TestFiles/test_blank.dxf"
    if os.path.exists(blank_dxf):
        os.remove(blank_dxf)
    res = run_cli("new_dxf", {"output": blank_dxf})
    assert res["status"] == "ok", f"new_dxf failed: {res}"
    assert os.path.exists(blank_dxf), "Blank DXF file not created"
    res = run_cli("list_entities", {"input": blank_dxf})
    assert res["status"] == "ok", f"list_entities on blank failed: {res}"
    assert len(res["data"]["entities"]) == 0, "Blank DXF should have no entities"
    print("Blank document created and lists 0 entities")

    # 7. Test export_svg on an empty document returns a valid empty SVG (no error)
    print("Testing export_svg on empty document...")
    empty_svg = "TestFiles/test_empty.svg"
    if os.path.exists(empty_svg):
        os.remove(empty_svg)
    res = run_cli("export_svg", {"input": blank_dxf, "output": empty_svg})
    assert res["status"] == "ok", f"export_svg on empty should succeed: {res}"
    assert res["data"].get("empty") is True, f"export_svg should flag empty: {res}"
    assert os.path.exists(empty_svg), "Empty SVG file not created"
    print("Empty document exported a valid empty SVG without erroring")

    # 8. Test append_dxf merges into a blank document (MAS-13 regression).
    print("Testing append_dxf into a blank document...")
    merged_dxf = "TestFiles/test_merged.dxf"
    if os.path.exists(merged_dxf):
        os.remove(merged_dxf)
    res = run_cli("append_dxf", {
        "primary": blank_dxf,
        "secondary": input_dxf,
        "output": merged_dxf
    })
    assert res["status"] == "ok", f"append_dxf into blank failed: {res}"
    res = run_cli("list_entities", {"input": merged_dxf})
    merged_count = len(res["data"]["entities"])
    print(f"Merged document has {merged_count} entities")
    assert merged_count == 3, f"Expected 3 merged entities, got {merged_count}"
 
    # 9. Test point ignoring and import_distribute layout aspect ratio
    print("Testing point ignoring and import_distribute layout...")
    import ezdxf
    
    # Create a secondary DXF with:
    # - a line from (10, 10) to (20, 20)
    # - a touching POINT at (10, 10)
    # - an isolated POINT at (100, 100) (should be ignored for layout calculation)
    test_pts_dxf = "TestFiles/test_pts.dxf"
    doc_pts = ezdxf.new(dxfversion="R2010")
    msp_pts = doc_pts.modelspace()
    msp_pts.add_line((10.0, 10.0), (20.0, 20.0))
    msp_pts.add_point((10.0, 10.0))
    msp_pts.add_point((100.0, 100.0))
    doc_pts.saveas(test_pts_dxf)
    
    pts_out_dxf = "TestFiles/test_pts_out.dxf"
    if os.path.exists(pts_out_dxf):
        os.remove(pts_out_dxf)
        
    res = run_cli("import_distribute", {
        "primary": blank_dxf,
        "secondaries": [test_pts_dxf],
        "output": pts_out_dxf
    })
    assert res["status"] == "ok", f"import_distribute failed: {res}"
    
    # Read output and verify the line is centered around (0,0),
    # meaning the bounds center used was (15,15) and NOT (55,55).
    doc_out = ezdxf.readfile(pts_out_dxf)
    msp_out = doc_out.modelspace()
    lines = [e for e in msp_out if e.dxftype() == "LINE"]
    assert len(lines) == 1, "Expected 1 line in output"
    line = lines[0]
    l_cx = (line.dxf.start.x + line.dxf.end.x) / 2.0
    l_cy = (line.dxf.start.y + line.dxf.end.y) / 2.0
    assert abs(l_cx) < 0.1 and abs(l_cy) < 0.1, f"Expected line center near (0,0), got ({l_cx}, {l_cy})"
    print("Isolated points successfully ignored in bounds calculation!")

    # Test 2D compact grid distribution of multiple files (e.g. 3 files)
    print("Testing 2D compact grid layout distribution...")
    grid_out_dxf = "TestFiles/test_grid_out.dxf"
    if os.path.exists(grid_out_dxf):
        os.remove(grid_out_dxf)
    
    res = run_cli("import_distribute", {
        "primary": blank_dxf,
        "secondaries": [test_pts_dxf, test_pts_dxf, test_pts_dxf],
        "output": grid_out_dxf
    })
    assert res["status"] == "ok", f"import_distribute for grid failed: {res}"
    
    doc_grid = ezdxf.readfile(grid_out_dxf)
    msp_grid = doc_grid.modelspace()
    lines_grid = [e for e in msp_grid if e.dxftype() == "LINE"]
    assert len(lines_grid) == 3, f"Expected 3 lines, got {len(lines_grid)}"
    
    centers = [((l.dxf.start.x + l.dxf.end.x)/2.0, (l.dxf.start.y + l.dxf.end.y)/2.0) for l in lines_grid]
    y_coords = [c[1] for c in centers]
    min_y, max_y = min(y_coords), max(y_coords)
    assert abs(max_y - min_y) > 10.0, f"Expected items to stack vertically (diff in Y > 10), got Y coords: {y_coords}"
    print("2D compact layout verified successfully!")

    # 10. Test add_holes on both sides
    print("Testing add_holes (both sides)...")
    both_holes_dxf = "TestFiles/test_both_holes.dxf"
    res = run_cli("add_holes", {
        "input": input_dxf,
        "output": both_holes_dxf,
        "offset_distance": 3.0,
        "hole_diameter": 1.0,
        "hole_spacing": 4.0,
        "side": "both"
    })
    assert res["status"] == "ok", f"add_holes both sides failed: {res}"
    res = run_cli("list_entities", {"input": both_holes_dxf})
    both_hole_count = sum(1 for e in res["data"]["entities"] if e["layer"] == "SEWING_HOLES")
    print(f"Generated {both_hole_count} sewing holes on both sides")
    assert both_hole_count > 0

    # 11. Test add_glue_tabs with start/end offsets
    print("Testing add_glue_tabs with start/end offsets...")
    tabs_dxf = "TestFiles/test_tabs.dxf"
    # Get a LINE handle from test_pts_dxf
    res = run_cli("list_entities", {"input": test_pts_dxf})
    lines = [e for e in res["data"]["entities"] if e["type"] == "LINE"]
    assert len(lines) > 0, "No lines found to add glue tabs to"
    line_handle = lines[0]["handle"]
    res = run_cli("add_glue_tabs", {
        "input": test_pts_dxf,
        "output": tabs_dxf,
        "handles": [line_handle],
        "height": 5.0,
        "type": "trapezoid",
        "side": "left",
        "start_offset": 2.0,
        "end_offset": 3.0
    })
    assert res["status"] == "ok", f"add_glue_tabs failed: {res}"
    assert os.path.exists(tabs_dxf)
    print("Paper tab generation with offsets verified successfully!")

    print("ALL TESTS PASSED SUCCESSFULLY!")

if __name__ == "__main__":
    test_dxf_ops()
