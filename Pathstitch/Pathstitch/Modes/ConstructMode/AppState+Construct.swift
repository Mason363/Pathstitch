import Foundation
import AppKit
import UniformTypeIdentifiers

/// Construct-mode logic on AppState: build the bar-and-hinge model from the live
/// 2D sketch, and push fold / ground controls to the viewport. The interactive
/// solve (folding, no-stretch propagation) happens in `constructViewport.html`;
/// Swift just supplies the rest geometry and the target angles.
extension AppState {

    /// Enters construct mode and (re)builds the model from the current sketch so
    /// edits made in 2D are reflected — the "live sketch" promise.
    func enterConstructMode() {
        activeMode = .construct
        buildConstructModel()
    }

    /// Assemble only the currently selected enclosed area(s) — right-click → "Assemble
    /// Only This Area". Filters by the selected entities' DXF handles.
    func assembleOnlySelectedAreas() {
        guard !selectedHandles.isEmpty else { return }
        constructIncludeHandles = Set(selectedHandles)
        hasUnsavedChanges = true
        enterConstructMode()
    }

    /// Clear the selective filter so every enclosed area assembles again.
    func assembleAllAreas() {
        guard !constructIncludeHandles.isEmpty else { if activeMode != .construct { enterConstructMode() }; return }
        constructIncludeHandles = []
        hasUnsavedChanges = true
        enterConstructMode()
    }

    // MARK: - Guided one-click helpers (Phase 2)

    /// One-click "Assemble": fold every still-flat fold to 90° (the natural box/
    /// upright pose) without disturbing angles the user already set. Hobbyist path.
    func assembleAll() {
        guard !constructFolds.isEmpty else { return }
        pushConstructUndo()
        for i in constructFolds.indices where constructFolds[i].angleDeg == 0 {
            constructFolds[i].angleDeg = 90
        }
        constructFoldStateToken += 1
        hasUnsavedChanges = true
    }

    /// True when there are unstitched chains that could plausibly be auto-paired.
    var canAutoStitch: Bool {
        let seamed = Set(constructSeams.flatMap { [$0.chainA, $0.chainB] })
        return constructHoleChains.filter { !seamed.contains($0.id) }.count >= 2
    }

    /// Auto-propose seams: greedily pair unstitched chains on *different* panels by
    /// closest arc-length (a quick local score — no worker round-trips), then create
    /// a seam for each plausible pair for the user to confirm/adjust. The flagship
    /// matcher (match_chains) still resolves correspondence per created seam.
    func autoProposeSeams() {
        let chains = constructHoleChains
        func arclen(_ c: HoleChain) -> Double {
            guard c.holes.count > 1 else { return 0 }
            var s = 0.0
            for k in 0..<(c.holes.count - 1) {
                s += hypot(c.holes[k+1].x - c.holes[k].x, c.holes[k+1].y - c.holes[k].y)
            }
            if c.closed, let f = c.holes.first, let l = c.holes.last { s += hypot(l.x - f.x, l.y - f.y) }
            return s
        }
        let lens = Dictionary(uniqueKeysWithValues: chains.map { ($0.id, arclen($0)) })
        var used = Set(constructSeams.flatMap { [$0.chainA, $0.chainB] })
        var cands: [(score: Double, a: Int, b: Int)] = []
        for i in 0..<chains.count {
            for j in (i+1)..<chains.count {
                let A = chains[i], B = chains[j]
                if A.panelId == B.panelId { continue }
                let la = lens[A.id] ?? 0, lb = lens[B.id] ?? 0, m = max(la, lb, 1e-6)
                let score = abs(la - lb) / m
                if score < 0.25 { cands.append((score, A.id, B.id)) }   // plausible match
            }
        }
        cands.sort { $0.score < $1.score }
        var created = 0
        for c in cands where !used.contains(c.a) && !used.contains(c.b) {
            createStitch(chainA: c.a, chainB: c.b)   // each pushes undo + runs the matcher
            used.insert(c.a); used.insert(c.b); created += 1
        }
        if created == 0 { errorMessage = "No clearly-matching seams found. Stitch chains manually." }
    }

    /// Assigns how an engulfed area is treated ("stamp" | "patch" | "cutout" |
    /// "independent") and rebuilds so it takes effect. Drives the overlap chooser.
    func setAreaTreatment(inner: String, mode: String) {
        pushConstructUndo()
        constructAreaTreatments[inner] = mode
        pendingEngulfed.removeAll { $0["inner"] == inner }
        hasUnsavedChanges = true
        buildConstructModel()
    }

