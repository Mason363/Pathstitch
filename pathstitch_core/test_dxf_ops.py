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

    print("ALL TESTS PASSED SUCCESSFULLY!")

if __name__ == "__main__":
    test_dxf_ops()
