import SwiftUI

struct FaceRowView: View {
    let bodyIndex: Int
    let face: Face3D
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.on.square")
                .font(.system(size: 9))
                .foregroundColor(isSelected ? Color.to_accent : Color.to_textMut)

            Text("Face \(face.face_index)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? Color.to_accent : Color.to_textSec)

            Spacer()

            Text(face.type)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.to_card))
                .foregroundColor(Color.to_textMut)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.to_accentTint : Color.clear))
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
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("B\(sel.bodyIndex + 1) : F\(sel.faceIndex)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color.to_accent)
                Spacer()
                Text(face.type)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.to_accentTint))
                    .foregroundColor(Color.to_textSec)
            }
            Text("\(String(format: "%.1f", face.area)) mm²")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundColor(Color.to_textMut)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.to_field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.to_fieldBorder, lineWidth: 1))
    }
}

/// Caption + control on one line — keeps the right panel reading like a
/// settings form instead of a stack of anonymous pickers. Adaptive: drops the
/// control below the label when the panel is too narrow to fit both.
struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                TOLabel(label).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                content
            }
            VStack(alignment: .leading, spacing: 8) {
                TOLabel(label)
                content
            }
        }
    }
}

struct ThreeDModeView: View {
    @Bindable var state: AppState
    @State private var selectedPlane: String = "XY"
    