    /// Triangulates the current panels + fold lines into a construct model and
    /// hands the JSON to the viewport. Folds are auto-detected from a fold/crease
    /// layer in the sketch (see `construct_ops._FOLD_LAYERS`); existing fold
    /// angles are preserved across rebuilds so a live edit doesn't reset the pose.
    func buildConstructModel() {
        // Read-only snapshot of the live sketch — never mutates the 2D file/state
        // (see snapshotSketchForWorker). No sketch yet → nothing to assemble; bail
        // without writing or clobbering anything.
        guard let dxfURL = snapshotSketchForWorker() else {
            isBuildingConstructModel = false
            return
        }
        let ground = constructGroundPanel
        let extraFolds = constructUserFolds.map {
            ["panelId": $0.panelId, "seg": [[$0.x0, $0.y0], [$0.x1, $0.y1]]] as [String: Any]
        }
        let include = Array(constructIncludeHandles)   // empty = all areas
        let treatments = constructAreaTreatments
        isBuildingConstructModel = true

        Task {
            do {
                let res = try await PythonBridge.shared.run(
                    module: "construct_ops",
                    op: "build_construct_model",
                    args: ["input": dxfURL.path, "ground_panel": ground,
                           "extra_folds": extraFolds, "include_handles": include,
                           "area_treatments": treatments]
                )

                let data = res["data"] as? [String: Any]
                let panels = (data?["panels"] as? [[String: Any]]) ?? []
                // No enclosed areas (e.g. the sketch was emptied in 2D) → clear the
                // 3D view instead of erroring or leaving a stale pose.
                guard let data = data, !panels.isEmpty else {
                    await MainActor.run { self.clearConstructModel() }
                    return
                }

                let modelData = try JSONSerialization.data(withJSONObject: data)
                let modelStr = String(data: modelData, encoding: .utf8) ?? ""

                // Derive one FoldSpec per (panelId, foldId) group, keeping any
                // angle the user already dialed in for that fold.
                let prior = self.constructFolds
                var newFolds: [FoldSpec] = []
                for p in panels {
                    let pid = p["id"] as? Int ?? 0
                    let hinges = p["hinges"] as? [[String: Any]] ?? []
                    let foldIds = Set(hinges.compactMap { h -> Int? in
                        guard let f = h["foldId"] as? Int, f >= 0 else { return nil }
                        return f
                    })
                    for fid in foldIds.sorted() {
                        let kept = prior.first { $0.panelId == pid && $0.foldId == fid }
                        newFolds.append(FoldSpec(panelId: pid, foldId: fid,
                                                 angleDeg: kept?.angleDeg ?? 0,
                                                 roundness: kept?.roundness ?? 0))
                    }
                }

                // id → DXF handle (this build) so index-keyed refs migrate by stable
                // handle across rebuilds; allHandles prunes refs to deleted areas.
                var newIdToHandle: [Int: String] = [:]
                for p in panels { if let id = p["id"] as? Int { newIdToHandle[id] = (p["handle"] as? String) ?? String(id) } }
                let newHandleToId = Dictionary(newIdToHandle.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                let allHandles = Set((data["allHandles"] as? [String]) ?? [])

                // Sewing-hole chains, auto-detected from the live sketch.
                var chains: [HoleChain] = []
                if let raw = data["holeChains"],
                   let cd = try? JSONSerialization.data(withJSONObject: raw),
                   let parsed = try? JSONDecoder().decode([HoleChain].self, from: cd) {
                    chains = parsed
                }
                // Keep only seams whose two chains still exist after the rebuild.
                let chainIds = Set(chains.map { $0.id })
                let survivingSeams = self.constructSeams.filter {
                    chainIds.contains($0.chainA) && chainIds.contains($0.chainB)
                }

                // Engulfed (nested) areas → those the user hasn't assigned a
                // treatment to yet drive the chooser prompt. Stamps are surface
                // outlines pushed to the viewport.
                let engulfed = (data["engulfed"] as? [[String: String]]) ?? []
                let undecided = engulfed.filter { e in
                    guard let inner = e["inner"] else { return false }
                    return self.constructAreaTreatments[inner] == nil
                }
                var stampsStr = "[]"
                if let raw = data["stamps"],
                   let sd = try? JSONSerialization.data(withJSONObject: raw),
                   let s = String(data: sd, encoding: .utf8) { stampsStr = s }

                await MainActor.run {
                    // Reconcile index-keyed refs to the rebuilt panels: migrate by
                    // DXF handle (panel ids renumber after a 2D delete), dropping any
                    // whose area was deleted in 2D — so nothing ghosts. (No history →
                    // keep ids that are still valid, e.g. first build after reopen.)
                    let oldMap = self.constructPanelHandles
                    func mapId(_ id: Int) -> Int? {
                        if let h = oldMap[id] { return newHandleToId[h] }
                        return newIdToHandle[id] != nil ? id : nil
                    }
                    self.constructDecals = Dictionary(self.constructDecals.compactMap { k, v in mapId(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
                    self.constructDecalXforms = Dictionary(self.constructDecalXforms.compactMap { k, v in mapId(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
                    self.constructBaseRegions = Dictionary(self.constructBaseRegions.compactMap { k, v in mapId(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
                    self.constructGlues = self.constructGlues.compactMap { g in
                        guard let a = mapId(g.panelA), let b = mapId(g.panelB) else { return nil }
                        var gg = g; gg.panelA = a; gg.panelB = b; return gg
                    }
                    if let ap = self.activeDecalPanel { self.activeDecalPanel = mapId(ap) }
                    self.constructIncludeHandles = self.constructIncludeHandles.intersection(allHandles)
                    self.constructAreaTreatments = self.constructAreaTreatments.filter { allHandles.contains($0.key) }
                    self.constructPanelXf = self.constructPanelXf.filter { allHandles.contains($0.key) }
                    self.constructPanelHandles = newIdToHandle

                    self.constructModelJSON = modelStr
                    self.constructFolds = newFolds
                    self.constructHoleChains = chains
                    self.constructSeams = survivingSeams
                    self.pendingEngulfed = undecided
                    self.constructStampsJSON = stampsStr
                    self.constructStampToken += 1
                    self.constructModelToken += 1
                    self.constructFoldStateToken += 1   // re-apply ground + angles to the new mesh
                    self.constructSeamStateToken += 1   // re-apply seams to the new mesh
                    self.isBuildingConstructModel = false
                    // Just creased? Select that panel's newest fold so the angle
                    // slider is right there — visible proof the crease landed.
                    if let cp = self.pendingCreaseSelectPanel {
                        self.pendingCreaseSelectPanel = nil
                        if let newest = newFolds.filter({ $0.panelId == cp }).max(by: { $0.foldId < $1.foldId }) {
                            self.selectedFoldId = newest.id
                        }
                    }
                }
                // Refresh each surviving seam's correspondence against the new
                // hole counts (a 2D edit can change how many holes a seam has).
                for seam in survivingSeams { self.rematchSeam(seam.id) }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isBuildingConstructModel = false
                }
            }
        }
    }

    // MARK: - Assembly undo/redo (the panel's own history)

    var canUndoConstruct: Bool { !constructUndoStack.isEmpty }
    var canRedoConstruct: Bool { !constructRedoStack.isEmpty }

    private func snapshotConstruct() -> ConstructUndoState {
        ConstructUndoState(groundPanel: constructGroundPanel, folds: constructFolds,
                           seams: constructSeams, glues: constructGlues,
                           userFolds: constructUserFolds, materialHex: constructMaterialHex,
                           thicknessMm: constructThicknessMm,
                           materialId: constructMaterialId, temper: constructTemper,
                           thicknessOz: constructThicknessOz, kFactor: constructKFactor,
                           minBendRadiusMm: constructMinBendRadiusMm,
                           decals: constructDecals,
                           decalXforms: constructDecalXforms,
                           includeHandles: constructIncludeHandles,
                           areaTreatments: constructAreaTreatments,
                           baseRegions: constructBaseRegions,
                           panelXf: constructPanelXf)
    }

    /// Record the current assembly state before a mutating edit, so Cmd-Z can undo
    /// it. Coalesce identical back-to-back snapshots (e.g. a slider re-press).
    func pushConstructUndo() {
        let snap = snapshotConstruct()
        if let last = constructUndoStack.last, sameConstruct(last, snap) { return }
        constructUndoStack.append(snap)
        if constructUndoStack.count > 100 { constructUndoStack.removeFirst() }
        constructRedoStack.removeAll()
    }

    private func sameConstruct(_ a: ConstructUndoState, _ b: ConstructUndoState) -> Bool {
        a.groundPanel == b.groundPanel && a.folds == b.folds && a.seams == b.seams
        && a.glues == b.glues && a.userFolds == b.userFolds && a.materialHex == b.materialHex
        && a.thicknessMm == b.thicknessMm && a.materialId == b.materialId
        && a.kFactor == b.kFactor && a.minBendRadiusMm == b.minBendRadiusMm
        && a.decals == b.decals && a.decalXforms == b.decalXforms
        && a.includeHandles == b.includeHandles && a.areaTreatments == b.areaTreatments
        && a.baseRegions == b.baseRegions && a.panelXf == b.panelXf
    }

    private func applyConstruct(_ s: ConstructUndoState) {
        constructGroundPanel = s.groundPanel
        constructFolds = s.folds
        constructSeams = s.seams
        constructGlues = s.glues
        constructMaterialHex = s.materialHex
        constructThicknessMm = s.thicknessMm
        constructMaterialId = s.materialId
        constructTemper = s.temper
        constructThicknessOz = s.thicknessOz
        constructKFactor = s.kFactor
        constructMinBendRadiusMm = s.minBendRadiusMm
        constructDecals = s.decals
        constructDecalXforms = s.decalXforms
        // userFolds / include set / area treatments change the topology → rebuild;
        // otherwise just re-push controls.
        let topologyChanged = (s.userFolds != constructUserFolds)
            || (s.includeHandles != constructIncludeHandles)
            || (s.areaTreatments != constructAreaTreatments)
        let baseChanged = (s.baseRegions != constructBaseRegions)
        constructUserFolds = s.userFolds
        constructIncludeHandles = s.includeHandles
        constructAreaTreatments = s.areaTreatments
        constructBaseRegions = s.baseRegions
        let xfChanged = (s.panelXf != constructPanelXf)
        constructPanelXf = s.panelXf
        if selectedFoldId != nil && !constructFolds.contains(where: { $0.id == selectedFoldId }) {
            selectedFoldId = nil
        }
        hasUnsavedChanges = true
        if topologyChanged {
            buildConstructModel()
        } else {
            constructFoldStateToken += 1
            constructSeamStateToken += 1
            constructMaterialToken += 1
            constructDecalToken += 1
            if baseChanged { constructBaseToken += 1 }
            if xfChanged { constructPanelXfToken += 1 }
        }
    }

    func undoConstruct() {
        guard let prev = constructUndoStack.popLast() else { return }
        constructRedoStack.append(snapshotConstruct())
        applyConstruct(prev)
    }

    func redoConstruct() {
        guard let next = constructRedoStack.popLast() else { return }
        constructUndoStack.append(snapshotConstruct())
        applyConstruct(next)
    }

    /// Sets a fold's target angle and pushes it live to the solver.
    func setConstructFoldAngle(_ id: FoldSpec.ID, _ deg: Double) {
        guard let i = constructFolds.firstIndex(where: { $0.id == id }) else { return }
        constructFolds[i].angleDeg = deg
        constructFoldStateToken += 1
        hasUnsavedChanges = true
    }

    /// Sets a fold's angle by (panelId, foldId) — used by direct drag-to-fold in 3D,
    /// which reports the final angle on release. The viewport already applied it live
    /// (and the inspector slider reads `angleDeg` directly via @Observable), so we do
    /// NOT bump the push token — no redundant re-pose round-trip (mirrors panelXf).
    func setConstructFoldAngleByIds(panelId: Int, foldId: Int, deg: Double) {
        guard let i = constructFolds.firstIndex(where: { $0.panelId == panelId && $0.foldId == foldId }),
              abs(constructFolds[i].angleDeg - deg) > 1e-6 else { return }
        pushConstructUndo()                 // snapshot is pre-drag (Swift held the old angle until now)
        constructFolds[i].angleDeg = deg
        hasUnsavedChanges = true
    }

    /// Sets a fold's roundness (0 sharp … 1 round) and re-poses.
    func setConstructFoldRoundness(_ id: FoldSpec.ID, _ r: Double) {
        guard let i = constructFolds.firstIndex(where: { $0.id == id }) else { return }
        constructFolds[i].roundness = max(0, min(1, r))
        constructFoldStateToken += 1
        hasUnsavedChanges = true
    }

    /// Pins a panel as ground and, if a face point is given, sets that panel's base
    /// region — the side that stays flat. Clicking a different face re-roots its fold
    /// tree there ("creases create planes; pick which plane is the base").
    func setConstructGround(_ panelId: Int, basePoint: [Double]? = nil) {
        let sameGround = (panelId == constructGroundPanel)
        let samebase = (basePoint == nil) || (constructBaseRegions[panelId] == basePoint)
        guard !sameGround || !samebase else { return }
        pushConstructUndo()
        constructGroundPanel = panelId
        if let bp = basePoint, bp.count == 2 { constructBaseRegions[panelId] = bp }
        constructFoldStateToken += 1   // ground is pushed alongside the fold angles
        constructBaseToken += 1
        hasUnsavedChanges = true
    }

    /// {panelId: [x,y]} base-region points for the viewport to re-root fold trees.
    var constructBaseJSON: String {
        var obj: [String: [Double]] = [:]
        for (pid, pt) in constructBaseRegions { obj[String(pid)] = pt }
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// {handle: [tx,ty,tz, qx,qy,qz,qw, s]} per-panel pose overrides for the viewport.
    var constructPanelXfJSON: String {
        guard let d = try? JSONSerialization.data(withJSONObject: constructPanelXf),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Stores a panel pose override reported by the gizmo (handle-keyed → survives
    /// 2D edits). Pose only; the 2D sketch is untouched.
    func setPanelTransform(handle: String, t: [Double], q: [Double], s: Double) {
        guard t.count == 3, q.count == 4 else { return }
        pushConstructUndo()
        constructPanelXf[handle] = [t[0], t[1], t[2], q[0], q[1], q[2], q[3], s]
        hasUnsavedChanges = true
        // No token bump: the viewport already applied it live; this just persists.
    }

    /// Requests an export (format "step" | "stl"); the viewport bridge gathers the
    /// folded geometry, writes the file via OCC, and shows a save panel.
    func exportConstruct(_ format: String) {
        constructExportFormat = format
        constructExportToken += 1
    }

    /// Sets the transform gizmo mode (translate / rotate / scale) and pushes it.
    func setConstructTransformMode(_ m: String) {
        constructTransformMode = m
        constructTransformModeToken += 1
    }

    // MARK: - Assembly readouts + health (item 8: make it genuinely useful)

    /// Total stitched-seam length (mm), averaging each seam's two chains.
    var constructSeamLengthMm: Double {
        constructSeams.reduce(0) { $0 + ($1.lenA + $1.lenB) * 0.5 }
    }
    /// Total stitches across all seams (hole pairs ≈ stitch passes).
    var constructStitchCount: Int {
        constructSeams.reduce(0) { $0 + max($1.holesA, $1.holesB) }
    }
    /// Assembly health: panels not connected to ground (by fold/seam/glue), hole
    /// chains left unstitched, and seams that don't fit. `ok` when nothing's wrong.
    var assemblyHealth: (floating: Int, openChains: Int, mismatched: Int, ok: Bool) {
        let ids = Set(constructPanelHandles.keys)
        guard !ids.isEmpty else { return (0, 0, 0, true) }
        var adj: [Int: Set<Int>] = [:]
        for s in constructSeams {
            let pa = constructHoleChains.first { $0.id == s.chainA }?.panelId
            let pb = constructHoleChains.first { $0.id == s.chainB }?.panelId
            if let a = pa, let b = pb { adj[a, default: []].insert(b); adj[b, default: []].insert(a) }
        }
        for g in constructGlues { adj[g.panelA, default: []].insert(g.panelB); adj[g.panelB, default: []].insert(g.panelA) }
        var seen: Set<Int> = [constructGroundPanel]
        var q = [constructGroundPanel]
        while let r = q.popLast() { for n in adj[r] ?? [] where !seen.contains(n) { seen.insert(n); q.append(n) } }
        let floating = ids.subtracting(seen).count
        let seamedChains = Set(constructSeams.flatMap { [$0.chainA, $0.chainB] })
        let openChains = constructHoleChains.filter { !seamedChains.contains($0.id) }.count
        let mismatched = constructSeams.filter { $0.verdict == .mismatch }.count
        return (floating, openChains, mismatched, floating == 0 && mismatched == 0)
    }

    /// Clears all per-panel pose overrides (back to the seated pose).
    func clearConstructPanelTransforms() {
        guard !constructPanelXf.isEmpty else { return }
        pushConstructUndo()
        constructPanelXf.removeAll()
        constructPanelXfToken += 1   // push the (empty) set so the viewport resets
        hasUnsavedChanges = true
    }

    /// Switches the active construct tool (changes click behavior in the viewport).
    func setConstructTool(_ tool: ConstructTool) {
        constructTool = tool
        constructToolToken += 1
    }

    /// Recenters / frames the assembly.
    func constructHome() {
        triggerConstructHomeToken += 1
    }


    /// Sets the mockup leather colour (hex like "8A5A2B") and pushes it live.
    func setConstructMaterialColor(_ hex: String) {
        guard hex != constructMaterialHex else { return }
        pushConstructUndo()
        constructMaterialHex = hex
        constructMaterialToken += 1
        hasUnsavedChanges = true
    }

    /// Sets the mockup material thickness (mm) and re-shells the panels.
    func setConstructThickness(_ mm: Double) {
        constructThicknessMm = mm
        constructMaterialToken += 1
        hasUnsavedChanges = true
    }

    // MARK: - Physical leather (Phase 1 — Material & Bend-Allowance Foundation)

    /// Picks a physical leather from `LeatherStore`: sets thickness, default tint,
    /// and the physical properties (temper, K-factor, min bend radius) that drive
    /// bend allowance and the fold-radius DFM. Thickness and tint stay overridable.
    func selectConstructMaterial(_ m: LeatherMaterial) {
        pushConstructUndo()
        constructMaterialId = m.id
        constructTemper = m.temper
        constructThicknessOz = m.thicknessOz
        constructThicknessMm = m.thicknessMm
        constructKFactor = m.kFactor
        constructMinBendRadiusMm = m.minBendRadiusMm
        constructMaterialHex = m.colorHex
        constructMaterialToken += 1
        hasUnsavedChanges = true
    }

    /// The leather currently selected (nil for older / custom assemblies).
    var constructLeather: LeatherMaterial? {
        constructMaterialId.flatMap { LeatherStore.shared.material(id: $0) }
    }

    // MARK: Multi-material (Phase 2) — per-panel leather

    /// The leather a panel is made of — its per-panel override, else nil (the panel
    /// uses the assembly default). Keyed by DXF handle so it survives 2D edits.
    func leatherForPanel(_ panelId: Int) -> LeatherMaterial? {
        guard let handle = constructPanelHandles[panelId],
              let id = constructPanelMaterials[handle] else { return nil }
        return LeatherStore.shared.material(id: id)
    }

    /// Assigns (leatherId) or clears (nil) a panel's leather and re-pushes material.
    func setConstructPanelMaterial(_ panelId: Int, _ leatherId: String?) {
        guard let handle = constructPanelHandles[panelId] else { return }
        if let id = leatherId, !id.isEmpty { constructPanelMaterials[handle] = id }
        else { constructPanelMaterials.removeValue(forKey: handle) }
        constructMaterialToken += 1
        hasUnsavedChanges = true
    }

    /// Bend inputs (thickness, K-factor, min radius) for a fold — the fold's panel
    /// material when set (multi-material), else the assembly default. So a firm
    /// stiffener patch folds to its own radius, not the soft body's.
    private func bendParams(for spec: FoldSpec) -> (t: Double, k: Double, minR: Double) {
        if let m = leatherForPanel(spec.panelId) {
            return (m.thicknessMm, m.kFactor, m.minBendRadiusMm)
        }
        return (constructThicknessMm, constructKFactor, constructMinBendRadiusMm)
    }

    /// One fold's inside bend radius, derived from its roundness and the leather:
    /// even a "sharp" leather fold has a natural inside radius near half the
    /// thickness (you can't crease thick stock to a knife edge), and rounding it
    /// opens the radius toward a comfortable maximum. Drives both the bend
    /// allowance and the min-radius check. (The Python `fold_metrics` op is pure
    /// physics and takes this radius explicitly; this is the app-side policy.)
    func constructFoldRadius(_ spec: FoldSpec) -> Double {
        let p = bendParams(for: spec)
        let comfortable = max(p.minR * 4, p.t * 3)
        return max(p.t * 0.5, spec.roundness * comfortable)
    }

    /// Bend allowance for one fold — the developed neutral-axis arc, mm. Mirrors
    /// `construct_ops.bend_allowance`: BA = θ·(R + K·T).
    func constructBendAllowance(_ spec: FoldSpec) -> Double {
        let p = bendParams(for: spec)
        let theta = abs(spec.angleDeg) * .pi / 180.0
        return theta * (constructFoldRadius(spec) + p.k * p.t)
    }

    /// Bend deduction for one fold — flat length = outside flange sum − BD. Mirrors
    /// `construct_ops.bend_deduction`.
    func constructBendDeduction(_ spec: FoldSpec) -> Double {
        let p = bendParams(for: spec)
        let a = min(abs(spec.angleDeg), 179.0) * .pi / 180.0
        let r = constructFoldRadius(spec)
        let ossb = tan(a / 2.0) * (r + p.t)
        return 2.0 * ossb - constructBendAllowance(spec)
    }

    /// True when a fold's inside radius meets its panel's leather minimum (a flat
    /// fold is trivially safe). A soft check — surfaced as a warning, never a block.
    func constructFoldRadiusOK(_ spec: FoldSpec) -> Bool {
        if abs(spec.angleDeg) <= 1e-6 { return true }
        let p = bendParams(for: spec)
        return p.minR <= 0 || constructFoldRadius(spec) + 1e-9 >= p.minR
    }

    /// Bent folds whose inside radius is tighter than the leather minimum.
    var constructTightFolds: [FoldSpec] {
        constructFolds.filter { abs($0.angleDeg) > 0.5 && !constructFoldRadiusOK($0) }
    }

    /// Total bend allowance across all bent folds (mm).
    var constructTotalBendAllowance: Double {
        constructFolds.filter { abs($0.angleDeg) > 0.5 }
            .reduce(0) { $0 + constructBendAllowance($1) }
    }

    /// Total bend deduction across all bent folds (mm).
    var constructTotalBendDeduction: Double {
        constructFolds.filter { abs($0.angleDeg) > 0.5 }
            .reduce(0) { $0 + constructBendDeduction($1) }
    }

    /// Hex string → 0xRRGGBB int for the viewport.
    var constructMaterialColorInt: Int {
        Int(constructMaterialHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8A5A2B
    }

    // MARK: - Mockup rendering (render mode + finish + custom texture + lighting)

    /// Switches between the editing view and the clean Mockup beauty render.
    func setConstructRenderMode(_ m: String) {
        guard m != constructRenderMode else { return }
        constructRenderMode = m
        constructRenderToken += 1
        hasUnsavedChanges = true
    }

    /// How panels are shaded (wireframe / solid / flat / realistic), independent
    /// of edit/mockup. Pushed live to the viewport.
    func setConstructShaderMode(_ m: String) {
        guard m != constructShaderMode else { return }
        constructShaderMode = m
        constructShaderToken += 1
        hasUnsavedChanges = true
    }

    /// Cutting-mat config for the Assembly viewport — encodes the shared mat state
    /// so the 3D mat matches the 2D mat exactly.
    var constructMatJSON: String {
        let obj: [String: Any] = [
            "enabled": matEnabled,
            "w": matWidthMm,
            "h": matHeightMm,
            "gridVisible": matGridVisible,
            "spacing": matGridSpacingMm,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Leather finish preset (matte / satin / glossy); pushed with the material.
    func setConstructFinish(_ name: String) {
        guard name != constructFinish else { return }
        constructFinish = name
        constructMaterialToken += 1   // pushMaterial re-applies finish too
        hasUnsavedChanges = true
    }

    /// Opens an image and uses it as the custom leather albedo (tiled, visual-only).
    func loadConstructLeatherTexture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { resp in
            guard resp == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            let ext = url.pathExtension.lowercased()
            let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                        "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp"][ext] ?? "image/jpeg"
            let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
            DispatchQueue.main.async { self.setConstructLeatherTextureURL(dataURL) }
        }
    }

    /// Sets / clears the custom leather texture and pushes it live.
    func setConstructLeatherTextureURL(_ url: String?) {
        constructLeatherTextureURL = url
        constructTextureToken += 1
        hasUnsavedChanges = true
    }
    /// Tiling (repeats per panel) for the custom leather texture.
    func setConstructLeatherTiling(_ t: Double) {
        constructLeatherTiling = max(0.25, t)
        constructTextureToken += 1
        hasUnsavedChanges = true
    }

    /// {ambient, lights:[{color,intensity,rotation,height,softness,on}]} for the viewport.
    var constructLightingJSON: String {
        let lights = constructLights.map { l -> [String: Any] in
            let c = Int(l.colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
            return ["color": c, "intensity": l.intensity, "rotation": l.rotation,
                    "height": l.height, "softness": l.softness, "on": l.on]
        }
        let payload: [String: Any] = ["ambient": constructAmbient, "lights": lights]
        guard let d = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Applies one of the named lighting presets (Standard / Diffuse / Top-Left / Right).
    func applyLightPreset(_ preset: ConstructLightPreset) {
        constructLights = preset.lights
        constructAmbient = preset.ambient
        activeLightIndex = 0
        constructLightingToken += 1
        hasUnsavedChanges = true
    }

    /// Mutate the currently-edited light and re-push the lighting live.
    private func updateActiveLight(_ f: (inout ConstructLight) -> Void) {
        guard constructLights.indices.contains(activeLightIndex) else { return }
        f(&constructLights[activeLightIndex])
        constructLightingToken += 1
        hasUnsavedChanges = true
    }
    func setLightColor(_ hex: String)   { updateActiveLight { $0.colorHex = hex } }
    func setLightIntensity(_ v: Double)  { updateActiveLight { $0.intensity = v } }
    func setLightSoftness(_ v: Double)   { updateActiveLight { $0.softness = v } }
    func setLightOn(_ on: Bool)          { updateActiveLight { $0.on = on } }
    /// The sphere-drag and the rotation/height sliders both set the light direction.
    func setLightDirection(rotation: Double, height: Double) {
        updateActiveLight { $0.rotation = rotation; $0.height = height }
    }
    func setActiveLight(_ i: Int) { if constructLights.indices.contains(i) { activeLightIndex = i } }
    /// Sets the global ambient fill (0 = dramatic … high = flat/soft).
    func setConstructAmbient(_ v: Double) {
        constructAmbient = max(0, min(1, v))
        constructLightingToken += 1
        hasUnsavedChanges = true
    }
    /// Adds a light (copied from the active one) and selects it for editing.
    func addConstructLight() {
        var l = constructLights.indices.contains(activeLightIndex) ? constructLights[activeLightIndex] : ConstructLight()
        l.id = UUID(); l.rotation = (l.rotation + 90).truncatingRemainder(dividingBy: 360)
        constructLights.append(l)
        activeLightIndex = constructLights.count - 1
        constructLightingToken += 1
        hasUnsavedChanges = true
    }
    /// Removes a light (keeps at least one).
    func removeConstructLight(_ i: Int) {
        guard constructLights.count > 1, constructLights.indices.contains(i) else { return }
        constructLights.remove(at: i)
        activeLightIndex = min(activeLightIndex, constructLights.count - 1)
        constructLightingToken += 1
        hasUnsavedChanges = true
    }

    // MARK: - Fold side (which stays flat) + artwork placement

    /// {panelId,foldId} of the selected fold for the viewport's side highlight.
    var constructSelFoldJSON: String {
        guard let id = selectedFoldId,
              let f = constructFolds.first(where: { $0.id == id }),
              let d = try? JSONSerialization.data(withJSONObject: ["panelId": f.panelId, "foldId": f.foldId]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Stores the viewport's reported region centroids + 2D segment for the selected fold.
    func setFoldSides(panelId: Int, base: [Double], move: [Double], seg: [[Double]]? = nil) {
        lastFoldSides = (panelId, base, move)
        lastFoldSeg = (seg?.count == 2) ? seg : nil
    }

    /// Repositions (newSeg) or deletes (newSeg = nil) the FOLD-layer LINE matching
    /// `oldSeg` in the 2D sketch, then rebuilds — crease drag / delete from 3D.
    func editFoldLine(oldSeg: [[Double]], newSeg: [[Double]]?) {
        guard oldSeg.count == 2 else { return }
        saveToHistory()                       // 2D history owns this geometry edit
        let url = ensureActiveDXFFileExists()
        isBuildingConstructModel = true
        Task {
            do {
                await reconcileBufferIfNeeded()
                var args: [String: Any] = ["input": url.path, "output": url.path, "old_seg": oldSeg]
                if let ns = newSeg, ns.count == 2 { args["new_seg"] = ns }
                _ = try await PythonBridge.shared.run(module: "dxf_ops", op: "edit_fold_line", args: args)
                await MainActor.run {
                    self.reloadDXF()
                    self.buildConstructModel()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isBuildingConstructModel = false
                }
            }
        }
    }

    /// Deletes the currently selected fold's line from the 2D sketch (3D Delete).
    func deleteSelectedFold() {
        guard let seg = lastFoldSeg, seg.count == 2 else { return }
        editFoldLine(oldSeg: seg, newSeg: nil)
        selectedFoldId = nil
        lastFoldSeg = nil
    }

    /// Flip which side of the selected fold stays flat: re-root the panel at the side
    /// that's currently folding (reuses the base-region mechanism; Ground tool still works).
    func flipFoldSide() {
        guard let fs = lastFoldSides, fs.move.count == 2 else { return }
        setConstructGround(fs.panelId, basePoint: fs.move)
    }

    /// Drop an image → enter artwork placement (bird's-eye; click a body to place it).
    func enterArtworkPlacement(_ dataURL: String) {
        if constructRenderMode != "edit" { setConstructRenderMode("edit") }
        pendingArtworkURL = dataURL
        constructArtworkMode = true
        constructArtworkToken += 1
        hasUnsavedChanges = true
    }
    /// Leave artwork placement (restores the camera).
    func exitArtworkPlacement() {
        guard constructArtworkMode else { return }
        constructArtworkMode = false
        pendingArtworkURL = nil
        constructArtworkToken += 1
    }
    /// Transient artwork command pushed to the viewport ("fill" | "flipface" | "mirror").
    func artworkCommand(_ cmd: String) {
        constructArtworkCmd = cmd
        constructArtworkCmdToken += 1
    }
    /// Store a framing reported live from the viewport (drag / fill / flip) WITHOUT
    /// re-pushing decals — the viewport already applied it (mirrors the panelXf path).
    func storeDecalFrame(panelId: Int, ox: Double, oy: Double, scale: Double, rot: Double, mirror: Double, side: Double) {
        constructDecalXforms[panelId] = [ox, oy, scale, rot, mirror, side]
        if constructDecals[panelId] != nil { activeDecalPanel = panelId }
        hasUnsavedChanges = true
    }

    /// Clears the 3D assembly when the sketch has no enclosed areas (e.g. everything
    /// was deleted in 2D) — pushes an empty model so the viewport shows nothing,
    /// instead of leaving a stale pose or erroring.
    func clearConstructModel() {
        constructModelJSON = "{\"panels\":[],\"groundPanel\":0}"
        constructFolds = []
        constructHoleChains = []
        constructSeams = []
        constructStampsJSON = "[]"
        pendingEngulfed = []
        constructPanelHandles = [:]
        selectedFoldId = nil
        constructModelToken += 1
        constructFoldStateToken += 1
        constructSeamStateToken += 1
        constructStampToken += 1
        isBuildingConstructModel = false
    }

    /// {panelId: {url, ox, oy, scale, rot, mirror}} for the viewport to re-apply
    /// artwork decals *with their framing* (offset / scale / rotation / flip).
    var constructDecalsJSON: String {
        var obj: [String: Any] = [:]
        for (pid, url) in constructDecals {
            let x = decalXform(pid)
            obj[String(pid)] = ["url": url, "ox": x[0], "oy": x[1],
                                "scale": x[2], "rot": x[3], "mirror": x[4], "side": x[5]]
        }
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Removes one panel's artwork (the viewport reconciles the removal).
    func clearConstructDecal(_ pid: Int) {
        pushConstructUndo()
        constructDecals.removeValue(forKey: pid)
        constructDecalXforms.removeValue(forKey: pid)
        if activeDecalPanel == pid { activeDecalPanel = nil }
        constructDecalToken += 1
        hasUnsavedChanges = true
    }

    /// Clears all artwork decals (the viewport reconciles removals).
    func clearConstructDecals() {
        pushConstructUndo()
        constructDecals.removeAll()
        constructDecalXforms.removeAll()
        activeDecalPanel = nil
        constructDecalToken += 1
        hasUnsavedChanges = true
    }

    /// A fold line drawn in 3D becomes a real **FOLD-layer LINE in the 2D sketch**,
    /// so it shows up (and is editable / deletable) back in 2D and is read straight
    /// back as a hinge — persistent + parametric, not a hidden side list. Removal is
    /// done in 2D (delete the line, or 2D undo). `panelId` only drives which panel's
    /// new fold gets auto-selected after the rebuild.
    func addConstructUserFold(panelId: Int, x0: Double, y0: Double, x1: Double, y1: Double) {
        guard hypot(x1 - x0, y1 - y0) > 1.0 else { return }   // ignore a stray double-click
        saveToHistory()                       // 2D history owns this geometry edit
        let url = ensureActiveDXFFileExists()
        pendingCreaseSelectPanel = panelId
        isBuildingConstructModel = true
        Task {
            do {
                await reconcileBufferIfNeeded()
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops", op: "add_entity",
                    args: ["input": url.path, "output": url.path, "type": "line",
                           "params": ["start": [x0, y0], "end": [x1, y1]], "layer": "FOLD"])
                await MainActor.run {
                    self.reloadDXF()            // surface the new fold line in 2D
                    self.buildConstructModel()  // re-pose; reads the FOLD line as a hinge
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isBuildingConstructModel = false
                }
            }
        }
    }

    /// Removes the most recently added 3D fold line.
    func undoLastUserFold() {
        guard !constructUserFolds.isEmpty else { return }
        pushConstructUndo()
        constructUserFolds.removeLast()
        buildConstructModel()
    }

    /// Glue tool: pick a face/edge on panel A, then on panel B → bond per the
    /// current glue mode. `p2d` is the clicked point (selects the face/edge);
    /// `side` is which visible side was clicked (±1, winding-relative).
    func pickPanelForGlue(_ panelId: Int, _ p2d: [Double]? = nil, _ side: Double = 0) {
        if let first = selectedPanelForGlue {
            let firstPt = selectedGluePoint
            let firstSide = selectedGlueSide
            selectedPanelForGlue = nil; selectedGluePoint = nil; selectedGlueSide = 0
            if first != panelId {
                addGlue(panelA: first, panelB: panelId, aPt: firstPt, bPt: p2d,
                        aSide: firstSide, bSide: side)
            }
            constructSeamStateToken += 1
        } else {
            selectedPanelForGlue = panelId
            selectedGluePoint = p2d
            selectedGlueSide = side
            constructSeamStateToken += 1
        }
    }

    /// Sets the glue mode (panel / face / edge) for the next bond. Bumps the seam
    /// token too so the viewport re-pushes (the live highlight is mode-aware).
    func setConstructGlueMode(_ m: String) {
        constructGlueMode = m
        constructGlueModeToken += 1
        constructSeamStateToken += 1
    }

    func addGlue(panelA: Int, panelB: Int, aPt: [Double]? = nil, bPt: [Double]? = nil,
                 aSide: Double = 0, bSide: Double = 0) {
        guard !constructGlues.contains(where: {
            ($0.panelA == panelA && $0.panelB == panelB) ||
            ($0.panelA == panelB && $0.panelB == panelA) }) else { return }
        pushConstructUndo()
        constructGlues.append(GlueJoint(panelA: panelA, panelB: panelB,
                                        mode: constructGlueMode, aPt: aPt, bPt: bPt,
                                        aSide: aSide, bSide: bSide))
        constructSeamStateToken += 1
        hasUnsavedChanges = true
    }

    func removeGlue(_ id: GlueJoint.ID) {
        pushConstructUndo()
        constructGlues.removeAll { $0.id == id }
        constructSeamStateToken += 1
        hasUnsavedChanges = true
    }

    /// Serialized {groundPanel, folds:[{panelId,foldId,angleDeg}]} for the bridge.
    var constructControlsJSON: String {
        let folds = constructFolds.map {
            ["panelId": $0.panelId, "foldId": $0.foldId, "angleDeg": $0.angleDeg,
             "roundness": $0.roundness] as [String: Any]
        }
        let payload: [String: Any] = ["groundPanel": constructGroundPanel,
                                      "folds": folds]
        guard let d = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - Stitch flagship

    /// A chain the user clicked/selected for stitching. First pick is remembered;
    /// the second pick creates the seam. Picking the same chain twice clears it.
    func pickChainForStitch(_ chainId: Int) {
        guard constructHoleChains.contains(where: { $0.id == chainId }) else { return }
        if let first = selectedChainForStitch {
            selectedChainForStitch = nil
            constructSeamStateToken += 1            // clear the highlight
            if first != chainId { createStitch(chainA: first, chainB: chainId) }
        } else {
            selectedChainForStitch = chainId
            constructSeamStateToken += 1            // light up the picked chain
        }
    }

    /// Stitches chain A to chain B: runs the auto-matcher (arc-length
    /// correspondence + mismatch analysis) and adds the seam. Chain B is the one
    /// pulled onto chain A in the viewport.
    func createStitch(chainA: Int, chainB: Int) {
        guard chainA != chainB,
              !constructSeams.contains(where: {
                  ($0.chainA == chainA && $0.chainB == chainB) ||
                  ($0.chainA == chainB && $0.chainB == chainA) }) else { return }
        pushConstructUndo()
        let seam = StitchSeam(chainA: chainA, chainB: chainB)
        constructSeams.append(seam)
        hasUnsavedChanges = true
        constructSeamStateToken += 1
        let sid = seam.id
        Task { await self.matchSeam(sid) }   // correspondence resolves asynchronously
    }

    /// Re-runs the matcher for an existing seam (e.g. after a live sketch edit).
    func rematchSeam(_ seamId: StitchSeam.ID) {
        Task { await self.matchSeam(seamId) }
    }

    /// Calls `construct_ops.match_chains` for one seam and stores the result.
    private func matchSeam(_ seamId: StitchSeam.ID) async {
        guard let seam = await MainActor.run(body: { self.constructSeams.first { $0.id == seamId } }),
              let ca = await MainActor.run(body: { self.constructHoleChains.first { $0.id == seam.chainA } }),
              let cb = await MainActor.run(body: { self.constructHoleChains.first { $0.id == seam.chainB } })
        else { return }

        let ptsA = ca.holes.map { [$0.x, $0.y] }
        let ptsB = cb.holes.map { [$0.x, $0.y] }
        let anchors = seam.anchors ?? []
        let flip = seam.flip ?? false
        do {
            let res = try await PythonBridge.shared.run(
                module: "construct_ops", op: "match_chains",
                args: ["chainA": ptsA, "chainB": ptsB,
                       "closedA": ca.closed, "closedB": cb.closed,
                       "anchors": anchors, "flip": flip])
            guard let data = res["data"] as? [String: Any] else { return }
            let pairs = (data["pairs"] as? [[Int]]) ?? []
            let lenA = (data["lenA"] as? Double) ?? 0
            let lenB = (data["lenB"] as? Double) ?? 0
            let mismatch = (data["mismatch"] as? Double) ?? 0
            let reversed = (data["reversed"] as? Bool) ?? false
            let nA = ca.holes.count, nB = cb.holes.count
            await MainActor.run {
                guard let i = self.constructSeams.firstIndex(where: { $0.id == seamId }) else { return }
                self.constructSeams[i].pairs = pairs
                self.constructSeams[i].lenA = lenA
                self.constructSeams[i].lenB = lenB
                self.constructSeams[i].mismatch = mismatch
                self.constructSeams[i].reversed = reversed
                self.constructSeams[i].holesA = nA   // counts known now; gap fills after pose
                self.constructSeams[i].holesB = nB
                self.constructSeamStateToken += 1
            }
        } catch {
            // matching failure leaves the seam un-paired; the viewport just won't
            // draw thread for it. Surface quietly.
            await MainActor.run { self.errorMessage = "Stitch match failed: \(error.localizedDescription)" }
        }
    }

    /// Applies the viewport's live fit report (gap after seating + hole counts)
    /// onto the matching seams, so the inspector verdict reflects the real pose.
    func applySeamFit(_ fits: [[String: Any]]) {
        // Mutating constructSeams refreshes the inspector (AppState is @Observable);
        // the seam-state token is deliberately NOT bumped, so this fit update never
        // re-pushes to the viewport and disturbs the live pose.
        for fit in fits {
            guard let idStr = fit["id"] as? String, let id = UUID(uuidString: idStr),
                  let i = constructSeams.firstIndex(where: { $0.id == id }) else { continue }
            let gap = (fit["maxGap"] as? Double) ?? 0
            let nA = (fit["nA"] as? Int) ?? constructSeams[i].holesA
            let nB = (fit["nB"] as? Int) ?? constructSeams[i].holesB
            constructSeams[i].maxGapMm = gap
            constructSeams[i].holesA = nA
            constructSeams[i].holesB = nB
        }
    }

    /// Changes how a seam resolves a perimeter mismatch (ease / deform / 1:1).
    func setSeamMode(_ seamId: StitchSeam.ID, _ mode: StitchMode) {
        guard let i = constructSeams.firstIndex(where: { $0.id == seamId }), constructSeams[i].mode != mode else { return }
        pushConstructUndo()
        constructSeams[i].mode = mode
        constructSeamStateToken += 1
        hasUnsavedChanges = true
    }

    /// Removes a seam (unstitch).
    func removeSeam(_ seamId: StitchSeam.ID) {
        pushConstructUndo()
        constructSeams.removeAll { $0.id == seamId }
        constructSeamStateToken += 1
        hasUnsavedChanges = true
    }

    /// Toggles thread rendering in the viewport.
    func setConstructShowThread(_ on: Bool) {
        constructShowThread = on
        constructSeamStateToken += 1
    }

    // MARK: - Loft-style alignment pins + seam reverse

    /// Enters / leaves "add pin" mode for a seam: while on, clicking holes in 3D pins
    /// a hole↔hole pair (first click on one chain, second on the other).
    func setStitchPinMode(_ seamId: StitchSeam.ID?, _ on: Bool) {
        activeSeamForPins = on ? seamId : nil
        stitchPinMode = on && seamId != nil
        pendingAnchorHole = nil
        if stitchPinMode, constructTool != .stitch { setConstructTool(.stitch) }
        constructStitchPinToken += 1
        constructSeamStateToken += 1
    }

    /// A hole picked in 3D while pinning. The first goes pending; its partner on the
    /// *other* chain forms an alignment pin → re-match honoring it.
    func addAnchorHole(chainId: Int, k: Int) {
        guard stitchPinMode, let sid = activeSeamForPins,
              let si = constructSeams.firstIndex(where: { $0.id == sid }) else { return }
        let seam = constructSeams[si]
        guard chainId == seam.chainA || chainId == seam.chainB else { return }
        guard let first = pendingAnchorHole else { pendingAnchorHole = (chainId, k); return }
        if first.chainId == chainId { pendingAnchorHole = (chainId, k); return }  // same chain → replace
        let aIdx = (first.chainId == seam.chainA) ? first.k : k
        let bIdx = (first.chainId == seam.chainA) ? k : first.k
        pushConstructUndo()
        var anchors = constructSeams[si].anchors ?? []
        anchors.removeAll { ($0.first ?? -1) == aIdx }   // one pin per A hole
        anchors.append([aIdx, bIdx])
        constructSeams[si].anchors = anchors
        pendingAnchorHole = nil
        hasUnsavedChanges = true
        rematchSeam(sid)
    }

    /// Clears all alignment pins on a seam (back to auto matching).
    func clearStitchAnchors(_ seamId: StitchSeam.ID) {
        guard let si = constructSeams.firstIndex(where: { $0.id == seamId }),
              !(constructSeams[si].anchors ?? []).isEmpty else { return }
        pushConstructUndo()
        constructSeams[si].anchors = []
        pendingAnchorHole = nil
        hasUnsavedChanges = true
        rematchSeam(seamId)
    }

    /// Reverses a seam's correspondence direction (flip chain B).
    func reverseSeam(_ seamId: StitchSeam.ID) {
        guard let si = constructSeams.firstIndex(where: { $0.id == seamId }) else { return }
        pushConstructUndo()
        constructSeams[si].flip = !(constructSeams[si].flip ?? false)
        hasUnsavedChanges = true
        rematchSeam(seamId)
    }

    /// Count of pins on a seam (for the inspector label).
    func seamAnchorCount(_ seamId: StitchSeam.ID) -> Int {
        (constructSeams.first { $0.id == seamId }?.anchors ?? []).count
    }

    /// Serialized seams + thread flag for the viewport bridge. The viewport looks
    /// up each chain by id from the model it already holds.
    var constructSeamsJSON: String {
        let seams = constructSeams.map { s -> [String: Any] in
            ["id": s.id.uuidString, "chainA": s.chainA, "chainB": s.chainB,
             "mode": s.mode.rawValue, "pairs": s.pairs, "reversed": s.reversed,
             "anchors": s.anchors ?? []]
        }
        let glues = constructGlues.map { g -> [String: Any] in
            var o: [String: Any] = ["panelA": g.panelA, "panelB": g.panelB, "mode": g.mode,
                                    "aSide": g.aSide, "bSide": g.bSide]
            if let a = g.aPt { o["aPt"] = a }
            if let b = g.bPt { o["bPt"] = b }
            return o
        }
        var payload: [String: Any] = ["seams": seams, "glues": glues, "showThread": constructShowThread,
                                      "glueMode": constructGlueMode]
        if let sel = selectedChainForStitch { payload["selectedChain"] = sel }
        // Live first-pick highlight for the glue tool (drawn green in the viewport).
        if let gp = selectedPanelForGlue {
            var gs: [String: Any] = ["panelId": gp, "side": selectedGlueSide]
            if let pt = selectedGluePoint { gs["p2d"] = pt }
            payload["glueSel"] = gs
        }
        guard let d = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: d, encoding: .utf8) else { return "{}" }
        return str
    }
}
