import os
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
from OCC.Core.STEPControl import STEPControl_Writer, STEPControl_AsIs
from OCC.Core.gp import gp_Pnt, gp_Ax2, gp_Dir

def create_test_step():
    # Make a box (Body 1)
    box = BRepPrimAPI_MakeBox(100.0, 50.0, 30.0).Shape()
    
    # Make a cylinder (Body 2)
    # Position cylinder at (150, 0, 0)
    ax2 = gp_Ax2(gp_Pnt(150.0, 25.0, 0.0), gp_Dir(0.0, 0.0, 1.0))
    cylinder = BRepPrimAPI_MakeCylinder(ax2, 20.0, 60.0).Shape()
    
    # Write to STEP file
    writer = STEPControl_Writer()
    writer.Transfer(box, STEPControl_AsIs)
    writer.Transfer(cylinder, STEPControl_AsIs)
    
    os.makedirs("TestFiles", exist_ok=True)
    writer.Write("TestFiles/test.step")
    print("Created TestFiles/test.step successfully.")

if __name__ == "__main__":
    create_test_step()
