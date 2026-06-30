import SwiftUI

/// Construct mode UI: the interactive 3D assembly viewport on the left and an
/// inspector on the right (rebuild-from-sketch, ground, per-fold angle sliders,
/// solver-quality readout). The fold/stitch math runs in the viewport; this
/// view just drives the controls on `AppState`.
struct ConstructModeView: View {
    @Bindable var state: AppState

    /// Display-only settings (shading + cutting mat) are tucked into a collapsed
    /// disclosure so the inspector leads with the active tool, not view chrome.
    @State private var showDisplay = false

    /// Overlap chooser: apply the picked treatment to every undecided area at once
    /// (a whole row of holes/areas) rather than one prompt at a time.
    @State private var overlapApplyToAll = false

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
                    stampToken: state.constructStampToken,
                    baseToken: state.constructBaseToken,
                    panelXfToken: state.constructPanelXfToken,
                    transformModeToken: state.constructTransformModeToken,
                    exportToken: state.constructExportToken,
                    renderToken: state.constructRenderToken,
                    shaderToken: state.constructShaderToken,
                    matToken: state.matToken,
                    lightingToken: state.constructLightingToken,
                    textureToken: state.constructTextureToken,
                    selFoldToken: state.constructSelFoldToken,
                    artworkToken: state.constructArtworkToken,
                    artworkCmdToken: state.constructArtworkCmdToken,
                    stitchPinToken: state.constructStitchPinToken,
                    snapActive: state.snapActive,
                    homeToken: state.triggerConstructHomeToken,
                    state: state
                )
                // Always-on "what does this tool do, what do I click next" banner —
                // the single biggest clarity fix. Sits where the eye already is.
                toolHUD
                    .padding(12)
                if let first = state.pendingEngulfed.first { overlapChooser(first) }
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
                             step: "Drag to orbit. Click a fold or panel to select it. Use Fold to drag-fold.")
        case .move:
            return ToolGuide(icon: "move.3d", name: "Move",
                             step: "Click a panel, then drag the gizmo to move / rotate / scale it (pose only — never edits the 2D sketch).")
        case .fold:
            return ToolGuide(icon: "arrow.uturn.up", name: "Fold",
                             step: "Drag a flap to fold it — snaps to 15/45/90°, hold ⇧ for free. Drag empty space to orbit; the slider → fine-tunes.")
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

    // One enclosed area sits inside another — ask how to treat the inner one.
    @ViewBuilder
    private func overlapChooser(_ e: [String: String]) -> some View {
        let inner = e["inner"] ?? ""
        let count = state.pendingEngulfed.count
        return VStack(alignment: .leading, spacing: 10) {
            Text(count > 1 ? "Overlapping areas (\(count))" : "Overlapping area")
                .font(PlasticityFont.label.weight(.semibold))
                .foregroundColor(.text_primary).tracking(1)
            Text(count > 1
                 ? "\(count) areas sit inside others. How should they be treated?"
                 : "An area sits inside another. How should the inner one be treated?")
                .font(PlasticityFont.label).foregroundColor(.text_secondary)
                .fixedSize(horizontal: false, vertical: true)
            if count > 1 {
                Toggle(isOn: $overlapApplyToAll) {
                    Text("Apply my choice to all \(count) areas")
                        .font(PlasticityFont.label).foregroundColor(.text_primary)
                }
                .toggleStyle(.checkbox)
            }
            overlapOption(inner, "sew", "Sewing holes", "Treat the area as a stitch hole — joins the hole chains like any hole on the SEWING_HOLES layer.")
            overlapOption(inner, "stamp", "Decoration stamp", "Printed/tooled outline on the surface — never cut, rides the fold.")
            overlapOption(inner, "patch", "Raised patch", "A separate piece sitting on top (pocket / overlay).")
            overlapOption(inner, "cutout", "Cut-out window", "A real hole through the outer panel.")
            overlapOption(inner, "independent", "Independent panel", "Just another panel that happens to overlap in 2D.")
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.bg_panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accent.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func overlapOption(_ inner: String, _ mode: String, _ title: String, _ blurb: String) -> some View {
        Button { state.setAreaTreatment(inner: inner, mode: mode, all: overlapApplyToAll) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PlasticityFont.label.weight(.semibold)).foregroundColor(.text_primary)
                Text(blurb).font(PlasticityFont.label).foregroundColor(.text_secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.bg_selected.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Construct").font(PlasticityFont.header).foregroundColor(.text_primary)
                Spacer()
                Button { state.undoConstruct() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12))
                }
                .buttonStyle(.plain).disabled(!state.canUndoConstruct)
                .foregroundColor(state.canUndoConstruct ? .text_secondary : .text_secondary.opacity(0.3))
                .help("Undo (⌘Z)")
                Button { state.redoConstruct() } label: {
                    Image(systemName: "arrow.uturn.forward").font(.system(size: 12))
                }
                .buttonStyle(.plain).disabled(!state.canRedoConstruct)
                .foregroundColor(state.canRedoConstruct ? .text_secondary : .text_secondary.opacity(0.3))
                .help("Redo (⇧⌘Z)")
                Button { state.constructHome() } label: {
                    Image(systemName: "house").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(.text_secondary).help("Recenter view")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)

            Divider().background(Color.border_subtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Always-on overview: finished size / stitches / health + Export +
                    // Assemble. Stays put no matter which tool is active.
                    overviewStrip
                    Divider().background(Color.border_subtle)

                    // Edit ↔ Mockup. Mockup swaps the editing tools for material +
                    // lighting (presentation) controls.
                    renderModeSection

                    // Controls-first: the active tool's options lead the inspector.
                    if state.constructArtworkMode {
                        artworkPanel
                    } else if state.constructRenderMode == "mockup" {
                        materialSection
                        ConstructLightingView(state: state)
                    } else {
                        stepCard
                        toolOptions
                        stretchSection
                    }

                    // Display-only aids (shading + cutting mat), collapsed by default
                    // so they don't crowd the tool controls. Apply in Edit and Mockup.
                    Divider().background(Color.border_subtle)
                    DisclosureGroup(isExpanded: $showDisplay) {
                        VStack(alignment: .leading, spacing: 14) {
                            shadingSection
                            matSection
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("DISPLAY OPTIONS").font(PlasticityFont.label)
                            .foregroundColor(.text_secondary).tracking(1)
                    }
                }
                .padding(14)
            }
            Spacer()
        }
    }

    // MARK: Render mode — Edit (working) vs Mockup (clean beauty render)

    private let renderModes: [(String, String)] = [("edit", "Edit"), ("mockup", "Mockup")]

    private var renderModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { state.constructRenderMode },
                set: { state.setConstructRenderMode($0) })) {
                ForEach(renderModes, id: \.0) { key, label in Text(label).tag(key) }
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
        }
    }

    // MARK: Shading — how panels are drawn (independent of Edit/Mockup)

    private let shaderModes: [(String, String)] = [
        ("wireframe", "Wire"), ("solid", "Solid"), ("flat", "Flat"), ("realistic", "Realistic")
    ]

    private var shadingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SHADING").font(PlasticityFont.header).foregroundColor(.text_secondary)
            Picker("", selection: Binding(
                get: { state.constructShaderMode },
                set: { state.setConstructShaderMode($0) })) {
                ForEach(shaderModes, id: \.0) { key, label in Text(label).tag(key) }
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            Text("How panels are drawn — works in both Edit and Mockup. Realistic is the PBR leather; Wire/Solid/Flat are inspection views.")
                .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Cutting mat — finite baseplate shared with the 2D canvas

    private var matSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { state.matEnabled },
                set: { state.matEnabled = $0; state.bumpMat() })) {
                Text("Cutting mat").font(PlasticityFont.label).foregroundColor(.text_primary)
            }
            if state.matEnabled {
                HStack(spacing: 6) {
                    Text("W").font(PlasticityFont.label).foregroundColor(.text_secondary)
                    TextField("W", value: Binding(get: { state.matWidthMm },
                        set: { state.matWidthMm = $0; state.bumpMat() }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 56)
                    Text("H").font(PlasticityFont.label).foregroundColor(.text_secondary)
                    TextField("H", value: Binding(get: { state.matHeightMm },
                        set: { state.matHeightMm = $0; state.bumpMat() }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 56)
                    Text("mm").font(PlasticityFont.label).foregroundColor(.text_secondary)
                }
                Toggle(isOn: Binding(
                    get: { state.matGridVisible },
                    set: { state.matGridVisible = $0; state.bumpMat() })) {
                    Text("Show mat grid").font(PlasticityFont.label).foregroundColor(.text_primary)
                }
            }
        }
    }

    private let transformModes: [(String, String)] = [
        ("translate", "Move"), ("rotate", "Rotate"), ("scale", "Scale")
    ]

    private let finishes: [(String, String)] = [("matte", "Matte"), ("satin", "Satin"), ("glossy", "Glossy")]

    // MARK: Always-on overview strip (size / stitches / health + Assemble + Export)

    private var overviewStrip: some View {
        let h = state.assemblyHealth
        let healthy = h.ok && h.openChains == 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "%.0f × %.0f × %.0f mm",
                                state.constructFinishedW, state.constructFinishedH, state.constructFinishedD))
                        .font(PlasticityFont.label.monospacedDigit()).foregroundColor(.text_primary)
                    Text("\(state.constructStitchCount) stitches · \(String(format: "%.0f", state.constructLeatherAreaMm2 / 100)) cm² · \(state.constructReadoutPanels) panels")
                        .font(PlasticityFont.label).foregroundColor(.text_secondary)
                }
                Spacer()
                Image(systemName: healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(healthy ? .green : .orange)
                    .help(healthy ? "Everything connected, seams fit" : healthSummary(h))
            }
            HStack(spacing: 8) {
                Button { state.assembleAll() } label: {
                    HStack(spacing: 4) { Image(systemName: "shippingbox"); Text("Assemble") }
                        .font(PlasticityFont.label).frame(maxWidth: .infinity)
                }
                .buttonStyle(PlasticityButtonStyle(isEnabled: !state.constructFolds.isEmpty))
                .disabled(state.constructFolds.isEmpty)
                Menu {
                    Button("STEP (.step)") { state.exportConstruct("step") }
                    Button("STL (.stl)") { state.exportConstruct("stl") }
                } label: {
                    HStack(spacing: 4) { Image(systemName: "square.and.arrow.up"); Text("Export") }
                        .font(PlasticityFont.label)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(state.constructReadoutPanels == 0)
            }
        }
    }

    private func healthSummary(_ h: (floating: Int, openChains: Int, mismatched: Int, ok: Bool)) -> String {
        var parts: [String] = []
        if h.floating > 0 { parts.append("\(h.floating) unattached") }
        if h.mismatched > 0 { parts.append("\(h.mismatched) seam mismatch") }
        if h.openChains > 0 { parts.append("\(h.openChains) unstitched") }
        return parts.isEmpty ? "OK" : parts.joined(separator: " · ")
    }

    // MARK: Contextual tool options — only the active tool's controls

    @ViewBuilder private var toolOptions: some View {
        switch state.constructTool {
        case .select: selectSection
        case .move:   moveSection
        case .fold:   foldSection
        case .crease: creaseSection
        case .ground: groundSection
        case .stitch: seamSection
        case .glue:   glueSection
        }
    }

    private var selectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Select")
            Text("Hover highlights what you'll pick. Click a fold to set its angle, or choose a tool on the left.")
                .font(PlasticityFont.label).foregroundColor(.text_secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { state.buildConstructModel() } label: {
                HStack { Image(systemName: "arrow.triangle.2.circlepath"); Text("Rebuild from sketch") }
                    .font(PlasticityFont.label)
            }
            .buttonStyle(.plain).foregroundColor(.text_secondary)
            healthDetail
        }
    }

    private var creaseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Crease")
            Text("Click a start point, then an end point across a panel — endpoints snap to corners / edges (toggle snapping with the snap button or “n”). The new fold is written to the 2D sketch on the FOLD layer, so it's editable back in 2D.")
                .font(PlasticityFont.label).foregroundColor(.accent)
                .fixedSize(horizontal: false, vertical: true)
            if !state.constructUserFolds.isEmpty {
                Button { state.undoLastUserFold() } label: {
                    HStack { Image(systemName: "arrow.uturn.backward"); Text("Undo added fold (\(state.constructUserFolds.count))") }
                        .font(PlasticityFont.label)
                }
                .buttonStyle(.plain).foregroundColor(.text_secondary)
            }
        }
    }

    private func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c.opacity(0.65)).frame(width: 9, height: 9)
            Text(t).font(PlasticityFont.label).foregroundColor(.text_secondary)
        }
    }

    // MARK: Artwork placement panel (shown while a dropped image is being placed)

    private var artworkPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Place Artwork")
            Text(state.activeDecalPanel == nil
                 ? "Bird's-eye view — click a body to drop the image onto it."
                 : "Drag the art on the body to move it. Tune it below; click another body to place it there too.")
                .font(PlasticityFont.label).foregroundColor(.text_secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let pid = state.activeDecalPanel, state.constructDecals[pid] != nil {
                Text("Body \(pid)").font(PlasticityFont.label.weight(.semibold)).foregroundColor(.text_primary)
                HStack(spacing: 10) {
                    Button { state.artworkCommand("fill") } label: {
                        HStack(spacing: 4) { Image(systemName: "arrow.up.left.and.arrow.down.right"); Text("Fill") }.font(PlasticityFont.label)
                    }.buttonStyle(.plain).foregroundColor(.accent)
                    Button { state.artworkCommand("flipface") } label: {
                        HStack(spacing: 4) { Image(systemName: "square.on.square"); Text("Other face") }.font(PlasticityFont.label)
                    }.buttonStyle(.plain).foregroundColor(.accent)
                    Button { state.artworkCommand("mirror") } label: {
                        HStack(spacing: 4) { Image(systemName: "arrow.left.and.right"); Text("Mirror") }.font(PlasticityFont.label)
                    }.buttonStyle(.plain).foregroundColor(.accent)
                }
                let x = state.decalXform(pid)
                framingSlider("Scale", value: x[2], range: 0.2...3) { state.setDecalXform(pid, 2, $0) }
                framingSlider("Rotation", value: x[3], range: -180...180, unit: "°") { state.setDecalXform(pid, 3, $0) }
                Button { state.clearConstructDecal(pid) } label: {
                    HStack { Image(systemName: "trash"); Text("Remove from body \(pid)") }.font(PlasticityFont.label)
                }.buttonStyle(.plain).foregroundColor(.text_secondary)
            }
            Button { state.exitArtworkPlacement() } label: {
                HStack { Image(systemName: "checkmark"); Text("Done") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(PlasticityButtonStyle(isEnabled: true))
        }
    }

    private var moveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Transform")
            Text("Click a panel, then drag the gizmo. This poses the 3D object only — it never changes the 2D sketch, and edits in 2D still flow through.")
                .font(PlasticityFont.label).foregroundColor(.text_secondary)
            Picker("", selection: Binding(
                get: { state.constructTransformMode },
                set: { state.setConstructTransformMode($0) })) {
                ForEach(transformModes, id: \.0) { key, label in Text(label).tag(key) }
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            if !state.constructPanelXf.isEmpty {
                Button { state.clearConstructPanelTransforms() } label: {
                    HStack { Image(systemName: "arrow.uturn.backward"); Text("Reset poses (\(state.constructPanelXf.count))") }
                        .font(PlasticityFont.label)
                }
                .buttonStyle(.plain).foregroundColor(.text_secondary)
            }
        }
    }

    private var groundSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Ground")
            Text("Panel \(state.constructGroundPanel) is pinned to the ground plane.")
                .font(PlasticityFont.label).foregroundColor(.text_secondary)
            Text("Ground tool → click a face to pin it as the base that stays flat. On a folded panel, click the side you want flat — the rest folds relative to it.")
                .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.7))
        }
    }

    private var foldSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Folds")
            // Lead with the primary interaction (drag-to-fold); the "what is a fold
            // line" explainer follows for when there are none yet.
            Label("Drag a flap in 3D to fold it. Snaps to 15/45/90° — hold ⇧ for free.",
                  systemImage: "hand.draw")
                .font(PlasticityFont.label).foregroundColor(.accent)
                .fixedSize(horizontal: false, vertical: true)
            if state.constructFolds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No fold lines yet. Two ways to add one:")
                        .font(PlasticityFont.label).foregroundColor(.text_secondary)
                    Text("• In 2D: draw a LINE → right-click → “Make Fold Line” (or move it to a FOLD layer), then press Rebuild.")
                        .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("• In 3D: use the Crease tool below and click two points across a panel.")
                        .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(state.constructFolds) { spec in
                    foldRow(spec)
                }
                bendSummary
            }
            // Which side stays flat vs folds — shown for the selected fold, with a
            // one-click Flip. (Ground tool can also click the base face directly.)
            if let id = state.selectedFoldId, state.constructFolds.contains(where: { $0.id == id }) {
                HStack(spacing: 12) {
                    legendDot(.green, "stays flat")
                    legendDot(.orange, "folds up")
                }
                Button { state.flipFoldSide() } label: {
                    HStack { Image(systemName: "arrow.left.arrow.right"); Text("Flip — make the other side fold") }
                        .font(PlasticityFont.label)
                }
                .buttonStyle(.plain).foregroundColor(.accent)
                .disabled(state.lastFoldSides == nil)
                Text("Drag the blue endpoint handles in 3D to move this crease.")
                    .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Button { state.deleteSelectedFold() } label: {
                    HStack { Image(systemName: "trash"); Text("Delete crease") }.font(PlasticityFont.label)
                }
                .buttonStyle(.plain).foregroundColor(.text_secondary)
                .disabled(state.lastFoldSeg == nil)
            }
            Button { state.setConstructTool(.crease) } label: {
                HStack { Image(systemName: ConstructTool.crease.icon); Text("Add fold (Crease tool)") }
                    .font(PlasticityFont.label)
            }
            .buttonStyle(.plain).foregroundColor(.accent)
        }
    }

    // MARK: Glue (weld) joints — for glue-tab construction

    private let glueModes: [(String, String)] = [
        ("panel", "Pieces"), ("face", "Faces"), ("edge", "Edges")
    ]

    private var glueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Glue")
            // How the bond seats — pick before clicking the two parts.
            Picker("", selection: Binding(
                get: { state.constructGlueMode },
                set: { state.setConstructGlueMode($0) })) {
                ForEach(glueModes, id: \.0) { key, label in Text(label).tag(key) }
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            Text(glueModeBlurb(state.constructGlueMode))
                .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.7))

            if state.constructTool == .glue {
                if let p = state.selectedPanelForGlue {
                    Text("Panel \(p) picked — click the \(glueTarget(state.constructGlueMode)) on the other piece.")
                        .font(PlasticityFont.label).foregroundColor(.accent)
                } else {
                    Text("Glue tool — click the \(glueTarget(state.constructGlueMode)) on one piece, then the other.")
                        .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.8))
                }
            } else {
                Button { state.setConstructTool(.glue) } label: {
                    HStack { Image(systemName: ConstructTool.glue.icon); Text("Glue tool") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PlasticityButtonStyle(isEnabled: true))
            }
            ForEach(state.constructGlues) { g in
                HStack {
                    Text("Panel \(g.panelA) ⊕ \(g.panelB) · \(g.mode)").font(PlasticityFont.label).foregroundColor(.text_primary)
                    Spacer()
                    Button { state.removeGlue(g.id) } label: { Image(systemName: "xmark.circle").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundColor(.text_secondary)
                }
            }
        }
    }

    private func glueModeBlurb(_ m: String) -> String {
        switch m {
        case "face": return "Lay the two chosen faces flat together (overlay / tab onto a panel)."
        case "edge": return "Align the two chosen edges (join pieces along an edge)."
        default:     return "Stick the two pieces together where they're nearest (general)."
        }
    }
    private func glueTarget(_ m: String) -> String {
        switch m { case "face": return "face"; case "edge": return "edge"; default: return "piece" }
    }

    // Bend-allowance summary for the whole assembly (Phase 1). Only shown once
    // something is actually folded; the per-fold numbers live in `foldRow`.
    @ViewBuilder private var bendSummary: some View {
        if state.constructFolds.contains(where: { abs($0.angleDeg) > 0.5 }) {
            Divider().background(Color.border_subtle).padding(.vertical, 2)
            readoutRow("Bend allowance", String(format: "%.1f mm", state.constructTotalBendAllowance))
            readoutRow("Flat blank deduction", String(format: "−%.1f mm", state.constructTotalBendDeduction))
            readoutRow("Min bend radius", String(format: "%.1f mm", state.constructMinBendRadiusMm))
            let tight = state.constructTightFolds.count
            if tight > 0 {
                let mat = state.constructLeather?.name ?? "this leather"
                Label("\(tight) fold\(tight == 1 ? "" : "s") tighter than \(mat) allows — grain may crack",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(PlasticityFont.label).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
                in: -180...180, step: 1,
                onEditingChanged: { began in if began { state.pushConstructUndo() } }
            )
            .controlSize(.small)
            HStack(spacing: 6) {
                Image(systemName: "drop").font(.system(size: 9)).foregroundColor(.text_secondary)
                Slider(
                    value: Binding(
                        get: { spec.roundness },
                        set: { state.setConstructFoldRoundness(spec.id, $0) }),
                    in: 0...1,
                    onEditingChanged: { began in if began { state.pushConstructUndo() } }
                )
                .controlSize(.mini)
                Text(spec.roundness < 0.02 ? "sharp" : "round")
                    .font(PlasticityFont.label).foregroundColor(.text_secondary)
            }
            .help("Fold roundness — 0 = sharp crease, 1 = rounded")
            // Bend allowance for this fold (sheet-metal: BA = θ·(R + K·T)), plus a
            // soft warning when the fold is tighter than the leather can take.
            if abs(spec.angleDeg) > 0.5 {
                HStack(spacing: 6) {
                    Text(String(format: "Bend allowance %.1f mm", state.constructBendAllowance(spec)))
                        .font(PlasticityFont.label.monospacedDigit())
                        .foregroundColor(.text_secondary.opacity(0.8))
                    if !state.constructFoldRadiusOK(spec) {
                        Spacer(minLength: 4)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundColor(.orange)
                            .help("Inside radius is tighter than this leather's minimum bend radius — the grain may crack. Round the fold or skive the bend.")
                    }
                }
            }
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

                // One-click: auto-pair likely seams (closest arc-length, different
                // panels) for the user to confirm/adjust.
                if state.canAutoStitch {
                    Button { state.autoProposeSeams() } label: {
                        HStack { Image(systemName: "wand.and.stars"); Text("Auto-stitch seams") }
                            .font(PlasticityFont.label)
                    }
                    .buttonStyle(.plain).foregroundColor(.accent)
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

    /// The plain-English verdict label + colour for a seam's fit.
    private func verdictStyle(_ v: StitchSeam.Verdict) -> (String, Color) {
        switch v {
        case .match:    return ("FITS", .green)
        case .ease:     return ("EASE", Color(hex: "C9A36A"))
        case .mismatch: return ("MISMATCH", .orange)
        }
    }

    private func seamRow(_ seam: StitchSeam) -> some View {
        let (vLabel, vColor) = verdictStyle(seam.verdict)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(vLabel)
                    .font(PlasticityFont.label.weight(.bold)).tracking(0.5)
                    .foregroundColor(vColor)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(vColor.opacity(0.18)))
                Text("Chain \(seam.chainA) → \(seam.chainB)")
                    .font(PlasticityFont.label).foregroundColor(.text_primary)
                Spacer()
                Button { state.removeSeam(seam.id) } label: {
                    Image(systemName: "scissors").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(.text_secondary).help("Unstitch")
            }

            // The three numbers a maker actually checks: hole counts, edge lengths,
            // and the gap left after the seam is seated in 3D.
            fitStat("Holes", "\(seam.holesA) vs \(seam.holesB)",
                    warn: seam.holesA != seam.holesB && seam.holesA > 0 && seam.holesB > 0)
            fitStat("Length", String(format: "%.0f vs %.0f mm", seam.lenA, seam.lenB),
                    warn: seam.mismatch >= 0.12)
            fitStat("Gap after seating", String(format: "%.1f mm", seam.maxGapMm),
                    warn: seam.maxGapMm > 4)

            if seam.verdict == .mismatch {
                Text("Seams differ too much to sew cleanly. Try Deform to Fit, or fix the hole count/spacing in 2D.")
                    .font(PlasticityFont.label).foregroundColor(.orange.opacity(0.9))
            } else if seam.verdict == .ease {
                Text("Slightly off — eased (gathered) losslessly. Switch to Deform to Fit for a flush 1:1.")
                    .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.8))
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

            // Alignment pins (Fusion-Loft) + reverse. Add pins to lock which holes
            // line up; the matcher fills the rest between them.
            let pinning = state.activeSeamForPins == seam.id && state.stitchPinMode
            HStack(spacing: 8) {
                Button { state.setStitchPinMode(seam.id, !pinning) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: pinning ? "pin.fill" : "pin")
                        Text(pinning ? "Pinning… click hole A then B" : "Add pins (\((seam.anchors ?? []).count))")
                    }.font(PlasticityFont.label)
                }
                .buttonStyle(.plain).foregroundColor(pinning ? .accent : .text_primary)
                Spacer()
                if !(seam.anchors ?? []).isEmpty {
                    Button { state.clearStitchAnchors(seam.id) } label: {
                        Image(systemName: "pin.slash").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundColor(.text_secondary).help("Clear pins")
                }
                Button { state.reverseSeam(seam.id) } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundColor((seam.flip ?? false) ? .accent : .text_secondary)
                }.buttonStyle(.plain).help("Reverse seam direction")
            }

            // Stitch phase: shift which holes line up by N along chain B. Pins fix
            // the alignment exactly, so the shift is disabled while any pin is set.
            let pinned = !(seam.anchors ?? []).isEmpty
            HStack(spacing: 8) {
                Text("Stitch phase").font(PlasticityFont.label).foregroundColor(.text_secondary)
                Spacer()
                Button { state.shiftSeam(seam.id, by: -1) } label: {
                    Image(systemName: "minus").font(.system(size: 10, weight: .bold))
                }.buttonStyle(.plain).disabled(pinned).help("Shift one hole back")
                let sh = seam.shift ?? 0
                Text(sh > 0 ? "+\(sh)" : "\(sh)")
                    .font(PlasticityFont.label.monospacedDigit())
                    .foregroundColor(sh != 0 ? .accent : .text_primary)
                    .frame(minWidth: 22)
                Button { state.shiftSeam(seam.id, by: 1) } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                }.buttonStyle(.plain).disabled(pinned).help("Shift one hole forward")
            }
            .opacity(pinned ? 0.4 : 1.0)
            if pinned {
                Text("Remove pins to shift the stitch phase.")
                    .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.7))
            }
            if pinning {
                Text("Click a hole on one row, then its partner on the other. The seam re-matches around your pins.")
                    .font(PlasticityFont.label).foregroundColor(.accent)
            }
        }
        .padding(7)
        .background(Color.bg_selected.opacity(0.5))
        .cornerRadius(5)
    }

    private func fitStat(_ label: String, _ value: String, warn: Bool) -> some View {
        HStack {
            Text(label).font(PlasticityFont.label).foregroundColor(.text_secondary)
            Spacer()
            Text(value).font(PlasticityFont.label.monospacedDigit())
                .foregroundColor(warn ? .orange : .text_primary)
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

            // Physical leather — sets thickness, tint, and the bend-allowance
            // properties (temper, K-factor, min bend radius). Thickness + tint
            // below stay overridable afterwards.
            Picker(selection: Binding<String>(
                get: { state.constructMaterialId ?? "" },
                set: { id in if let m = LeatherStore.shared.material(id: id) { state.selectConstructMaterial(m) } })) {
                Text("Choose leather…").tag("")
                ForEach(LeatherStore.shared.all) { m in Text(m.name).tag(m.id) }
            } label: { EmptyView() }
            .pickerStyle(.menu).controlSize(.small).labelsHidden()
            if let m = state.constructLeather {
                Text(m.summary)
                    .font(PlasticityFont.label).foregroundColor(.text_secondary.opacity(0.85))
            }

            // Multi-material: give individual panels their own leather (e.g. a firm
            // stiffener patch on a soft body). Empty = the assembly default above.
            if state.constructPanelHandles.count >= 2 {
                DisclosureGroup {
                    ForEach(state.constructPanelHandles.keys.sorted(), id: \.self) { pid in
                        HStack {
                            Text("Panel \(pid)").font(PlasticityFont.label).foregroundColor(.text_secondary)
                            Spacer()
                            Picker(selection: Binding<String>(
                                get: { state.leatherForPanel(pid)?.id ?? "" },
                                set: { state.setConstructPanelMaterial(pid, $0.isEmpty ? nil : $0) })) {
                                Text("Assembly default").tag("")
                                ForEach(LeatherStore.shared.all) { m in Text(m.name).tag(m.id) }
                            } label: { EmptyView() }
                            .labelsHidden().controlSize(.small).frame(maxWidth: 160)
                        }
                    }
                } label: {
                    Text("Per-panel material").font(PlasticityFont.label).foregroundColor(.text_secondary)
                }
            }

            Text("Tint").font(PlasticityFont.label).foregroundColor(.text_secondary).tracking(1)
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
                in: 0.5...8, step: 0.1,
                onEditingChanged: { began in if began { state.pushConstructUndo() } }
            )
            .controlSize(.small)

            // Finish — surface sheen from matte veg-tan to glossy patent.
            HStack {
                Text("Finish").font(PlasticityFont.label).foregroundColor(.text_secondary)
                Spacer()
            }
            Picker("", selection: Binding(
                get: { state.constructFinish },
                set: { state.setConstructFinish($0) })) {
                ForEach(finishes, id: \.0) { key, label in Text(label).tag(key) }
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()

            // Custom leather texture — a photo / seamless tile used as the albedo.
            HStack(spacing: 8) {
                Button { state.loadConstructLeatherTexture() } label: {
                    HStack(spacing: 4) { Image(systemName: "photo"); Text(state.constructLeatherTextureURL == nil ? "Custom texture…" : "Replace texture…") }
                        .font(PlasticityFont.label)
                }
                .buttonStyle(.plain).foregroundColor(.accent)
                if state.constructLeatherTextureURL != nil {
                    Button { state.setConstructLeatherTextureURL(nil) } label: {
                        Image(systemName: "xmark.circle").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundColor(.text_secondary).help("Remove texture")
                }
            }
            if state.constructLeatherTextureURL != nil {
                framingSlider("Tiling", value: state.constructLeatherTiling, range: 0.5...8) {
                    state.setConstructLeatherTiling($0)
                }
            }

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
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range,
                   onEditingChanged: { began in if began { state.pushConstructUndo() } })
                .controlSize(.small)
        }
    }

    // MARK: Health detail — the actionable "what's wrong" lines (numbers live in the
    // overview strip; this is shown under the Select tool).

    private var healthDetail: some View {
        let h = state.assemblyHealth
        return VStack(alignment: .leading, spacing: 4) {
            readoutRow("Seam length", String(format: "%.0f mm", state.constructSeamLengthMm))
            Divider().background(Color.border_subtle).padding(.vertical, 2)
            if h.ok && h.openChains == 0 {
                Label("Everything connected, seams fit", systemImage: "checkmark.seal.fill")
                    .font(PlasticityFont.label).foregroundColor(.green)
            } else {
                if h.floating > 0 {
                    Label("\(h.floating) panel\(h.floating == 1 ? "" : "s") not attached to the base", systemImage: "exclamationmark.triangle.fill")
                        .font(PlasticityFont.label).foregroundColor(.orange)
                }
                if h.mismatched > 0 {
                    Label("\(h.mismatched) seam\(h.mismatched == 1 ? "" : "s") don't fit", systemImage: "exclamationmark.triangle.fill")
                        .font(PlasticityFont.label).foregroundColor(.orange)
                }
                if h.openChains > 0 {
                    Label("\(h.openChains) hole chain\(h.openChains == 1 ? "" : "s") unstitched", systemImage: "circle.dashed")
                        .font(PlasticityFont.label).foregroundColor(.text_secondary)
                }
            }
        }
    }

    private func readoutRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(PlasticityFont.label).foregroundColor(.text_secondary)
            Spacer()
            Text(value).font(PlasticityFont.label.monospacedDigit()).foregroundColor(.text_primary)
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
