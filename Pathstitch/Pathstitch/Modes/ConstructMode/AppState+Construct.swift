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

    /// Triangulates the current panels + fold lines into a construct model and
    /// hands the JSON to the viewport. Folds are auto-detected from a fold/crease
    /// layer in the sketch (see `construct_ops._FOLD_LAYERS`); existing fold
    /// angles are preserved across rebuilds so a live edit doesn't reset the pose.
    func buildConstructModel() {
        let dxfURL = ensureActiveDXFFileExists()
        let ground = constructGroundPanel
        let extraFolds = constructUserFolds.map {
            ["panelId": $0.panelId, "seg": [[$0.x0, $0.y0], [$0.x1, $0.y1]]] as [String: Any]
        }
        isBuildingConstructModel = true

        Task {
            do {
                let res = try await PythonBridge.shared.run(
                    module: "construct_ops",
                    op: "build_construct_model",
                    args: ["input": dxfURL.path, "ground_panel": ground, "extra_folds": extraFolds]
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

                await MainActor.run {
                    self.constructModelJSON = modelStr
                    self.constructFolds = newFolds
                    self.constructHoleChains = chains
                    self.constructSeams = survivingSeams
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

    /// Sets a fold's target angle and pushes it live to the solver.
    func setConstructFoldAngle(_ id: FoldSpec.ID, _ deg: Double) {
        guard let i = constructFolds.firstIndex(where: { $0.id == id }) else { return }
        constructFolds[i].angleDeg = deg
        constructFoldStateToken += 1
        hasUnsavedChanges = true
    }

    /// Pins a different panel to the ground plane.
    func setConstructGround(_ panelId: Int) {
        constructGroundPanel = panelId
        constructFoldStateToken += 1   // ground is pushed alongside the fold angles
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

    /// Sets the drag-brush radius (mm) and pushes it live to the viewport.
    func setConstructBrushRadius(_ r: Double) {
        constructBrushRadius = r
        constructBrushToken += 1
    }

    /// Sets the bend-grab axis ("screen" | "x" | "y" | "z") and pushes it live.
    func setConstructDragAxis(_ axis: String) {
        constructDragAxis = axis
        constructBrushToken += 1   // rides the brush push
    }

    /// Sets fold stiffness (0 = round/soft bend, 1 = tight crease) and re-poses.
    func setConstructStiffness(_ s: Double) {
        constructStiffness = s
        constructFoldStateToken += 1   // stiffness rides the controls push
        hasUnsavedChanges = true
    }

    /// Sets the mockup leather colour (hex like "8A5A2B") and pushes it live.
    func setConstructMaterialColor(_ hex: String) {
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
        constructDecals.removeValue(forKey: pid)
        constructDecalXforms.removeValue(forKey: pid)
        if activeDecalPanel == pid { activeDecalPanel = nil }
        constructDecalToken += 1
        hasUnsavedChanges = true
    }

    /// Clears all artwork decals (the viewport reconciles removals).
    func clearConstructDecals() {
        constructDecals.removeAll()
        constructDecalXforms.removeAll()
        activeDecalPanel = nil
        constructDecalToken += 1
        hasUnsavedChanges = true
    }

    /// Re-poses from the folded rest state, clearing any brush drape.
    func resetConstructDrape() {
        constructFoldStateToken += 1   // re-applying controls re-solves from rest
    }

    /// Adds a fold line drawn in 3D (2D segment in a panel's space) and rebuilds.
    func addConstructUserFold(panelId: Int, x0: Double, y0: Double, x1: Double, y1: Double) {
        guard hypot(x1 - x0, y1 - y0) > 1.0 else { return }   // ignore a stray double-click
        constructUserFolds.append(ConstructUserFold(panelId: panelId, x0: x0, y0: y0, x1: x1, y1: y1))
        hasUnsavedChanges = true
        pendingCreaseSelectPanel = panelId   // select the new fold once the rebuild lands
        buildConstructModel()   // re-triangulate so the new crease is a real hinge
    }

    /// Removes the most recently added 3D fold line.
    func undoLastUserFold() {
        guard !constructUserFolds.isEmpty else { return }
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
        constructGlues.append(GlueJoint(panelA: panelA, panelB: panelB))
        constructSeamStateToken += 1
        hasUnsavedChanges = true
    }

    func removeGlue(_ id: GlueJoint.ID) {
        constructGlues.removeAll { $0.id == id }
        constructSeamStateToken += 1
        hasUnsavedChanges = true
    }

    /// Serialized {groundPanel, folds:[{panelId,foldId,angleDeg}]} for the bridge.
    var constructControlsJSON: String {
        let folds = constructFolds.map {
            ["panelId": $0.panelId, "foldId": $0.foldId, "angleDeg": $0.angleDeg] as [String: Any]
        }
        let payload: [String: Any] = ["groundPanel": constructGroundPanel,
                                      "folds": folds, "stiffness": constructStiffness]
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
            await MainActor.run {
                guard let i = self.constructSeams.firstIndex(where: { $0.id == seamId }) else { return }
                self.constructSeams[i].pairs = pairs
                self.constructSeams[i].lenA = lenA
                self.constructSeams[i].lenB = lenB
                self.constructSeams[i].mismatch = mismatch
                self.constructSeams[i].reversed = reversed
                self.constructSeamStateToken += 1
            }
        } catch {
            // matching failure leaves the seam un-paired; the viewport just won't
            // draw thread for it. Surface quietly.
            await MainActor.run { self.errorMessage = "Stitch match failed: \(error.localizedDescription)" }
        }
    }

    /// Changes how a seam resolves a perimeter mismatch (ease / deform / 1:1).
    func setSeamMode(_ seamId: StitchSeam.ID, _ mode: StitchMode) {
        guard let i = constructSeams.firstIndex(where: { $0.id == seamId }) else { return }
        constructSeams[i].mode = mode
        constructSeamStateToken += 1
        hasUnsavedChanges = true
    }

    /// Removes a seam (unstitch).
    func removeSeam(_ seamId: StitchSeam.ID) {
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