    var body: some View {
        HStack(spacing: 0) {
            // The 3D tool strip (Select / Move / Plane) lives in the app's
            // leftmost sidebar (ContentView.leftToolbar), the same place as the
            // 2D tools — not as a separate strip here.

            // Left Panel: Solid Bodies (200px wide)
            VStack(alignment: .leading, spacing: 0) {
                TOGroupLabel("Solid Bodies")
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                    .padding(.bottom, 11)

                TODivider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach($state.bodies3D) { $body in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Button(action: {
                                        body.visible.toggle()
                                    }) {
                                        Image(systemName: body.visible ? "eye" : "eye.slash")
                                            .font(.system(size: 11))
                                            .foregroundColor(body.visible ? Color.to_textSec : Color.to_textMut)
                                            .frame(width: 14, height: 14)
                                    }
                                    .buttonStyle(PlainButtonStyle())

                                    Image(systemName: "cube.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.to_accent)

                                    Text(body.name)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundColor(Color.to_textPri)
                                        .lineLimit(1)

                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 9)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.to_field))

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
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .frame(width: 200)
            .background(Color.to_panel)
            .overlay(Rectangle().fill(Color.to_panelBorder).frame(width: 1), alignment: .trailing)
            
            // Center Viewport: WKWebView wrapper
            ThreeDViewport(
                selectedFaces3D: state.selectedFaces3D,
                stepJsonContent: state.stepJsonContent,
                stepModelLoadToken: state.stepModelLoadToken,
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
                forcedSeams3D: state.forcedSeams3D,
                forbiddenSeams3D: state.forbiddenSeams3D,
                seamControlMode: state.seamControlMode,
                distortionDataJSON: state.distortionDataJSON,
                state: state
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bg_base)
                .overlay(alignment: .topTrailing) {
                    Button(action: { state.frameHome3D() }) {
                        Image(systemName: "house")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.to_textSec)
                            .frame(width: 30, height: 30)
                            .background(Color.to_panel.opacity(0.94))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.to_panelBorder, lineWidth: 1))
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
                        VStack(alignment: .leading, spacing: 10) {
                            TOGroupLabel("Selected Faces")

                            if state.selectedFaces3D.isEmpty {
                                TOStatus(color: .to_textFaint, text: "No selection",
                                         hint: "click a face in the list or viewport")
                            } else {
                                TOStatus(text: "\(state.selectedFaces3D.count) face\(state.selectedFaces3D.count == 1 ? "" : "s") in queue")

                                ForEach(Array(state.selectedFaces3D), id: \.self) { sel in
                                    if let body = state.bodies3D.first(where: { $0.body_index == sel.bodyIndex }),
                                       let face = body.faces.first(where: { $0.face_index == sel.faceIndex }) {
                                        SelectedFaceRowView(sel: sel, bodyObj: body, face: face)
                                    }
                                }
                            }
                        }

                        TODivider()

                        // Section 1.5: Move Bodies (MAS-125)
                        moveBodiesSection

                        // Section 2: Unfolding (one section, one mental model:
                        // pick how pieces come out, then unfold)
                        VStack(alignment: .leading, spacing: 12) {
                            TOGroupLabel("Unfold")

                            SettingRow(label: "Layout") {
                                TOSelect(options: [("connected", "Connected Net"), ("separate", "Separate Pieces")],
                                         selection: $state.netLayout)
                                    .help("Connected Net keeps faces joined at fold lines; Separate Pieces flattens each face on its own.")
                            }

                            SettingRow(label: "Distort") {
                                TOSelect(options: [("conformal", "Conformal"), ("equal-area", "Equal-Area"),
                                                   ("equidistant", "Equidistant"), ("balanced", "Balanced")],
                                         selection: $state.distortionMode)
                                    .help("The parameterization energy mode used to flatten curved surfaces.")
                            }

                            if state.netLayout == "connected" {
                                SettingRow(label: "Unroll") {
                                    TOSelect(options: [("radial", "Radial"), ("strip", "Strip"), ("spanning", "Spanning Tree")],
                                             selection: $state.netMode)
                                        .help("How faces unroll around the anchor: outward rings, long strips, or the most stable fold edges.")
                                }

                                SettingRow(label: "Seams") {
                                    TOSelect(options: [("none", "Plain"), ("tabs", "Glue Tabs"), ("holes", "Sew Holes")],
                                             selection: $state.netDecoration)
                                        .help("Added along every mated seam pair. Sizes come from the Add Holes / Glue Tab tool settings.")
                                }

                                SettingRow(label: "Control") {
                                    TOSelect(options: [("auto", "Auto"), ("manual", "Manual (Cuts)"), ("hybrid", "Hybrid (Folds)")],
                                             selection: $state.seamControlMode)
                                        .help("Auto uses curvature-weighted spanning tree. Manual lets you pick cuts. Hybrid lets you force creases.")
                                }

                                // Anchor face — the fixed face the net unrolls around.
                                if let anchor = state.anchorFace3D {
                                    HStack {
                                        TOStatus(text: "Anchor B\(anchor.bodyIndex + 1):F\(anchor.faceIndex)")
                                        miniButton("Reset", tint: .to_textMut) { state.anchorFace3D = nil }
                                    }
                                } else {
                                    HStack {
                                        TOStatus(color: .to_textFaint, text: "Anchor: default (largest)")
                                        if let firstSel = state.selectedFaces3D.first, state.selectedFaces3D.count == 1 {
                                            miniButton("Set selected", tint: .to_accent) { state.anchorFace3D = firstSel }
                                        }
                                    }
                                }

                                if let selectedEdge = state.selectedEdge3D {
                                    SettingRow(label: "Edge B\(selectedEdge.bodyIndex + 1):E\(selectedEdge.edgeIndex)") {
                                        TOSelect(options: [("default", "Default (global)"), ("none", "Plain (cut)"),
                                                           ("tabs", "Glue Tab"), ("holes", "Sew Holes")],
                                                 selection: Binding(
                                                    get: { state.seamDecorations3D[selectedEdge] ?? "default" },
                                                    set: { newVal in
                                                        if newVal == "default" {
                                                            state.seamDecorations3D.removeValue(forKey: selectedEdge)
                                                        } else {
                                                            state.seamDecorations3D[selectedEdge] = newVal
                                                        }
                                                    }))
                                    }
                                }

                                if state.seamControlMode == "manual" && !state.forcedSeams3D.isEmpty {
                                    TOSecondaryButton(title: "Clear manual cuts", icon: "xmark") {
                                        state.forcedSeams3D.removeAll()
                                    }
                                } else if state.seamControlMode == "hybrid" && !state.forbiddenSeams3D.isEmpty {
                                    TOSecondaryButton(title: "Clear forced folds", icon: "xmark") {
                                        state.forbiddenSeams3D.removeAll()
                                    }
                                }
                            }

                            TOCheck(label: "Live recompute",
                                    isOn: $state.liveRecomputeEnabled) {
                                if state.liveRecomputeEnabled {
                                    state.wholeBodyRecompute = false
                                    state.triggerLiveRecompute()
                                }
                            }

                            TOPrimaryButton(title: "Unfold Selected",
                                            enabled: !state.selectedFaces3D.isEmpty) {
                                if state.netLayout == "connected" {
                                    state.unfoldConnected(wholeBody: false, mode: state.netMode, decoration: state.netDecoration)
                                } else {
                                    state.unfoldAllSelected()
                                }
                            }
                            .help(state.netLayout == "connected"
                                  ? "Unfolds the selected faces as one connected net — shared edges become dashed fold lines, cuts become seams."
                                  : "Flattens each selected face and places them side-by-side in the 2D editor.")

                            if state.netLayout == "connected" {
                                TOSecondaryButton(title: "Unfold Entire Body", icon: "square.on.square",
                                                  enabled: !state.bodies3D.isEmpty) {
                                    state.wholeBodyRecompute = true
                                    state.unfoldConnected(wholeBody: true, mode: state.netMode, decoration: state.netDecoration)
                                }
                                .help("Unfolds every face of every body into connected nets.")
                            }

                            if state.selectedFaces3D.isEmpty {
                                TOHint("Select faces in the list or viewport (⇧-click for multiple).")
                            }
                        }

                        TODivider()

                        // Section 3: Sketch Projection
                        VStack(alignment: .leading, spacing: 12) {
                            TOGroupLabel("Projection Sketch")

                            if !state.isPlaneSelectionActive {
                                TOPrimaryButton(title: "Add Plane") {
                                    state.startPlaneSelection()
                                }
                                .help("Enter Plane Selection Mode to define a projection plane.")
                            } else {
                                TOSegmented(options: [("origin", "Origin Planes"), ("face", "Shape Face")],
                                            selection: $state.planeSelectionModeType) {
                                    // Reset selected plane and offset when switching modes
                                    state.selectedProjectionPlane = nil
                                    state.selectedProjectionFaceIndex = nil
                                    state.selectedProjectionBodyIndex = nil
                                    state.planeOffset = 0.0
                                }
                                .frame(maxWidth: .infinity)

                                if state.planeSelectionModeType == "origin" {
                                    TOHint("Click an origin plane square (XY, YZ, ZX) in the 3D viewport.")
                                    if let plane = state.selectedProjectionPlane {
                                        TOStatus(text: "Selected: \(plane) plane")
                                    } else {
                                        TOStatus(color: .to_textFaint, text: "Selected: none")
                                    }
                                } else {
                                    TOHint("Click a flat face of the 3D model in the viewport.")
                                    if let faceIdx = state.selectedProjectionFaceIndex, let bodyIdx = state.selectedProjectionBodyIndex {
                                        TOStatus(text: "Selected face B\(bodyIdx + 1):F\(faceIdx)")
                                    } else {
                                        TOStatus(color: .to_textFaint, text: "Selected: none")
                                    }
                                }

                                if state.selectedProjectionPlane != nil {
                                    SettingRow(label: "Offset") {
                                        TOStepper(value: $state.planeOffset, unit: "mm", step: 1,
                                                  range: -100000...100000, maxFrac: 2)
                                    }
                                    TOPrimaryButton(title: "Confirm Projection") {
                                        state.confirmPlaneProjection()
                                    }
                                    .help("Lock this plane position and project 3D silhouettes onto it.")
                                }

                                TOSecondaryButton(title: "Cancel", tint: .to_textMut) {
                                    state.cancelPlaneSelection()
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
            .frame(width: 240)
            .background(Color.to_panel)
            .overlay(Rectangle().fill(Color.to_panelBorder).frame(width: 1), alignment: .leading)
        }
        .background(Color.bg_base)
    }

    /// A small inline text button (Reset / Set selected) used beside status lines.
    private func miniButton(_ title: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(tint)
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
                guard o[axis] != newVal else { return }
                o[axis] = newVal
                state.beginBodyMove()   // one undo step per committed value (MAS-143)
                state.setBodyOffset(index: i, x: o[0], y: o[1], z: o[2])
            }
        )
    }

