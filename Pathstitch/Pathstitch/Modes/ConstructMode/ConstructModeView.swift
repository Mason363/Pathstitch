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
                    explodeToken: state.constructExplodeToken,
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
                        Text("Building assembly…")
                            .font(.system(size: 12.5, weight: .medium)).foregroundColor(.to_textSec)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.to_panel.opacity(0.94)))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.to_panelBorder, lineWidth: 1))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            inspector
                .frame(width: 280)
                .background(Color.to_panel)
                .border(Color.to_panelBorder, width: 1)
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
        case .measure:
            return ToolGuide(icon: "ruler", name: "Measure",
                             step: "Click two points on the leather — the tape sticks to the surface and re-reads as you fold. Clicks near a sewing hole snap to it.")
        }
    }

    private var toolHUD: some View {
        let g = toolGuide
        return HStack(spacing: 10) {
            Image(systemName: g.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.to_accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.to_textPri)
                Text(g.step).font(.system(size: 12, weight: .medium)).foregroundColor(.to_textTer)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.to_panel.opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.to_accent.opacity(0.35), lineWidth: 1))
        )
        .frame(maxWidth: 360, alignment: .leading)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    private var stepCard: some View {
        let g = toolGuide
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: g.icon).font(.system(size: 14, weight: .semibold))
                .foregroundColor(.to_accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(g.name).font(.system(size: 13, weight: .semibold)).tracking(0.4)
                    .textCase(.uppercase).foregroundColor(.to_textPri)
                Text(g.step).font(.system(size: 12, weight: .medium)).foregroundColor(.to_textTer)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.to_accentTint))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.to_accent.opacity(0.35), lineWidth: 1))
    }

    // One enclosed area sits inside another — ask how to treat the inner one.
    @ViewBuilder
    private func overlapChooser(_ e: [String: String]) -> some View {
        let inner = e["inner"] ?? ""
        let count = state.pendingEngulfed.count
        return VStack(alignment: .leading, spacing: 12) {
            Text(count > 1 ? "Overlapping areas (\(count))" : "Overlapping area")
                .font(.system(size: 13, weight: .semibold)).tracking(0.5)
                .foregroundColor(.to_textPri)
            TOHint(count > 1
                 ? "\(count) areas sit inside others. How should they be treated?"
                 : "An area sits inside another. How should the inner one be treated?")
            if count > 1 {
                TOCheck(label: "Apply my choice to all \(count) areas", isOn: $overlapApplyToAll)
            }
            overlapOption(inner, "sew", "Sewing holes", "Treat the area as a stitch hole — joins the hole chains like any hole on the SEWING_HOLES layer.")
            overlapOption(inner, "stamp", "Decoration stamp", "Printed/tooled outline on the surface — never cut, rides the fold.")
            overlapOption(inner, "patch", "Raised patch", "A separate piece sitting on top (pocket / overlay).")
            overlapOption(inner, "cutout", "Cut-out window", "A real hole through the outer panel.")
            overlapOption(inner, "independent", "Independent panel", "Just another panel that happens to overlap in 2D.")
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.to_panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.to_panelBorder, lineWidth: 1))
        .toPanelShadow()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func overlapOption(_ inner: String, _ mode: String, _ title: String, _ blurb: String) -> some View {
        Button { state.setAreaTreatment(inner: inner, mode: mode, all: overlapApplyToAll) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.to_textPri)
                Text(blurb).font(.system(size: 12, weight: .medium)).foregroundColor(.to_textMut)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.to_field))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.to_fieldBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var inspector: some View {
        // Construct/3D shell (design handoff, Shell B): pinned construct header,
        // Edit/Mockup toggle, and active-tool card; a single scrolling settings
        // region; then the pinned solver readout + (collapsed) Display Options.
        let editing = !state.constructArtworkMode && state.constructRenderMode != "mockup"
        return VStack(alignment: .leading, spacing: 0) {
            // Construct header (pinned).
            HStack(spacing: 12) {
                Text("Construct")
                    .font(.system(size: 15, weight: .semibold)).tracking(1.05).textCase(.uppercase)
                    .foregroundColor(.to_textPri)
                Spacer()
                Button { state.undoConstruct() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12))
                }
                .buttonStyle(.plain).disabled(!state.canUndoConstruct)
                .foregroundColor(state.canUndoConstruct ? .to_textTer : .to_textTer.opacity(0.3))
                .help("Undo (⌘Z)")
                Button { state.redoConstruct() } label: {
                    Image(systemName: "arrow.uturn.forward").font(.system(size: 12))
                }
                .buttonStyle(.plain).disabled(!state.canRedoConstruct)
                .foregroundColor(state.canRedoConstruct ? .to_textTer : .to_textTer.opacity(0.3))
                .help("Redo (⇧⌘Z)")
                Button { state.constructHome() } label: {
                    Image(systemName: "house").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(.to_textTer).help("Recenter view")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            // Pinned overview (size / stitches / health + Assemble + Export),
            // Edit ↔ Mockup, and the active-tool card.
            VStack(alignment: .leading, spacing: 12) {
                overviewStrip
                renderModeSection
                if editing { stepCard }
            }
            .padding(.horizontal, 14).padding(.bottom, 12)

            TODivider()

            // Scrolling settings — the only region that scrolls.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if state.constructArtworkMode {
                        artworkPanel
                    } else if state.constructRenderMode == "mockup" {
                        materialSection
                        ConstructLightingView(state: state)
                    } else {
                        toolOptions
                    }
                }
                .padding(14)
            }

            // Pinned solver readout + (collapsed) Display Options.
            VStack(alignment: .leading, spacing: 0) {
                if editing {
                    TODivider()
                    stretchSection
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
                TODivider()
                DisclosureGroup(isExpanded: $showDisplay) {
                    VStack(alignment: .leading, spacing: 14) {
                        if state.constructAssemblySteps.count >= 2 { stepsSection }
                        explodeSection
                        shadingSection
                        matSection
                    }
                    .padding(.top, 8).padding(.horizontal, 14).padding(.bottom, 12)
                } label: {
                    TOGroupLabel("Display Options")
                        .padding(.horizontal, 14).padding(.vertical, 11)
                }
                .tint(Color.to_textTer)
            }
            .background(Color.to_panel)
        }
    }

    // MARK: Render mode — Edit (working) vs Mockup (clean beauty render)

    private let renderModes: [(String, String)] = [("edit", "Edit"), ("mockup", "Mockup")]

    private var renderModeSection: some View {
        TOSegmented(options: renderModes,
                    selection: Binding(get: { state.constructRenderMode },
                                       set: { state.setConstructRenderMode($0) }))
        .frame(maxWidth: .infinity)
    }

    // MARK: Build steps — scrub the solver's seating order like instructions

    private var stepsSection: some View {
        let steps = state.constructAssemblySteps
        let n = steps.count
        let lim = state.constructStepLimit          // -1 = show all
        let shown = lim < 0 ? n : min(lim, n)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TOGroupLabel("Build Steps")
                Spacer()
                if lim >= 0 {
                    Button { state.setConstructStep(-1) } label: {
                        Text("Show all")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.to_accent)
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Button { state.setConstructStep(max(1, shown - 1)) } label: {
                    Image(systemName: "minus").font(.system(size: 11, weight: .bold))
                        .foregroundColor(.to_textTer).frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(shown <= 1).help("One step back")
                Text(lim < 0 ? "All \(n) steps" : "Step \(shown) of \(n)")
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundColor(lim < 0 ? .to_textPri : .to_accent)
                    .frame(maxWidth: .infinity)
                Button {
                    let next = shown + 1
                    state.setConstructStep(next >= n ? -1 : next)
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        .foregroundColor(.to_textTer).frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(lim < 0).help("One step forward")
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<n, id: \.self) { i in
                    let active = lim >= 0 && i == shown - 1
                    let placed = lim < 0 || i < shown
                    Button { state.setConstructStep(i + 1) } label: {
                        HStack(spacing: 6) {
                            Text("\(i + 1).")
                                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                                .foregroundColor(active ? .to_accent : .to_textMut)
                            Text(state.assemblyStepCaption(i))
                                .font(.system(size: 12, weight: active ? .semibold : .regular))
                                .foregroundColor(active ? .to_accent : (placed ? .to_textSec : .to_textMut))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3.5)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(active ? Color.to_accentTint : Color.clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            TOHint("The stitch order, worked out from the assembly — scrub it to see the build one attachment at a time. View only.")
        }
    }

    // MARK: Exploded view — pull the pieces apart to inspect internal seams

    private var explodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TOGroupLabel("Explode")
            TOSlider(value: Binding(get: { state.constructExplode },
                                    set: { state.setConstructExplode($0) }),
                     range: 0...1, unit: "",
                     minLabel: "assembled", maxLabel: "apart", maxFrac: 2)
            TOHint("Pulls the pieces apart to inspect seams inside a closed shape — view only, never exported.")
        }
    }

    // MARK: Shading — how panels are drawn (independent of Edit/Mockup)

    private let shaderModes: [(String, String)] = [
        ("wireframe", "Wire"), ("solid", "Solid"), ("flat", "Flat"), ("realistic", "Realistic")
    ]

    private var shadingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TOGroupLabel("Shading")
            TOSegmented(options: shaderModes,
                        selection: Binding(get: { state.constructShaderMode },
                                           set: { state.setConstructShaderMode($0) }))
            TOHint("How panels are drawn — works in both Edit and Mockup. Realistic is the PBR leather; Wire/Solid/Flat are inspection views.")
        }
    }

    // MARK: Cutting mat — finite baseplate shared with the 2D canvas

    private var matSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TOCheck(label: "Cutting mat",
                    isOn: Binding(get: { state.matEnabled },
                                  set: { state.matEnabled = $0; state.bumpMat() }))
            if state.matEnabled {
                HStack(spacing: 8) {
                    TOLabel("W", color: .to_textMut)
                    TextField("", value: Binding(get: { state.matWidthMm },
                        set: { state.matWidthMm = $0; state.bumpMat() }), format: .number)
                        .toFieldStyle(width: 60)
                    TOLabel("H", color: .to_textMut)
                    TextField("", value: Binding(get: { state.matHeightMm },
                        set: { state.matHeightMm = $0; state.bumpMat() }), format: .number)
                        .toFieldStyle(width: 60)
                    TOLabel("mm", color: .to_textMut)
                }
                TOCheck(label: "Show mat grid",
                        isOn: Binding(get: { state.matGridVisible },
                                      set: { state.matGridVisible = $0; state.bumpMat() }))
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.0f × %.0f × %.0f mm",
                                state.constructFinishedW, state.constructFinishedH, state.constructFinishedD))
                        .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                        .foregroundColor(.to_textPri)
                    Text("\(state.constructStitchCount) stitches · \(String(format: "%.0f", state.constructLeatherAreaMm2 / 100)) cm² · \(state.constructReadoutPanels) panels")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.to_textMut)
                }
                Spacer()
                Image(systemName: healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(healthy ? .to_ok : .to_warn)
                    .help(healthy ? "Everything connected, seams fit" : healthSummary(h))
            }
            HStack(spacing: 8) {
                TOPrimaryButton(title: "Assemble", enabled: !state.constructFolds.isEmpty) {
                    state.assembleAll()
                }
                Menu {
                    Button("STEP (.step)") { state.exportConstruct("step") }
                    Button("STL (.stl)") { state.exportConstruct("stl") }
                    Divider()
                    Button("3D model (.glb)") { state.exportConstruct("glb") }
                    Button("Snapshot (.png)") { state.exportConstruct("png") }
                    Button("Step sheet (PNG per step)") { state.exportConstruct("steps") }
                        .disabled(state.constructAssemblySteps.count < 2)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
                        Text("Export").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundColor(state.constructReadoutPanels == 0 ? .to_textMut : .to_accent)
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.to_accent.opacity(state.constructReadoutPanels == 0 ? 0.05 : 0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.to_accent.opacity(state.constructReadoutPanels == 0 ? 0.15 : 0.45), lineWidth: 1))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
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
        case .measure: measureSection
        }
    }

    private var selectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TOHint("Hover highlights what you'll pick. Click a fold to set its angle, or choose a tool on the left.")
            TOSecondaryButton(title: "Rebuild from sketch", icon: "arrow.triangle.2.circlepath") {
                state.buildConstructModel()
            }
            healthDetail
        }
    }

    private var creaseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TOHint("Endpoints snap to corners / edges (toggle snapping with “n”). The new fold is written to the 2D sketch on the FOLD layer — editable back in 2D.")
            if !state.constructUserFolds.isEmpty {
                TOSecondaryButton(title: "Undo added fold (\(state.constructUserFolds.count))",
                                  icon: "arrow.uturn.backward") {
                    state.undoLastUserFold()
                }
            }
        }
    }

    private func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c.opacity(0.7)).frame(width: 8, height: 8)
            Text(t).font(.system(size: 12, weight: .medium)).foregroundColor(.to_textMut)
        }
    }

    // MARK: Artwork placement panel (shown while a dropped image is being placed)

    private var artworkPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Place Artwork")
            TOHint(state.activeDecalPanel == nil
                 ? "Bird's-eye view — click a body to drop the image onto it."
                 : "Drag the art on the body to move it. Tune it below; click another body to place it there too.")
            if let pid = state.activeDecalPanel, state.constructDecals[pid] != nil {
                TOStatus(text: "Body \(pid)")
                HStack(spacing: 8) {
                    TOSecondaryButton(title: "Fill", icon: "arrow.up.left.and.arrow.down.right") {
                        state.artworkCommand("fill")
                    }
                    TOSecondaryButton(title: "Other face", icon: "square.on.square") {
                        state.artworkCommand("flipface")
                    }
                    TOSecondaryButton(title: "Mirror", icon: "arrow.left.and.right") {
                        state.artworkCommand("mirror")
                    }
                }
                let x = state.decalXform(pid)
                framingSlider("Scale", value: x[2], range: 0.2...3) { state.setDecalXform(pid, 2, $0) }
                framingSlider("Rotation", value: x[3], range: -180...180, unit: "°") { state.setDecalXform(pid, 3, $0) }
                TOSecondaryButton(title: "Remove from body \(pid)", icon: "trash", tint: .to_textMut) {
                    state.clearConstructDecal(pid)
                }
            }
            TOPrimaryButton(title: "Done") { state.exitArtworkPlacement() }
        }
    }

    private var moveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TORow(label: "Gizmo") {
                TOSegmented(options: transformModes,
                            selection: Binding(get: { state.constructTransformMode },
                                               set: { state.setConstructTransformMode($0) }))
            }
            TOHint("Poses the 3D object only — it never changes the 2D sketch, and edits in 2D still flow through.")
            if !state.constructPanelXf.isEmpty {
                TOSecondaryButton(title: "Reset poses (\(state.constructPanelXf.count))",
                                  icon: "arrow.uturn.backward") {
                    state.clearConstructPanelTransforms()
                }
            }
        }
    }

    private var groundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TOStatus(text: "Base panel \(state.constructGroundPanel)", hint: "stays flat")
            TOHint("Click a face to pin it as the base. On a folded panel, click the side you want flat — the rest folds relative to it.")
        }
    }

    private var foldSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.constructFolds.isEmpty {
                TOHint("No fold lines yet. Add one two ways:")
                VStack(alignment: .leading, spacing: 6) {
                    TOHint("• In 2D: draw a LINE → right-click → “Make Fold Line” (or move it to a FOLD layer), then Rebuild.")
                    TOHint("• In 3D: use the Crease tool and click two points across a panel.")
                }
            } else {
                if state.constructFolds.count >= 2 && !state.constructFolds.contains(where: { $0.linked == true }) {
                    TOHint("Tip: the ⛓ button links folds so they fold together — e.g. all four box flaps.")
                }
                ForEach(state.constructFolds) { spec in
                    foldRow(spec)
                }
                bendSummary
            }
            // Which side stays flat vs folds — shown for the selected fold, with a
            // one-click Flip. (Ground tool can also click the base face directly.)
            if let id = state.selectedFoldId, state.constructFolds.contains(where: { $0.id == id }) {
                TODivider()
                HStack(spacing: 14) {
                    legendDot(.to_ok, "stays flat")
                    legendDot(.to_warn, "folds up")
                }
                TOSecondaryButton(title: "Flip — make the other side fold",
                                  icon: "arrow.left.arrow.right",
                                  enabled: state.lastFoldSides != nil) {
                    state.flipFoldSide()
                }
                TOHint("Drag the blue endpoint handles in 3D to move this crease.")
                TOSecondaryButton(title: "Delete crease", icon: "trash",
                                  enabled: state.lastFoldSeg != nil, tint: .to_textMut) {
                    state.deleteSelectedFold()
                }
            }
            TOSecondaryButton(title: "Add fold (Crease tool)", icon: ConstructTool.crease.icon) {
                state.setConstructTool(.crease)
            }
        }
    }

    // MARK: Measure — two points on the folded leather, live distance

    private var measureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TOSegmented(options: [("straight", "Straight"), ("surface", "Along surface")],
                        selection: Binding(get: { state.constructMeasureMode },
                                           set: { state.setConstructMeasureMode($0) }))
            if state.constructMeasureMm >= 0 {
                HStack(spacing: 8) {
                    Image(systemName: "ruler").font(.system(size: 13)).foregroundColor(.to_accent)
                    Text(String(format: "%.1f mm", state.constructMeasureMm))
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                        .foregroundColor(.to_textPri)
                    Text(String(format: "(%.2f in)", state.constructMeasureMm / 25.4))
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundColor(.to_textMut)
                    Spacer()
                }
                if state.constructMeasureMode == "surface" && !state.constructMeasureIsSurface {
                    TOStatus(color: .to_warn, text: "Points sit on different pieces — showing the straight line.")
                } else if state.constructMeasureIsSurface {
                    TOHint("Exact over-the-leather run (the flat-pattern distance) — what a strap or lace actually travels across the folds.")
                } else {
                    TOHint("Straight-line distance. The endpoints stick to the leather, so it re-reads as you fold or explode.")
                }
                TOSecondaryButton(title: "Clear measurement", icon: "xmark", tint: .to_textMut) {
                    state.clearConstructMeasurement()
                }
            } else {
                TOHint("Click two points on the leather to measure. Clicks near a sewing hole snap to the hole for exact hole-to-hole runs.")
            }
        }
    }

    // MARK: Glue (weld) joints — for glue-tab construction

    private let glueModes: [(String, String)] = [
        ("panel", "Pieces"), ("face", "Faces"), ("edge", "Edges")
    ]

    private var glueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // How the bond seats — pick before clicking the two parts.
            TORow(label: "Bond") {
                TOSegmented(options: glueModes,
                            selection: Binding(get: { state.constructGlueMode },
                                               set: { state.setConstructGlueMode($0) }))
            }
            TOHint(glueModeBlurb(state.constructGlueMode))

            if state.constructTool == .glue {
                if let p = state.selectedPanelForGlue {
                    TOStatus(text: "Piece \(p) picked",
                             hint: "click the \(glueTarget(state.constructGlueMode)) on the other piece")
                } else {
                    TOStatus(color: .to_textFaint,
                             text: "Pick two \(glueTarget(state.constructGlueMode))s to weld")
                }
            } else {
                TOSecondaryButton(title: "Glue tool", icon: ConstructTool.glue.icon) {
                    state.setConstructTool(.glue)
                }
            }
            if !state.constructGlues.isEmpty {
                TODivider()
                ForEach(state.constructGlues) { g in
                    HStack {
                        Text("Piece \(g.panelA) ⊕ \(g.panelB) · \(g.mode)")
                            .font(.system(size: 12.5, weight: .medium)).foregroundColor(.to_textSec)
                        Spacer()
                        Button { state.removeGlue(g.id) } label: {
                            Image(systemName: "xmark.circle").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundColor(.to_textMut).help("Remove glue")
                    }
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
            TODivider()
            readoutRow("Bend allowance", String(format: "%.1f mm", state.constructTotalBendAllowance))
            readoutRow("Flat blank deduction", String(format: "−%.1f mm", state.constructTotalBendDeduction))
            readoutRow("Min bend radius", String(format: "%.1f mm", state.constructMinBendRadiusMm))
            let tight = state.constructTightFolds.count
            if tight > 0 {
                let mat = state.constructLeather?.name ?? "this leather"
                TOWarning(title: "\(tight) fold\(tight == 1 ? "" : "s") tighter than \(mat) allows",
                          detail: "The grain may crack — round the fold or skive the bend.")
            }
        }
    }

    private func foldRow(_ spec: FoldSpec) -> some View {
        let selected = state.selectedFoldId == spec.id
        let linked = spec.linked == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Panel \(spec.panelId) · Fold \(spec.foldId)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(selected ? .to_accent : .to_textSec)
                Spacer()
                // Fold symmetry: linked folds share one angle — drag/slide any of
                // them and the whole group follows. Joining adopts the group angle.
                Button { state.toggleFoldLinked(spec.id) } label: {
                    Image(systemName: linked ? "link.circle.fill" : "link.circle")
                        .font(.system(size: 13))
                        .foregroundColor(linked ? .to_accent : .to_textMut)
                }
                .buttonStyle(.plain)
                .help(linked ? "Linked — this fold moves with the other linked folds"
                             : "Link this fold so it moves with the other linked folds")
                Text("\(Int(spec.angleDeg))°")
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundColor(.to_textPri)
            }
            TOSlider(
                value: Binding(get: { spec.angleDeg },
                               set: { state.setConstructFoldAngle(spec.id, $0) }),
                range: -180...180, unit: "°", maxFrac: 0, step: 1,
                onBegin: { state.pushConstructUndo() })
            // One-tap presets for the angles leatherwork actually uses: box sides
            // (±90°), gusset half-folds (±45°), fold-flat (180°), and open (0°).
            TOPresetChips(values: [-180, -90, -45, 0, 45, 90, 180],
                          value: Binding(get: { spec.angleDeg },
                                         set: { state.pushConstructUndo()
                                                state.setConstructFoldAngle(spec.id, $0) }),
                          unit: "°", maxFrac: 0)
            TOSlider(
                value: Binding(get: { spec.roundness },
                               set: { state.setConstructFoldRoundness(spec.id, $0) }),
                range: 0...1, unit: "",
                minLabel: "sharp", maxLabel: "round", maxFrac: 2,
                onBegin: { state.pushConstructUndo() })
            // Bend allowance for this fold (sheet-metal: BA = θ·(R + K·T)), plus a
            // soft warning when the fold is tighter than the leather can take.
            if abs(spec.angleDeg) > 0.5 {
                HStack(spacing: 6) {
                    Text(String(format: "Bend allowance %.1f mm", state.constructBendAllowance(spec)))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundColor(.to_textMut)
                    if !state.constructFoldRadiusOK(spec) {
                        Spacer(minLength: 4)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundColor(.to_warn)
                            .help("Inside radius is tighter than this leather's minimum bend radius — the grain may crack. Round the fold or skive the bend.")
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Color.to_accentTint : Color.to_field))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(selected ? Color.to_accent : Color.to_fieldBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { state.selectedFoldId = spec.id }
    }

    // MARK: Stitch flagship — seams between sewing-hole chains

    private var seamSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.constructHoleChains.isEmpty {
                TOStatus(color: .to_textFaint, text: "No sewing holes found")
                TOHint("Add holes in 2D (Sewing Holes), then Rebuild — each run of holes becomes a chain you can stitch.")
            } else {
                TOStatus(text: "\(state.constructHoleChains.count) hole chains detected")

                // Stitch tool prompt + pending pick state.
                if state.constructTool == .stitch {
                    if let pick = state.selectedChainForStitch {
                        TOStatus(text: "Chain \(pick) selected", hint: "click another chain to sew")
                    } else {
                        TOHint("Click a hole chain in the viewport to start.")
                    }
                } else {
                    TOSecondaryButton(title: "Stitch chains", icon: ConstructTool.stitch.icon) {
                        state.setConstructTool(.stitch)
                    }
                }

                // One-click: auto-pair likely seams (closest arc-length, different
                // panels) for the user to confirm/adjust.
                if state.canAutoStitch {
                    TOSecondaryButton(title: "Auto-stitch seams", icon: "wand.and.stars") {
                        state.autoProposeSeams()
                    }
                }

                if !state.constructSeams.isEmpty {
                    TOCheck(label: "Show thread",
                            isOn: Binding(get: { state.constructShowThread },
                                          set: { state.setConstructShowThread($0) }))
                    ForEach(state.constructSeams) { seam in
                        seamRow(seam)
                    }
                    // Pro-CAD fit: the thresholds every FITS/EASE/MISMATCH verdict
                    // is judged against. Collapsed — the defaults suit hobbyists.
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            TORow(label: "Length ±") {
                                TOStepper(value: Binding(get: { state.seamTolMismatchPct },
                                                         set: { state.setSeamTolerances(mismatchPct: $0, gapMm: state.seamTolGapMm) }),
                                          unit: "%", step: 1, range: 1...50, maxFrac: 0)
                            }
                            TORow(label: "Max gap") {
                                TOStepper(value: Binding(get: { state.seamTolGapMm },
                                                         set: { state.setSeamTolerances(mismatchPct: state.seamTolMismatchPct, gapMm: $0) }),
                                          unit: "mm", step: 0.5, range: 0.5...25, maxFrac: 1)
                            }
                            TOHint("A seam reads MISMATCH when its length difference or after-seating gap exceeds these. Saved with the assembly.")
                        }
                        .padding(.top, 8)
                    } label: {
                        TOGroupLabel("Fit tolerance")
                    }
                    .tint(Color.to_textTer)
                }
            }
        }
    }

    /// A small accent chip that re-punches one seam side to N holes ("A → 12").
    private func repunchChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundColor(.to_accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.to_accentTint))
        }
        .buttonStyle(.plain)
        .help("Re-punch this side's holes to match the other side's count")
    }

    /// The plain-English verdict label + colour for a seam's fit.
    private func verdictStyle(_ v: StitchSeam.Verdict) -> (String, Color) {
        switch v {
        case .match:    return ("FITS", .to_ok)
        case .ease:     return ("EASE", Color(hex: "C9A36A"))
        case .mismatch: return ("MISMATCH", .to_warn)
        }
    }

    private func seamRow(_ seam: StitchSeam) -> some View {
        let verdict = state.seamVerdict(seam)   // judged against the user tolerances
        let (vLabel, vColor) = verdictStyle(verdict)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(vLabel)
                    .font(.system(size: 10, weight: .bold)).tracking(0.5)
                    .foregroundColor(vColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(vColor.opacity(0.18)))
                Text("Chain \(seam.chainA) → \(seam.chainB)")
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(.to_textSec)
                Spacer()
                Button { state.removeSeam(seam.id) } label: {
                    Image(systemName: "scissors").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(.to_textMut).help("Unstitch")
            }

            // The three numbers a maker actually checks: hole counts, edge lengths,
            // and the gap left after the seam is seated in 3D.
            fitStat("Holes", "\(seam.holesA) vs \(seam.holesB)",
                    warn: seam.holesA != seam.holesB && seam.holesA > 0 && seam.holesB > 0)
            fitStat("Length", String(format: "%.0f vs %.0f mm", seam.lenA, seam.lenB),
                    warn: seam.mismatch >= state.seamTolMismatchPct / 100)
            fitStat("Gap after seating", String(format: "%.1f mm", seam.maxGapMm),
                    warn: seam.maxGapMm > state.seamTolGapMm)

            if verdict == .mismatch {
                TOHint("Seams differ too much to sew cleanly. Try Deform to Fit, or fix the hole count/spacing in 2D.")
            } else if verdict == .ease {
                TOHint("Slightly off — eased (gathered) losslessly. Switch to Deform to Fit for a flush 1:1.")
            }

            // Fix in 2D: re-punch one side's holes so the counts match and the seam
            // sews hole-for-hole. The chain keeps its exact path and endpoints.
            if seam.holesA != seam.holesB, seam.holesA >= 2, seam.holesB >= 2 {
                HStack(spacing: 7) {
                    Image(systemName: "wand.and.rays")
                        .font(.system(size: 11)).foregroundColor(.to_accent)
                    Text("Fix in 2D")
                        .font(.system(size: 12.5, weight: .medium)).foregroundColor(.to_textSec)
                    Spacer()
                    repunchChip("A → \(seam.holesB)") { state.repunchSeamChain(seam.id, side: "A") }
                    repunchChip("B → \(seam.holesA)") { state.repunchSeamChain(seam.id, side: "B") }
                }
                TOHint("Re-punches that side's holes evenly along its own edge so both sides pair 1:1. Pins and phase reset.")
            }

            // Mismatch policy.
            TOSegmented(options: StitchMode.allCases.map { ($0, $0.label) },
                        selection: Binding(get: { seam.mode },
                                           set: { state.setSeamMode(seam.id, $0) }))
            TOHint(seam.mode.blurb)

            // Alignment pins (Fusion-Loft) + reverse. Add pins to lock which holes
            // line up; the matcher fills the rest between them.
            let pinning = state.activeSeamForPins == seam.id && state.stitchPinMode
            HStack(spacing: 8) {
                Button { state.setStitchPinMode(seam.id, !pinning) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: pinning ? "pin.fill" : "pin").font(.system(size: 11))
                        Text(pinning ? "Pinning… click hole A then B" : "Add pins (\((seam.anchors ?? []).count))")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                }
                .buttonStyle(.plain).foregroundColor(pinning ? .to_accent : .to_textSec)
                Spacer()
                if !(seam.anchors ?? []).isEmpty {
                    Button { state.clearStitchAnchors(seam.id) } label: {
                        Image(systemName: "pin.slash").font(.system(size: 12))
                    }.buttonStyle(.plain).foregroundColor(.to_textMut).help("Clear pins")
                }
                Button { state.reverseSeam(seam.id) } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundColor((seam.flip ?? false) ? .to_accent : .to_textMut)
                }.buttonStyle(.plain).help("Reverse seam direction")
            }

            // Stitch phase: shift which holes line up by N along chain B. Pins fix
            // the alignment exactly, so the shift is disabled while any pin is set.
            let pinned = !(seam.anchors ?? []).isEmpty
            HStack(spacing: 10) {
                TOLabel("Stitch phase")
                Spacer()
                Button { state.shiftSeam(seam.id, by: -1) } label: {
                    Image(systemName: "minus").font(.system(size: 11, weight: .bold))
                        .foregroundColor(.to_textTer).frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(pinned).help("Shift one hole back")
                let sh = seam.shift ?? 0
                Text(sh > 0 ? "+\(sh)" : "\(sh)")
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundColor(sh != 0 ? .to_accent : .to_textPri)
                    .frame(minWidth: 22)
                Button { state.shiftSeam(seam.id, by: 1) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        .foregroundColor(.to_textTer).frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(pinned).help("Shift one hole forward")
            }
            .opacity(pinned ? 0.4 : 1.0)
            if pinned {
                TOHint("Remove pins to shift the stitch phase.")
            }
            if pinning {
                TOStatus(text: "Click a hole on one row, then its partner on the other.",
                         hint: "re-matches around your pins")
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.to_field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.to_fieldBorder, lineWidth: 1))
    }

    private func fitStat(_ label: String, _ value: String, warn: Bool) -> some View {
        HStack {
            TOLabel(label, color: .to_textMut)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .foregroundColor(warn ? .to_warn : .to_textPri)
        }
    }

    // MARK: Mockup material — leather colour + thickness

    private let leatherSwatches: [(String, String)] = [
        ("8A5A2B", "Tan"), ("4A2F1B", "Dark brown"), ("C9A36A", "Natural"),
        ("3A2418", "Espresso"), ("7C1E1E", "Oxblood"), ("1C1C1E", "Black")
    ]

    private var materialSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Material")

            // Physical leather — sets thickness, tint, and the bend-allowance
            // properties (temper, K-factor, min bend radius). Thickness + tint
            // below stay overridable afterwards.
            TOSelect(options: [("", "Choose leather…")] + LeatherStore.shared.all.map { ($0.id, $0.name) },
                     selection: Binding<String>(
                        get: { state.constructMaterialId ?? "" },
                        set: { id in if let m = LeatherStore.shared.material(id: id) { state.selectConstructMaterial(m) } }))
            if let m = state.constructLeather {
                TOHint(m.summary)
            }

            // Multi-material: give individual panels their own leather (e.g. a firm
            // stiffener patch on a soft body). Empty = the assembly default above.
            if state.constructPanelHandles.count >= 2 {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.constructPanelHandles.keys.sorted(), id: \.self) { pid in
                            TORow(label: "Panel \(pid)") {
                                TOSelect(options: [("", "Assembly default")] + LeatherStore.shared.all.map { ($0.id, $0.name) },
                                         selection: Binding<String>(
                                            get: { state.leatherForPanel(pid)?.id ?? "" },
                                            set: { state.setConstructPanelMaterial(pid, $0.isEmpty ? nil : $0) }))
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    TOGroupLabel("Per-panel material")
                }
                .tint(Color.to_textTer)
            }

            TOGroupLabel("Tint")
            HStack(spacing: 8) {
                ForEach(leatherSwatches, id: \.0) { hex, name in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(state.constructMaterialHex.caseInsensitiveCompare(hex) == .orderedSame ? Color.to_accent : Color.to_fieldBorder, lineWidth: 2))
                        .onTapGesture { state.setConstructMaterialColor(hex) }
                        .help(name)
                }
            }

            TORow(label: "Thickness") {
                TOStepper(value: Binding(get: { state.constructThicknessMm },
                                         set: { state.setConstructThickness($0) }),
                          unit: "mm", step: 0.1, range: 0.5...8, maxFrac: 1)
            }

            // Finish — surface sheen from matte veg-tan to glossy patent.
            TORow(label: "Finish") {
                TOSegmented(options: finishes,
                            selection: Binding(get: { state.constructFinish },
                                               set: { state.setConstructFinish($0) }))
            }

            // Custom leather texture — a photo / seamless tile used as the albedo.
            HStack(spacing: 8) {
                TOSecondaryButton(title: state.constructLeatherTextureURL == nil ? "Custom texture…" : "Replace texture…",
                                  icon: "photo") {
                    state.loadConstructLeatherTexture()
                }
                if state.constructLeatherTextureURL != nil {
                    Button { state.setConstructLeatherTextureURL(nil) } label: {
                        Image(systemName: "xmark.circle").font(.system(size: 13))
                    }
                    .buttonStyle(.plain).foregroundColor(.to_textMut).help("Remove texture")
                }
            }
            if state.constructLeatherTextureURL != nil {
                framingSlider("Tiling", value: state.constructLeatherTiling, range: 0.5...8) {
                    state.setConstructLeatherTiling($0)
                }
            }

            TODivider()
            artworkSection
        }
    }

    // MARK: Artwork — drop an image, then frame it (move / scale / spin / flip)

    @ViewBuilder
    private var artworkSection: some View {
        TOGroupLabel("Artwork")
        TOHint("Drop an image (PNG/JPG) onto a panel to add it as artwork — visual only, it rides the fold and never changes the cut pattern.")

        if !state.constructDecals.isEmpty {
            // Which panel's art are we framing? Auto-targets the last drop; a
            // picker switches when several panels carry art.
            let pids = state.constructDecals.keys.sorted()
            let active = state.activeDecalPanel.flatMap { pids.contains($0) ? $0 : nil } ?? pids.first
            if pids.count > 1, let active {
                TORow(label: "Framing") {
                    TOSelect(options: pids.map { ($0, "Panel \($0)") },
                             selection: Binding(get: { active },
                                                set: { state.activeDecalPanel = $0 }))
                }
            }
            if let pid = active { decalFraming(pid) }

            TOSecondaryButton(title: "Clear all artwork (\(state.constructDecals.count))",
                              icon: "trash", tint: .to_textMut) {
                state.clearConstructDecals()
            }
        }
    }

    @ViewBuilder
    private func decalFraming(_ pid: Int) -> some View {
        let x = state.decalXform(pid)
        VStack(alignment: .leading, spacing: 10) {
            Text("Framing — panel \(pid)")
                .font(.system(size: 12.5, weight: .semibold)).foregroundColor(.to_textPri)
            framingSlider("Position X", value: x[0], range: -1...1) { state.setDecalXform(pid, 0, $0) }
            framingSlider("Position Y", value: x[1], range: -1...1) { state.setDecalXform(pid, 1, $0) }
            framingSlider("Scale", value: x[2], range: 0.2...3) { state.setDecalXform(pid, 2, $0) }
            framingSlider("Rotation", value: x[3], range: -180...180, unit: "°") { state.setDecalXform(pid, 3, $0) }
            TOCheck(label: "Flip side (mirror)",
                    isOn: Binding(get: { x[4] > 0.5 },
                                  set: { state.setDecalXform(pid, 4, $0 ? 1 : 0) }))
            TOSecondaryButton(title: "Remove from panel \(pid)", icon: "xmark.circle", tint: .to_textMut) {
                state.clearConstructDecal(pid)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.to_field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.to_fieldBorder, lineWidth: 1))
    }

    private func framingSlider(_ label: String, value: Double, range: ClosedRange<Double>,
                               unit: String = "", onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TOLabel(label)
            TOSlider(value: Binding(get: { value }, set: { onChange($0) }),
                     range: range, unit: unit, maxFrac: unit == "°" ? 0 : 2,
                     onBegin: { state.pushConstructUndo() })
        }
    }

    // MARK: Health detail — the actionable "what's wrong" lines (numbers live in the
    // overview strip; this is shown under the Select tool).

    private var healthDetail: some View {
        let h = state.assemblyHealth
        return VStack(alignment: .leading, spacing: 8) {
            readoutRow("Seam length", String(format: "%.0f mm", state.constructSeamLengthMm))
            TODivider()
            if h.ok && h.openChains == 0 {
                healthLine("Everything connected, seams fit", "checkmark.seal.fill", .to_ok)
            } else {
                if h.floating > 0 {
                    healthLine("\(h.floating) panel\(h.floating == 1 ? "" : "s") not attached to the base",
                               "exclamationmark.triangle.fill", .to_warn)
                }
                if h.mismatched > 0 {
                    healthLine("\(h.mismatched) seam\(h.mismatched == 1 ? "" : "s") don't fit",
                               "exclamationmark.triangle.fill", .to_warn)
                }
                if h.openChains > 0 {
                    healthLine("\(h.openChains) hole chain\(h.openChains == 1 ? "" : "s") unstitched",
                               "circle.dashed", .to_textMut)
                }
            }
        }
    }

    private func healthLine(_ text: String, _ icon: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(color)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func readoutRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(.to_textSec)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .foregroundColor(.to_textPri)
        }
    }

    private var stretchSection: some View {
        let pct = state.constructMaxStretchPct
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Solver")
            HStack {
                Text("Max stretch").font(.system(size: 13, weight: .medium)).foregroundColor(.to_textSec)
                Spacer()
                Text(String(format: "%.2f%%", pct))
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundColor(pct < 1 ? .to_ok : .to_warn)
            }
            Text("Leather is inextensible — this should stay near 0%.")
                .font(.system(size: 12, weight: .medium)).foregroundColor(.to_textMut)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        TOGroupLabel(title)
    }
}
