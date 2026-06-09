import SwiftUI

struct FaceRowView: View {
    let bodyIndex: Int
    let face: Face3D
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "square.on.square")
                .font(.system(size: 8))
                .foregroundColor(isSelected ? Color.accent : Color.text_muted)
            
            Text("Face \(face.face_index)")
                .font(PlasticityFont.label)
                .foregroundColor(isSelected ? Color.accent : Color.text_secondary)
            
            Spacer()
            
            Text(face.type)
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.bg_panel)
                .cornerRadius(2)
                .foregroundColor(Color.text_muted)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 20)
        .background(isSelected ? Color.bg_selected : Color.clear)
        .cornerRadius(3)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

struct SelectedFaceRowView: View {
    let sel: SelectedFace
    let bodyObj: Body3D
    let face: Face3D
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("B\(sel.bodyIndex + 1) : F\(sel.faceIndex)")
                    .font(PlasticityFont.body)
                    .fontWeight(.bold)
                    .foregroundColor(Color.accent)
                Spacer()
                Text(face.type)
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.bg_selected)
                    .cornerRadius(2)
                    .foregroundColor(Color.text_primary)
            }
            Text("\(String(format: "%.1f", face.area)) mm²")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)
        }
        .padding(6)
        .background(Color.bg_input)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
    }
}

struct ThreeDModeView: View {
    @Bindable var state: AppState
    @State private var selectedPlane: String = "XY"
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Panel: Solid Bodies (200px wide)
            VStack(alignment: .leading, spacing: 0) {
                Text("SOLID BODIES")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_secondary)
                    .tracking(0.5)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                
                Divider().background(Color.border_subtle)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach($state.bodies3D) { $body in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Button(action: {
                                        body.visible.toggle()
                                    }) {
                                        Image(systemName: body.visible ? "eye" : "eye.slash")
                                            .font(.system(size: 11))
                                            .foregroundColor(body.visible ? Color.text_primary : Color.text_muted)
                                            .frame(width: 14, height: 14)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    
                                    Image(systemName: "cube.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.accent)
                                    
                                    Text(body.name)
                                        .font(PlasticityFont.body)
                                        .foregroundColor(Color.text_primary)
                                        .lineLimit(1)
                                    
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(Color.bg_input.opacity(0.3))
                                .cornerRadius(4)
                                
                                if body.visible {
                                    VStack(alignment: .leading, spacing: 1) {
                                        ForEach(body.faces) { face in
                                            let faceSel = SelectedFace(bodyIndex: body.body_index, faceIndex: face.face_index)
                                            let isSelected = state.selectedFaces3D.contains(faceSel)
                                            
                                            FaceRowView(
                                                bodyIndex: body.body_index,
                                                face: face,
                                                isSelected: isSelected,
                                                onTap: {
                                                    if NSEvent.modifierFlags.contains(.shift) {
                                                        if state.selectedFaces3D.contains(faceSel) {
                                                            state.selectedFaces3D.remove(faceSel)
                                                        } else {
                                                            state.selectedFaces3D.insert(faceSel)
                                                        }
                                                    } else {
                                                        state.selectedFaces3D = [faceSel]
                                                    }
                                                }
                                            )
                                        }
                                    }
                                    .padding(.leading, 8)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .frame(width: 200)
            .background(Color.bg_panel)
            .border(Color.border_subtle, width: 1)
            
            // Center Viewport: WKWebView wrapper
            ThreeDViewport(
                selectedFaces3D: state.selectedFaces3D,
                stepJsonContent: state.stepJsonContent,
                bodies3D: state.bodies3D,
                state: state
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bg_base)
            
            // Right Panel: Selection & Processing (240px wide)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Section 1: Selection Info
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SELECTED FACES")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_secondary)
                                .tracking(0.5)
                            
                            if state.selectedFaces3D.isEmpty {
                                Text("No selection")
                                    .font(PlasticityFont.body)
                                    .foregroundColor(Color.text_muted)
                                    .padding(.vertical, 4)
                            } else {
                                Text("\(state.selectedFaces3D.count) face(s) in queue")
                                    .font(PlasticityFont.body)
                                    .foregroundColor(Color.text_primary)
                                    .padding(.bottom, 4)
                                
                                ForEach(Array(state.selectedFaces3D), id: \.self) { sel in
                                    if let body = state.bodies3D.first(where: { $0.body_index == sel.bodyIndex }),
                                       let face = body.faces.first(where: { $0.face_index == sel.faceIndex }) {
                                        SelectedFaceRowView(sel: sel, bodyObj: body, face: face)
                                    }
                                }
                            }
                            
                            Divider().background(Color.border_subtle)
                        }
                        
                        // Section 2: Actions
                        VStack(alignment: .leading, spacing: 10) {
                            Text("UNFOLD CONTROLS")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_secondary)
                                .tracking(0.5)
                            
                            Button("Unfold Selected Face") {
                                if let first = state.selectedFaces3D.first {
                                    state.unfoldFace(bodyIndex: first.bodyIndex, faceIndex: first.faceIndex)
                                }
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: state.selectedFaces3D.count == 1))
                            .disabled(state.selectedFaces3D.count != 1)
                            .help("Unfolds a single selected face and opens it in 2D Editor.")
                            
                            Button("Unfold All Selected") {
                                state.unfoldAllSelected()
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedFaces3D.isEmpty))
                            .disabled(state.selectedFaces3D.isEmpty)
                            .help("Unfolds all selected faces and places them side-by-side in 2D Editor.")
                        }
                        
                        Divider().background(Color.border_subtle)
                        
                        // Section 3: Sketch Projection
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PROJECTION SKETCH")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_secondary)
                                .tracking(0.5)
                            
                            Picker("Projection Plane", selection: $selectedPlane) {
                                Text("XY Plane").tag("XY")
                                Text("XZ Plane").tag("XZ")
                                Text("YZ Plane").tag("YZ")
                                Text("Parallel to Face").tag("face")
                            }
                            .pickerStyle(DefaultPickerStyle())
                            .labelsHidden()
                            
                            Button("Project to 2D Sketch") {
                                state.projectToSketch(planeType: selectedPlane)
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: selectedPlane != "face" || state.selectedFaces3D.count == 1))
                            .disabled(selectedPlane == "face" && state.selectedFaces3D.count != 1)
                            .help("Projects all body lines onto the selected axis plane or parallel to the selected face.")
                        }
                    }
                    .padding(14)
                }
            }
            .frame(width: 240)
            .background(Color.bg_panel)
            .border(Color.border_subtle, width: 1)
        }
        .background(Color.bg_base)
    }
}