    @ViewBuilder
    private var moveBodiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TOGroupLabel("Move Bodies")

            TOCheck(label: "Move tool",
                    isOn: Binding(
                        get: { state.bodyMoveToolActive },
                        set: { on in if on != state.bodyMoveToolActive { state.toggleBodyMoveTool() } }))
                .help("Select a body in the viewport, then drag the 3D gizmo or type exact offsets.")

            if state.bodyMoveToolActive {
                if let bi = state.selectedBodyIndex,
                   let body = state.bodies3D.first(where: { $0.body_index == bi }) {
                    TOStatus(text: "Selected: \(body.name)")

                    SettingRow(label: "X") {
                        TOStepper(value: bodyOffsetBinding(0), unit: "mm", step: state.bodyMoveStep,
                                  range: -100000...100000, maxFrac: 2)
                    }
                    SettingRow(label: "Y") {
                        TOStepper(value: bodyOffsetBinding(1), unit: "mm", step: state.bodyMoveStep,
                                  range: -100000...100000, maxFrac: 2)
                    }
                    SettingRow(label: "Z") {
                        TOStepper(value: bodyOffsetBinding(2), unit: "mm", step: state.bodyMoveStep,
                                  range: -100000...100000, maxFrac: 2)
                    }

                    SettingRow(label: "Step") {
                        TOStepper(value: $state.bodyMoveStep, unit: "mm", step: 1,
                                  range: 0.1...1000, maxFrac: 2)
                    }
                    .help("Distance for the precise nudge buttons.")

                    // Precise per-axis nudges by the Step amount.
                    HStack(spacing: 4) {
                        ForEach(Array(["X", "Y", "Z"].enumerated()), id: \.offset) { idx, axis in
                            miniAxisButton("−\(axis)") { nudgeBody(bi, axis: idx, dir: -1) }
                            miniAxisButton("+\(axis)") { nudgeBody(bi, axis: idx, dir: 1) }
                        }
                    }

                    TOSecondaryButton(title: "Reset position", icon: "arrow.uturn.backward") {
                        state.beginBodyMove()   // undoable (MAS-143)
                        state.setBodyOffset(index: bi, x: 0, y: 0, z: 0)
                    }
                    .help("Return this body to its distributed home position.")
                } else {
                    TOHint("Click a body in the viewport to select it.")
                }
            } else {
                TOHint("Enable to select bodies and move them with a 3D gizmo.")
            }

            TODivider()
        }
    }

    /// A compact bordered axis-nudge button (−X, +X, …) matching the field chrome.
    private func miniAxisButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundColor(.to_textSec)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.to_field))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.to_fieldBorder, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func nudgeBody(_ index: Int, axis: Int, dir: Double) {
        var o = state.selectedBodyOffset
        o[axis] += dir * state.bodyMoveStep
        state.beginBodyMove()   // each nudge is one undo step (MAS-143)
        state.setBodyOffset(index: index, x: o[0], y: o[1], z: o[2])
    }
}
