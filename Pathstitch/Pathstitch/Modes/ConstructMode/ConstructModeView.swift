import SwiftUI

/// Construct mode UI: the interactive 3D assembly viewport on the left and an
/// inspector on the right (rebuild-from-sketch, ground, per-fold angle sliders,
/// solver-quality readout). The fold/stitch math runs in the viewport; this
/// view just drives the controls on `AppState`.
struct ConstructModeView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ConstructViewport(
                    modelToken: state.constructModelToken,
                    foldStateToken: state.constructFoldStateToken,
                    seamStateToken: state.constructSeamStateToken,
                    toolToken: state.constructToolToken,
                    brushToken: state.constructBrushToken,
                    materialToken: state.constructMaterialToken,
                    homeToken: state.triggerConstructHomeToken,
                    state: state
                )
                if state.isBuildingConstructModel {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Building assembly…").font(PlasticityFont.label)
                    }
                    .padding(8)
                    .background(Color.bg_panel.opacity(0.9))
                    .cornerRadius(6)
                    .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            inspector
                .frame(width: 280)
                .background(Color.bg_panel)
                .border(Color.border_subtle, width: 1)
        }
        .onAppear {
            // Re-fold from the *current* sketch each time we enter the mode, so
            // edits made in 2D show up here — the "live sketch" promise.
            state.buildConstructModel()
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Construct").font(PlasticityFont.header).foregroundColor(.text_primary)
                Spacer()
                Button { state.constructHome() } label: {
                    Image(systemName: "house").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(.text_secondary).help("Recenter view")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)

            Divider().background(Color.border_subtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        state.buildConstructModel()
                    } label: {
                        HStack { Image(systemName: "arrow.triangle.2.circlepath"); Text("Rebuild from sketch") }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                    .padding(.top, 12)

                    groundSection
                    foldSection
                    seamSection
                    glueSection
                    dragSection
                    materialSection
                    stretchSection
                }
                .padding(14)
            }
            Spacer()
        }
    }

    private var groundSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Ground")
            Text("Panel \(state.constructGroundPanel) is pinned to the ground plane.")
                .font(PlasticityFont.label).foregroundColor(.text_secondary)
            Text("Pick the Ground tool, then click another panel to re-pin.")
                .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.7))
        }
    }

    private var foldSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Folds")
            // Fold softness — real leather bends over a radius, not a knife crease.
            HStack {
                Text("Stiffness").font(PlasticityFont.label).foregroundColor(.text_secondary)
                Spacer()
                Text(state.constructStiffness > 0.85 ? "Crisp"
                     : state.constructStiffness < 0.35 ? "Soft" : "Medium")
                    .font(PlasticityFont.label).foregroundColor(.text_secondary)
            }
            Slider(
                value: Binding(
                    get: { state.constructStiffness },
                    set: { state.setConstructStiffness($0) }),
                in: 0...1, step: 0.05
            )
            .controlSize(.small)
            if state.constructFolds.isEmpty {
                Text("No fold lines detected. Draw fold lines on a layer named FOLD (or CREASE) in 2D, or use the Crease tool to add them in 3D.")
                    .font(PlasticityFont.label).foregroundColor(.text_secondary)
            } else {
                ForEach(state.constructFolds) { spec in
                    foldRow(spec)
                }
            }
            if state.constructTool == .crease {
                Text("Crease tool — click two points on a panel to add a fold line.")
                    .font(PlasticityFont.label).foregroundColor(.accent)
            }
            if !state.constructUserFolds.isEmpty {
                Button { state.undoLastUserFold() } label: {
                    HStack { Image(systemName: "arrow.uturn.backward"); Text("Undo added fold (\(state.constructUserFolds.count))") }
                        .font(PlasticityFont.label)
                }
                .buttonStyle(.plain).foregroundColor(.text_secondary)
            }
        }
    }

    // MARK: Glue (weld) joints — for glue-tab construction

    private var glueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Glue")
            if state.constructTool == .glue {
                if let p = state.selectedPanelForGlue {
                    Text("Panel \(p) selected — click another panel to glue them.")
                        .font(PlasticityFont.label).foregroundColor(.accent)
                } else {
                    Text("Glue tool — click two panels to weld their meeting edges.")
                        .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.8))
                }
            } else {
                Button { state.setConstructTool(.glue) } label: {
                    HStack { Image(systemName: ConstructTool.glue.icon); Text("Glue panels") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PlasticityButtonStyle(isEnabled: true))
            }
            ForEach(state.constructGlues) { g in
                HStack {
                    Text("Panel \(g.panelA) ⊕ \(g.panelB)").font(PlasticityFont.label).foregroundColor(.text_primary)
                    Spacer()
                    Button { state.removeGlue(g.id) } label: { Image(systemName: "xmark.circle").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundColor(.text_secondary)
                }
            }
        }
    }

    private func foldRow(_ spec: FoldSpec) -> some View {
        let selected = state.selectedFoldId == spec.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Panel \(spec.panelId) · Fold \(spec.foldId)")
                    .font(PlasticityFont.label)
                    .foregroundColor(selected ? .accent : .text_primary)
                Spacer()
                Text("\(Int(spec.angleDeg))°")
                    .font(PlasticityFont.label.monospacedDigit())
                    .foregroundColor(.text_secondary)
            }
            Slider(
                value: Binding(
                    get: { spec.angleDeg },
                    set: { state.setConstructFoldAngle(spec.id, $0) }
                ),
                in: -180...180, step: 1
            )
            .controlSize(.small)
        }
        .padding(6)
        .background(selected ? Color.bg_selected : Color.clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture { state.selectedFoldId = spec.id }
    }

    // MARK: Stitch flagship — seams between sewing-hole chains

    private var seamSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Seams")
            if state.constructHoleChains.isEmpty {
                Text("No sewing holes found. Add holes in 2D (Sewing Holes), then Rebuild — each run of holes becomes a chain you can stitch.")
                    .font(PlasticityFont.label).foregroundColor(.text_secondary)
            } else {
                Text("\(state.constructHoleChains.count) hole chains detected.")
                    .font(PlasticityFont.label).foregroundColor(.text_secondary)

                // Stitch tool prompt + pending pick state.
                if state.constructTool == .stitch {
                    if let pick = state.selectedChainForStitch {
                        Text("Chain \(pick) selected — click another chain to sew them.")
                            .font(PlasticityFont.label).foregroundColor(.accent)
                    } else {
                        Text("Stitch tool active — click a hole chain in the viewport to start.")
                            .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.8))
                    }
                } else {
                    Button {
                        state.setConstructTool(.stitch)
                    } label: {
                        HStack { Image(systemName: ConstructTool.stitch.icon); Text("Stitch chains") }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                }

                if !state.constructSeams.isEmpty {
                    Toggle(isOn: Binding(
                        get: { state.constructShowThread },
                        set: { state.setConstructShowThread($0) })) {
                        Text("Show thread").font(PlasticityFont.label).foregroundColor(.text_secondary)
                    }
                    .toggleStyle(.switch).controlSize(.mini)

                    ForEach(state.constructSeams) { seam in
                        seamRow(seam)
                    }
                }
            }
        }
    }

    private func seamRow(_ seam: StitchSeam) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Chain \(seam.chainA) → \(seam.chainB)")
                    .font(PlasticityFont.label).foregroundColor(.text_primary)
                Spacer()
                Button { state.removeSeam(seam.id) } label: {
                    Image(systemName: "scissors").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(.text_secondary).help("Unstitch")
            }

            // Mismatch readout + warning when the two seams differ in length.
            HStack(spacing: 6) {
                Text(String(format: "%.0f vs %.0f mm", seam.lenA, seam.lenB))
                    .font(PlasticityFont.label.monospacedDigit())
                    .foregroundColor(.text_secondary)
                Spacer()
                Text(String(format: "%.0f%% mismatch", seam.mismatch * 100))
                    .font(PlasticityFont.label.monospacedDigit())
                    .foregroundColor(seam.hasWarning ? .orange : .text_secondary)
            }
            if seam.hasWarning {
                Text("Seams differ by \(Int(seam.mismatch * 100))% — eased (gathered). Switch to Deform to Fit to stretch them flush, or fix hole spacing in 2D.")
                    .font(PlasticityFont.label).foregroundColor(.orange.opacity(0.9))
            }

            // Mismatch policy.
            Picker("", selection: Binding(
                get: { seam.mode },
                set: { state.setSeamMode(seam.id, $0) })) {
                ForEach(StitchMode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            Text(seam.mode.blurb)
                .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.7))
        }
        .padding(6)
        .background(Color.bg_selected.opacity(0.5))
        .cornerRadius(5)
    }

    // MARK: Drag brush — pose / drape the form without stretching

    private var dragSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Drag brush")
            if state.constructTool == .drag {
                Text("Drag on a panel to pose it. The base stays put; the leather bends but never stretches.")
                    .font(PlasticityFont.label).foregroundColor(.text_secondary)
            } else {
                Button {
                    state.setConstructTool(.drag)
                } label: {
                    HStack { Image(systemName: ConstructTool.drag.icon); Text("Drag brush") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PlasticityButtonStyle(isEnabled: true))
            }
            HStack {
                Text("Radius").font(PlasticityFont.label).foregroundColor(.text_secondary)
                Spacer()
                Text("\(Int(state.constructBrushRadius)) mm")
                    .font(PlasticityFont.label.monospacedDigit()).foregroundColor(.text_secondary)
            }
            Slider(
                value: Binding(
                    get: { state.constructBrushRadius },
                    set: { state.setConstructBrushRadius($0) }),
                in: 5...120, step: 1
            )
            .controlSize(.small)
            Button { state.resetConstructDrape() } label: {
                HStack { Image(systemName: "arrow.uturn.backward"); Text("Reset drape") }
                    .font(PlasticityFont.label)
            }
            .buttonStyle(.plain).foregroundColor(.text_secondary)
        }
    }

    // MARK: Mockup material — leather colour + thickness

    private let leatherSwatches: [(String, String)] = [
        ("8A5A2B", "Tan"), ("4A2F1B", "Dark brown"), ("C9A36A", "Natural"),
        ("3A2418", "Espresso"), ("7C1E1E", "Oxblood"), ("1C1C1E", "Black")
    ]

    private var materialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Material")
            HStack(spacing: 8) {
                ForEach(leatherSwatches, id: \.0) { hex, name in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(state.constructMaterialHex.caseInsensitiveCompare(hex) == .orderedSame ? Color.accent : Color.border_subtle, lineWidth: 2))
                        .onTapGesture { state.setConstructMaterialColor(hex) }
                        .help(name)
                }
            }
            HStack {
                Text("Thickness").font(PlasticityFont.label).foregroundColor(.text_secondary)
                Spacer()
                Text(String(format: "%.1f mm", state.constructThicknessMm))
                    .font(PlasticityFont.label.monospacedDigit()).foregroundColor(.text_secondary)
            }
            Slider(
                value: Binding(
                    get: { state.constructThicknessMm },
                    set: { state.setConstructThickness($0) }),
                in: 0.5...8, step: 0.1
            )
            .controlSize(.small)
        }
    }

    private var stretchSection: some View {
        let pct = state.constructMaxStretchPct
        return VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Solver")
            HStack {
                Text("Max stretch").font(PlasticityFont.label).foregroundColor(.text_secondary)
                Spacer()
                Text(String(format: "%.2f%%", pct))
                    .font(PlasticityFont.label.monospacedDigit())
                    .foregroundColor(pct < 1 ? .green : .orange)
            }
            Text("Leather is inextensible — this should stay near 0%.")
                .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.7))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(PlasticityFont.label)
            .foregroundColor(.text_secondary)
            .tracking(1)
    }
}
