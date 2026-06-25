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
                    materialToken: state.constructMaterialToken,
                    decalToken: state.constructDecalToken,
                    homeToken: state.triggerConstructHomeToken,
                    state: state
                )
                // Always-on "what does this tool do, what do I click next" banner —
                // the single biggest clarity fix. Sits where the eye already is.
                toolHUD
                    .padding(12)
                if state.isBuildingConstructModel {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Building assembly…").font(PlasticityFont.label)
                    }
                    .padding(8)
                    .background(Color.bg_panel.opacity(0.9))
                    .cornerRadius(6)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

    // MARK: Tool guidance — one source of truth for "what this tool does + what to
    // click next", shown both as the viewport HUD and the inspector step card. The
    // text reacts to pending picks (e.g. first glue panel chosen) so it always
    // tells the user the *next* action, not a generic blurb.
    private struct ToolGuide { var icon: String; var name: String; var step: String }

    private var toolGuide: ToolGuide {
        switch state.constructTool {
        case .select:
            return ToolGuide(icon: "cursorarrow", name: "Select",
                             step: "Drag to orbit. Click a fold line to adjust its angle.")
        case .fold:
            if let id = state.selectedFoldId, state.constructFolds.contains(where: { $0.id == id }) {
                return ToolGuide(icon: "arrow.uturn.up", name: "Fold",
                                 step: "Drag the angle slider in the panel → to fold. Or click another fold line.")
            }
            return ToolGuide(icon: "arrow.uturn.up", name: "Fold",
                             step: "Click a fold line on the model, then set its angle in the panel →.")
        case .crease:
            return ToolGuide(icon: "scribble.variable", name: "Crease",
                             step: "Click a start point, then an end point across a panel — the dashed preview becomes a new fold.")
        case .ground:
            return ToolGuide(icon: "square.grid.3x3.fill.square", name: "Ground",
                             step: "Click the panel that should stay flat as the base. (Now: panel \(state.constructGroundPanel).)")
        case .stitch:
            if let pick = state.selectedChainForStitch {
                return ToolGuide(icon: "point.topleft.down.to.point.bottomright.curvepath", name: "Stitch",
                                 step: "Chain \(pick) picked — click the chain to sew it to.")
            }
            return ToolGuide(icon: "point.topleft.down.to.point.bottomright.curvepath", name: "Stitch",
                             step: "Click one row of sewing holes, then the row to sew it to.")
        case .glue:
            if let p = state.selectedPanelForGlue {
                return ToolGuide(icon: "link", name: "Glue",
                                 step: "Panel \(p) picked — click the panel to glue it to.")
            }
            return ToolGuide(icon: "link", name: "Glue",
                             step: "Click two panels in turn to weld their meeting edges (glue tabs).")
        }
    }

    private var toolHUD: some View {
        let g = toolGuide
        return HStack(spacing: 10) {
            Image(systemName: g.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.name).font(PlasticityFont.label.weight(.semibold)).foregroundColor(.text_primary)
                Text(g.step).font(PlasticityFont.label).foregroundColor(.text_secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.bg_panel.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accent.opacity(0.35), lineWidth: 1))
        )
        .frame(maxWidth: 360, alignment: .leading)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    private var stepCard: some View {
        let g = toolGuide
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: g.icon).font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.name.uppercased()).font(PlasticityFont.label.weight(.semibold))
                    .foregroundColor(.text_primary).tracking(1)
                Text(g.step).font(PlasticityFont.label).foregroundColor(.text_secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accent.opacity(0.30), lineWidth: 1))
        .padding(.top, 12)
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
                    // Mirror the viewport HUD so the active tool's controls below
                    // have an obvious header tying icon → name → next step.
                    stepCard

                    Button {
                        state.buildConstructModel()
                    } label: {
                        HStack { Image(systemName: "arrow.triangle.2.circlepath"); Text("Rebuild from sketch") }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: true))

                    groundSection
                    foldSection
                    seamSection
                    glueSection
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
            if state.constructFolds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No fold lines yet. Two ways to add them:")
                        .font(PlasticityFont.label).foregroundColor(.text_secondary)
                    Text("• In 2D: draw a LINE, then move it to a layer named FOLD or CREASE (Layers panel). Back here, press Rebuild.")
                        .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.85))
                    Text("• In 3D: pick the Crease tool and click two points across a panel.")
                        .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.85))
                }
            } else {
                ForEach(state.constructFolds) { spec in
                    foldRow(spec)
                }
            }
            if state.constructTool == .crease {
                Text("Crease tool — click a start point, then an end point across the panel. A dashed line previews it; the second click commits the fold and selects it so you can set its angle here.")
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

            Divider().background(Color.border_subtle).padding(.vertical, 2)
            artworkSection
        }
    }

    // MARK: Artwork — drop an image, then frame it (move / scale / spin / flip)

    @ViewBuilder
    private var artworkSection: some View {
        Text("Artwork").font(PlasticityFont.label).foregroundColor(.text_secondary).tracking(1)
        Text("Drop an image (PNG/JPG) onto a panel to add it as artwork — visual only, it rides the fold and never changes the cut pattern.")
            .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.8))

        if !state.constructDecals.isEmpty {
            // Which panel's art are we framing? Auto-targets the last drop; a
            // picker switches when several panels carry art.
            let pids = state.constructDecals.keys.sorted()
            let active = state.activeDecalPanel.flatMap { pids.contains($0) ? $0 : nil } ?? pids.first
            if pids.count > 1, let active {
                Picker("", selection: Binding(
                    get: { active },
                    set: { state.activeDecalPanel = $0 })) {
                    ForEach(pids, id: \.self) { Text("Panel \($0)").tag($0) }
                }
                .pickerStyle(.menu).controlSize(.small).labelsHidden()
            }
            if let pid = active { decalFraming(pid) }

            Button { state.clearConstructDecals() } label: {
                HStack { Image(systemName: "trash"); Text("Clear all artwork (\(state.constructDecals.count))") }
                    .font(PlasticityFont.label)
            }
            .buttonStyle(.plain).foregroundColor(.text_secondary)
        }
    }

    @ViewBuilder
    private func decalFraming(_ pid: Int) -> some View {
        let x = state.decalXform(pid)
        VStack(alignment: .leading, spacing: 6) {
            Text("Framing — panel \(pid)").font(PlasticityFont.label.weight(.semibold))
                .foregroundColor(.text_primary)
            framingSlider("Position X", value: x[0], range: -1...1) { state.setDecalXform(pid, 0, $0) }
            framingSlider("Position Y", value: x[1], range: -1...1) { state.setDecalXform(pid, 1, $0) }
            framingSlider("Scale", value: x[2], range: 0.2...3) { state.setDecalXform(pid, 2, $0) }
            framingSlider("Rotation", value: x[3], range: -180...180, unit: "°") { state.setDecalXform(pid, 3, $0) }
            Toggle(isOn: Binding(
                get: { x[4] > 0.5 },
                set: { state.setDecalXform(pid, 4, $0 ? 1 : 0) })) {
                Text("Flip side (mirror)").font(PlasticityFont.label).foregroundColor(.text_secondary)
            }
            .toggleStyle(.switch).controlSize(.mini)
            Button { state.clearConstructDecal(pid) } label: {
                HStack { Image(systemName: "xmark.circle"); Text("Remove from panel \(pid)") }
                    .font(PlasticityFont.label)
            }
            .buttonStyle(.plain).foregroundColor(.text_secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.bg_selected.opacity(0.5)))
    }

    private func framingSlider(_ label: String, value: Double, range: ClosedRange<Double>,
                               unit: String = "", onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(PlasticityFont.label).foregroundColor(.text_secondary)
                Spacer()
                Text(unit == "°" ? "\(Int(value))\(unit)" : String(format: "%.2f", value))
                    .font(PlasticityFont.label.monospacedDigit()).foregroundColor(.text_secondary)
            }
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range)
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
