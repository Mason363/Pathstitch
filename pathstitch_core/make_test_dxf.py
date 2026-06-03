import os
import ezdxf

def make_test_dxf():
    # Ensure TestFiles directory exists
    os.makedirs("TestFiles", exist_ok=True)
    
    doc = ezdxf.new("R2018")
    doc.header['$MEASUREMENT'] = 1  # 1 = Metric (mm)
    doc.header['$INSUNITS'] = 4     # 4 = Millimeters
    
    msp = doc.modelspace()
    
    # Layer setup
    doc.layers.new("ORIGINAL", dxfattribs={"color": 1}) # Red
    
    # Add a rectangle (as a closed LWPOLYLINE)
    msp.add_lwpolyline(
        [(10.0, 10.0), (110.0, 10.0), (110.0, 110.0), (10.0, 110.0)],
        format="xy",
        dxfattribs={"layer": "ORIGINAL", "closed": True}
    )
    
    # Add a circle
    msp.add_circle(
        center=(60.0, 60.0),
        radius=30.0,
        dxfattribs={"layer": "ORIGINAL"}
    )
    
    # Add an open polyline
    msp.add_lwpolyline(
        [(15.0, 15.0), (60.0, 30.0), (105.0, 15.0)],
        format="xy",
        dxfattribs={"layer": "ORIGINAL", "closed": False}
    )

    # Save to TestFiles/test.dxf
    output_path = "TestFiles/test.dxf"
    doc.saveas(output_path)
    print(f"Test DXF created at: {output_path}")

if __name__ == "__main__":
    make_test_dxf()
