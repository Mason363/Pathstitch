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

/// Caption + control on one line — keeps the right panel reading like a
/// settings form instead of a stack of anonymous pickers.
struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)
                .frame(width: 52, alignment: .leading)
            content
        }
    }
}

struct ThreeDModeView: View {
    @Bindable var state: AppState
    @State private var selectedPlane: String = "XY"
    @State private var netLayout: String = "connected"
    @State private var netMode: String = "radial"
    @State private var netDecoration: String = "none"
    
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
                isPlaneSelectionActive: state.isPlaneSelectionActive,
                planeSelectionModeType: state.planeSelectionModeType,
                selectedProjectionPlane: state.selectedProjectionPlane,
                selectedProjectionFaceIndex: state.selectedProjectionFaceIndex,
                selectedProjectionBodyIndex: state.selectedProjectionBodyIndex,
                planeOffset: state.planeOffset,
                threeDOrthographic: state.threeDOrthographic,
                triggerCameraAnimationToken: state.triggerCameraAnimationToken,
                triggerHomeFrameToken: state.triggerHomeFrameToken,
                bodyMoveToolActive: state.bodyMoveToolActive,
                selectedBodyIndex: state.selectedBodyIndex,
                bodyOffsetsJSON: state.bodyOffsetsJSON,
                bodyMoveStateToken: state.bodyMoveStateToken,
                state: state
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bg_base)
                .overlay(alignment: .topTrailing) {
                    Button(action: { state.frameHome3D() }) {
                        Image(systemName: "house")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.text_primary)
                            .frame(width: 30, height: 30)
                            .background(Color.bg_panel.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.border_subtle, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Home — frame the model with optimal framing")
                    .padding(12)
                }
            
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

                        // Section 1.5: Move Bodies (MAS-125)
                        moveBodiesSection

                        // Section 2: Unfolding (one section, one mental model:
                        // pick how pieces come out, then unfold)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("UNFOLD")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_secondary)
                                .tracking(0.5)

                            SettingRow(label: "Layout") {
                                Picker("Layout", selection: $netLayout) {
                                    Text("Connected Net").tag("connected")
                                    Text("Separate Pieces").tag("separate")
                                }
                                .pickerStyle(DefaultPickerStyle())
                                .labelsHidden()
                                .help("Connected Net keeps faces joined at fold lines; Separate Pieces flattens each face on its own.")
                            }

                            if netLayout == "connected" {
                                SettingRow(label: "Unroll") {
                                    Picker("Unroll Mode", selection: $netMode) {
                                        Text("Radial").tag("radial")
                                        Text("Strip").tag("strip")
                                        Text("Spanning Tree").tag("spanning")
                                    }
                                    .pickerStyle(DefaultPickerStyle())
                                    .labelsHidden()
                                    .help("How faces unroll around the anchor: outward rings, long strips, or the most stable fold edges.")
                                }

                                SettingRow(label: "Seams") {
                                    Picker("Seam Decoration", selection: $netDecoration) {
                                        Text("Plain").tag("none")
                                        Text("Glue Tabs").tag("tabs")
                                        Text("Sew Holes").tag("holes")
                                    }
                                    .pickerStyle(DefaultPickerStyle())
                                    .labelsHidden()
                                    .help("Added along every mated seam pair. Sizes come from the Add Holes / Glue Tab tool settings.")
                                }
                            }

                            Button("Unfold Selected") {
                                if netLayout == "connected" {
                                    state.unfoldConnected(wholeBody: false, mode: netMode, decoration: netDecoration)
                                } else {
                                    state.unfoldAllSelected()
                                }
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedFaces3D.isEmpty))
                            .disabled(state.selectedFaces3D.isEmpty)
                            .help(netLayout == "connected"
                                  ? "Unfolds the selected faces as one connected net — shared edges become dashed fold lines, cuts become seams."
                                  : "Flattens each selected face and places them side-by-side in the 2D editor.")

                            if netLayout == "connected" {
                                Button("Unfold Entire Body") {
                                    state.unfoldConnected(wholeBody: true, mode: netMode, decoration: netDecoration)
                                }
                                .buttonStyle(PlasticityButtonStyle(isEnabled: !state.bodies3D.isEmpty))
                                .disabled(state.bodies3D.isEmpty)
                                .help("Unfolds every face of every body into connected nets.")
                            }

                            if state.selectedFaces3D.isEmpty {
                                Text("Select faces in the list or viewport (⇧-click for multiple).")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_muted)
                            }
                        }

                        Divider().background(Color.border_subtle)

                        // Section 3: Sketch Projection
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PROJECTION SKETCH")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_secondary)
                                .tracking(0.5)

                            if !state.isPlaneSelectionActive {
                                Button("Add Plane") {
                                    state.startPlaneSelection()
                                }
                                .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                                .help("Enter Plane Selection Mode to define a projection plane.")
                            } else {
                                Picker("Define Plane By", selection: $state.planeSelectionModeType) {
                                    Text("Origin Planes").tag("origin")
                                    Text("Shape Face").tag("face")
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .labelsHidden()
                                .onChange(of: state.planeSelectionModeType) { oldValue, newValue in
                                    // Reset selected plane and offset when switching modes
                                    state.selectedProjectionPlane = nil
                                    state.selectedProjectionFaceIndex = nil
                                    state.selectedProjectionBodyIndex = nil
                                    state.planeOffset = 0.0
                                }
                                
                                if state.planeSelectionModeType == "origin" {
                                    Text("Click an origin plane square (XY, YZ, ZX) in the 3D viewport.")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_muted)
                                    
                                    if let plane = state.selectedProjectionPlane {
                                        Text("Selected: \(plane) Plane")
                                            .font(PlasticityFont.body)
                                            .foregroundColor(Color.accent)
                                    } else {
                                        Text("Selected: None")
                                            .font(PlasticityFont.body)
                                            .foregroundColor(Color.text_muted)
                                    }
                                } else {
                                    Text("Click a flat face of the 3D model in the viewport.")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_muted)
                                    
                                    if let faceIdx = state.selectedProjectionFaceIndex, let bodyIdx = state.selectedProjectionBodyIndex {
                                        Text("Selected Face: B\(bodyIdx + 1) : F\(faceIdx)")
                                            .font(PlasticityFont.body)
                                            .foregroundColor(Color.accent)
                                    } else {
                                        Text("Selected: None")
                                            .font(PlasticityFont.body)
                                            .foregroundColor(Color.text_muted)
                                    }
                                }
                                
                                if state.selectedProjectionPlane != nil {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Offset (mm)")
                                            .font(PlasticityFont.label)
                                            .foregroundColor(Color.text_secondary)
                                        
                                        TextField("", value: $state.planeOffset, format: .number)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                            .labelsHidden()
                                    }
                                    .padding(.top, 4)
                                    
                                    Button("Confirm Projection") {
                                        state.confirmPlaneProjection()
                                    }
                                    .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                                    .help("Lock this plane position and project 3D silhouettes onto it.")
                                }
                                
                                Button("Cancel") {
                                    state.cancelPlaneSelection()
                                }
                                .buttonStyle(PlainButtonStyle())
                                .foregroundColor(Color.text_secondary)
                                .font(PlasticityFont.body)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(Color.bg_input.opacity(0.5))
                                .cornerRadius(4)
                            }
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

    // MARK: - Move Bodies (MAS-125)

    /// Binding to one axis of the selected body's move offset; writes through
    /// `setBodyOffset` so the viewport gizmo and the doc dirty-flag stay in sync.
    private func bodyOffsetBinding(_ axis: Int) -> Binding<Double> {
        Binding(
            get: { state.selectedBodyOffset[axis] },
            set: { newVal in
                guard let i = state.selectedBodyIndex else { return }
                var o = state.selectedBodyOffset
                o[axis] = newVal
                state.setBodyOffset(index: i, x: o[0], y: o[1], z: o[2])
            }
        )
    }

    @ViewBuilder
    private var moveBodiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MOVE BODIES")
                .font(PlasticityFont.header)
                .foregroundColor(Color.text_secondary)
                .tracking(0.5)

            Toggle("Move Tool", isOn: Binding(
                get: { state.bodyMoveToolActive },
                set: { on in if on != state.bodyMoveToolActive { state.toggleBodyMoveTool() } }
            ))
            .toggleStyle(.switch)
            .font(PlasticityFont.body)
            .foregroundColor(Color.text_primary)
            .help("Select a body in the viewport, then drag the 3D gizmo or type exact offsets.")

            if state.bodyMoveToolActive {
                if let bi = state.selectedBodyIndex,
                   let body = state.bodies3D.first(where: { $0.body_index == bi }) {
                    Text("Selected: \(body.name)")
                        .font(PlasticityFont.body)
                        .foregroundColor(Color.accent)

                    SettingRow(label: "X (mm)") {
                        TextField("", value: bodyOffsetBinding(0), format: .number)
                            .textFieldStyle(RoundedBorderTextFieldStyle()).labelsHidden()
                    }
                    SettingRow(label: "Y (mm)") {
                        TextField("", value: bodyOffsetBinding(1), format: .number)
                            .textFieldStyle(RoundedBorderTextFieldStyle()).labelsHidden()
                    }
                    SettingRow(label: "Z (mm)") {
                        TextField("", value: bodyOffsetBinding(2), format: .number)
                            .textFieldStyle(RoundedBorderTextFieldStyle()).labelsHidden()
                    }

                    SettingRow(label: "Step") {
                        TextField("", value: $state.bodyMoveStep, format: .number)
                            .textFieldStyle(RoundedBorderTextFieldStyle()).labelsHidden()
                    }
                    .help("Distance for the precise nudge buttons.")

                    HStack(spacing: 4) {
                        ForEach(Array(["X", "Y", "Z"].enumerated()), id: \.offset) { idx, axis in
                            Button("-\(axis)") { nudgeBody(bi, axis: idx, dir: -1) }
                                .buttonStyle(BorderedButtonStyle()).controlSize(.small)
                            Button("+\(axis)") { nudgeBody(bi, axis: idx, dir: 1) }
                                .buttonStyle(BorderedButtonStyle()).controlSize(.small)
                        }
                    }

                    Button("Reset Position") {
                        state.setBodyOffset(index: bi, x: 0, y: 0, z: 0)
                    }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                    .help("Return this body to its distributed home position.")
                } else {
                    Text("Click a body in the viewport to select it.")
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_muted)
                }
            } else {
                Text("Enable to select bodies and move them with a 3D gizmo.")
                    .font(PlasticityFont.label)
                    .foregroundColor(Color.text_muted)
            }

            Divider().background(Color.border_subtle)
        }
    }

    private func nudgeBody(_ index: Int, axis: Int, dir: Double) {
        var o = state.selectedBodyOffset
        o[axis] += dir * state.bodyMoveStep
        state.setBodyOffset(index: index, x: o[0], y: o[1], z: o[2])
    }
}
