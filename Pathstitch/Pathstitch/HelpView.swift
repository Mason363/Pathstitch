import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Title
                Text("Pathstitch Help & Documentation")
                    .font(.system(.title, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Divider()
                    .background(Color.gray)
                
                // Architectural Guidance Section
                Group {
                    Text("Architectural Guidance")
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.yellow)
                    
                    Text("Pathstitch is a premium macOS CAD editor specializing in leathercraft sewing patterns and 3D unfoldings. The workflow revolves around:")
                        .foregroundColor(.gray)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        bulletPoint("3D Model centring and grounding (touching ground plane).")
                        bulletPoint("Unfolding 3D STEP faces into 2D flat patterns.")
                        bulletPoint("Adding offset curves, crease lines, glue tabs, and sewing holes.")
                        bulletPoint("Exporting to precision SVG and DXF vector formats.")
                    }
                }
                
                Divider()
                    .background(Color.gray)
                
                // Keyboard Shortcuts Section
                Group {
                    Text("Keyboard Shortcuts")
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.yellow)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        shortcutRow("CMD + O", "Open .stch project file")
                        shortcutRow("CMD + S", "Save .stch project file")
                        shortcutRow("CMD + Z", "Undo last operation")
                        shortcutRow("CMD + SHIFT + Z", "Redo last operation")
                        shortcutRow("Delete / Backspace", "Delete selected canvas shapes")
                        shortcutRow("Trackpad Scroll", "Pan 2D canvas view")
                        shortcutRow("CMD + Trackpad Scroll", "Zoom 2D canvas view")
                    }
                }
                
                Divider()
                    .background(Color.gray)
                
                // Layer Management Guidelines
                Group {
                    Text("Layer Management")
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.yellow)
                    
                    Text("Keep your workspace clean by assigning entities to distinct layers:")
                        .foregroundColor(.gray)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        bulletPoint("dxf_original: The original imported DXF outline.")
                        bulletPoint("drawn_shapes: Custom drawn geometry.")
                        bulletPoint("3d_to_2d: Unfolded geometries from 3D models.")
                        bulletPoint("sewing_holes: Sewing holes and seam lines.")
                    }
                }
            }
            .padding(30)
        }
        .frame(width: 550, height: 600)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
        .preferredColorScheme(.dark)
    }
    
    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.yellow)
            Text(text)
                .foregroundColor(.white)
        }
        .font(.body)
    }
    
    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white)
                .cornerRadius(4)
            
            Text(desc)
                .foregroundColor(.white)
                .font(.body)
        }
    }
}
