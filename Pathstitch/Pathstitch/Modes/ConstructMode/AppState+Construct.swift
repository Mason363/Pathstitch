import Foundation

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

                guard let data = res["data"] as? [String: Any],
                      let panels = data["panels"] as? [[String: Any]] else {
                    let msg = (res["message"] as? String) ?? "No panels in construct model."
                    throw PythonBridgeError.invalidResponse(msg)
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
                        let keep = prior.first { $0.panelId == pid && $0.foldId == fid }?.angleDeg ?? 0
                        newFolds.append(FoldSpec(panelId: pid, foldId: fid, angleDeg: keep))
                    }
                }

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
                           thicknessMm: constructThicknessMm, decals: constructDecals,
                           decalXforms: constructDecalXforms,
                           includeHandles: constructIncludeHandles,
                           areaTreatments: constructAreaTreatments,
                           baseRegions: constructBaseRegions)
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
        && a.thicknessMm == b.thicknessMm && a.decals == b.decals && a.decalXforms == b.decalXforms
        && a.includeHandles == b.includeHandles && a.areaTreatments == b.areaTreatments
        && a.baseRegions == b.baseRegions
    }

    private func applyConstruct(_ s: ConstructUndoState) {
        constructGroundPanel = s.groundPanel
        constructFolds = s.folds
        constructSeams = s.seams
        constructGlues = s.glues
        constructMaterialHex = s.materialHex
        constructThicknessMm = s.thicknessMm
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

    /// Hex string → 0xRRGGBB int for the viewport.
    var constructMaterialColorInt: Int {
        Int(constructMaterialHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8A5A2B
    }

    /// {panelId: {url, ox, oy, scale, rot, mirror}} for the viewport to re-apply
    /// artwork decals *with their framing* (offset / scale / rotation / flip).
    var constructDecalsJSON: String {
        var obj: [String: Any] = [:]
        for (pid, url) in constructDecals {
            let x = decalXform(pid)
            obj[String(pid)] = ["url": url, "ox": x[0], "oy": x[1],
                                "scale": x[2], "rot": x[3], "mirror": x[4]]
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

    /// Glue tool: pick panel A then panel B → weld their meeting edges.
    func pickPanelForGlue(_ panelId: Int) {
        if let first = selectedPanelForGlue {
            selectedPanelForGlue = nil
            if first != panelId { addGlue(panelA: first, panelB: panelId) }
            constructSeamStateToken += 1
        } else {
            selectedPanelForGlue = panelId
            constructSeamStateToken += 1
        }
    }

    func addGlue(panelA: Int, panelB: Int) {
        guard !constructGlues.contains(where: {
            ($0.panelA == panelA && $0.panelB == panelB) ||
            ($0.panelA == panelB && $0.panelB == panelA) }) else { return }
        pushConstructUndo()
        constructGlues.append(GlueJoint(panelA: panelA, panelB: panelB))
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
        do {
            let res = try await PythonBridge.shared.run(
                module: "construct_ops", op: "match_chains",
                args: ["chainA": ptsA, "chainB": ptsB,
                       "closedA": ca.closed, "closedB": cb.closed])
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

    /// Serialized seams + thread flag for the viewport bridge. The viewport looks
    /// up each chain by id from the model it already holds.
    var constructSeamsJSON: String {
        let seams = constructSeams.map { s -> [String: Any] in
            ["id": s.id.uuidString, "chainA": s.chainA, "chainB": s.chainB,
             "mode": s.mode.rawValue, "pairs": s.pairs, "reversed": s.reversed]
        }
        let glues = constructGlues.map { ["panelA": $0.panelA, "panelB": $0.panelB] as [String: Any] }
        var payload: [String: Any] = ["seams": seams, "glues": glues, "showThread": constructShowThread]
        if let sel = selectedChainForStitch { payload["selectedChain"] = sel }
        guard let d = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: d, encoding: .utf8) else { return "{}" }
        return str
    }
}
