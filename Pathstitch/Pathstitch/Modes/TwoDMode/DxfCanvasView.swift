import SwiftUI

/// One pen-tool anchor (MAS-94). `point` is the on-curve anchor; `handleOut`
/// is the outgoing bezier control point (toward the next anchor). The incoming
/// handle is the mirror of `handleOut` about `point`, giving Illustrator's
/// symmetric smooth points. A nil `handleOut` is a sharp corner.
struct PenAnchor: Equatable {
    var point: CGPoint
    var handleOut: CGPoint? = nil
    var handleIn: CGPoint? {
        guard let h = handleOut else { return nil }
        return CGPoint(x: 2 * point.x - h.x, y: 2 * point.y - h.y)
    }
}

struct DxfCanvasView: View {
    var state: AppState

    /// Screen-space pick radius (pt) for clicking a thin stroke to select it,
    /// shared by single-click select and the right-click context menu so both
    /// feel equally forgiving. Interior clicks on closed shapes are additionally
    /// covered by findNearestEntity's containment fallback (MAS-116).
    static let selectionHitTolerance: CGFloat = 20.0

    // Pen tool (MAS-94): anchors placed so far, plus whether the current
    // press is dragging out a smooth handle.
    @State private var penAnchors: [PenAnchor] = []
    @State private var penDraggingHandle = false
    @State private var penDraggingHandleIdx: Int? = nil
    @State private var penClosePending = false
    // Re-editing an existing pen path (parametric pen lines): the handle being
    // edited, whether it's closed, and which anchor/handle a drag is moving.
    @State private var editingPenHandle: String? = nil
    @State private var penEditingClosed = false
    @State private var penEditDragAnchor: Int? = nil
    @State private var penEditDragHandle: (idx: Int, isOut: Bool)? = nil

    @State private var dragStartOffset = CGSize.zero
    @State private var isDragging = false
    @State private var mouseLocation = CGPoint.zero
    @State private var hoverCoords: CGPoint? = nil
    
    @State private var dragSelectionStart: CGPoint? = nil
    @State private var dragSelectionEnd: CGPoint? = nil
    
    @State private var sketchStartPoint: CGPoint? = nil // in model coordinates
    @State private var sketchAwaitingSecondClick = false // true after the 1st click, before the 2nd commits
    @State private var editingMeasureId: UUID? = nil
    @State private var hoveredMeasurementId: UUID? = nil
    @State private var editingIsStart: Bool = false
    
    @State private var gizmoDragOffset = CGSize.zero
    @State private var isDraggingSelection = false
    @State private var dragStartModelPt = CGPoint.zero
    @State private var isDraggingFillet = false
    // While the corner-tool radius arrow is being dragged, the canvas renders a
    // lag-free local blend preview and the committed (stale) geometry is hidden,
    // so no Python round-trip happens per frame (fillet perf).
    @State private var isDraggingFilletArrow = false
    @State private var isDraggingOffset = false
    @State private var gizmoDragRotation: Double = 0.0
    @State private var isDraggingRotation = false
    // Scale tool (MAS-128): live preview factor + drag state.
    @State private var gizmoDragScale: CGFloat = 1.0
    @State private var isDraggingScale = false
    @State private var scaleDragStartDist: CGFloat = 0.0
    @State private var gizmoRotationStartAngle: Double? = nil

    // Precision movement dimension box (MAS-57). `gizmoDimKind` is "x", "y" or
    // "rot"; the box shows the live value while dragging and stays editable after
    // release so an exact value can be typed.
    @State private var gizmoDimKind: String? = nil
    @State private var gizmoDimText: String = ""
    @State private var gizmoDimApplied: Double = 0.0   // value applied so far this interaction
    @FocusState private var isGizmoDimFocused: Bool
    @State private var isHoveringFilletHandle = false
    @State private var isHoveringOffsetHandle = false
    @State private var isHoveringStartOffset = false
    @State private var isDraggingStartOffset = false
    @State private var isHoveringEndOffset = false
    @State private var isDraggingEndOffset = false

    // Free vertex editing + right-click Expand menu (MAS-62)
    @State private var editingVertexHandle: String? = nil
    @State private var editingVertexIndex: Int = 0
    @State private var editingVertexIsRect: Bool = false
    @State private var contextMenuScreenPos: CGPoint? = nil

    @State private var editingDimension: MeasurementLine? = nil
    @State private var editingDimensionText: String = ""
    @State private var editingDimensionScreenPos: CGPoint = .zero
    /// Invalid-formula flash on the dimension field (MAS-110 §4 / MAS-111).
    @State private var dimensionFieldError: Bool = false
    /// First picked point for a two-point linear dimension (MAS-110 §1).
    @State private var dimensionFirstPoint: CGPoint? = nil
    @FocusState private var isTextEditorFocused: Bool
    @FocusState private var isDimensionEditorFocused: Bool
    @FocusState private var isCalibrationInputFocused: Bool
    
    // Group 9 Layer-based Reference Image Drag States
    @State private var activeRefImageHandle: String? = nil
    @State private var refImageDragStartOffsetX: Double = 0.0
    @State private var refImageDragStartOffsetY: Double = 0.0
    @State private var refImageDragStartScaleX: Double = 1.0
    @State private var refImageDragStartScaleY: Double = 1.0
    @State private var refImageDragStartRotation: Double = 0.0
    @State private var refImageDragStartLocation: CGPoint? = nil
    @State private var refImageDragStartAngle: Double? = nil
    
    var selectionCenterModel: CGPoint? {
        state.selectionCenterModel
    }

    /// Pivot the Scale tool scales around: the picked scale point if set, else the
    /// selection's bounding-box center (MAS-128).
    var scalePivotModel: CGPoint? {
        if let p = state.scalePivotModel { return p }
        if let b = state.selectionBBox { return CGPoint(x: b.midX, y: b.midY) }
        return nil
    }

    var body: some View {
        @Bindable var state = state
        GeometryReader { geo in
            let modelBounds = state.entities.isEmpty ? CGRect(x: 0, y: 0, width: 200, height: 200) : getBounds(state.entities)
            
            ZStack(alignment: .bottomLeading) {
                Color.bg_base
                
                // Underlay Reference Images (Back Depth)
                ForEach(state.layers) { layer in
                    if layer.isReferenceImageLayer && layer.visible,
                       let img = state.getDecodedImage(for: layer),
                       layer.refImageDepth == "back" {
                        drawReferenceImage(img, for: layer, size: geo.size, bounds: modelBounds)
                    }
                }
                
                Canvas { context, size in
                    var ctx = context
                    renderCanvas(&ctx, size: size, modelBounds: modelBounds)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            handleDragChanged(val: val, size: geo.size, modelBounds: modelBounds)
                        }
                        .onEnded { val in
                            handleDragEnded(val: val, size: geo.size, modelBounds: modelBounds)
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { event in
                            let point = event.location
                            let modelPt = toModel(point: point, size: geo.size, bounds: modelBounds)
                            // Pen tool: double-click finishes the open path (MAS-94).
                            if state.currentTool == .pen {
                                finishPenPath()
                                return
                            }
                            if let nearestMeasure = findNearestMeasurement(screenPt: point, size: geo.size, bounds: modelBounds) {
                                editingDimension = nearestMeasure
                                editingDimensionText = String(format: "%.2f", nearestMeasure.distanceMm)
                                
                                let startScreen = toScreen(dx: nearestMeasure.start.x, dy: nearestMeasure.start.y, size: geo.size, bounds: modelBounds)
                                let endScreen = toScreen(dx: nearestMeasure.end.x, dy: nearestMeasure.end.y, size: geo.size, bounds: modelBounds)
                                editingDimensionScreenPos = CGPoint(
                                    x: (startScreen.x + endScreen.x) / 2,
                                    y: (startScreen.y + endScreen.y) / 2
                                )
                            } else if let nearestEntity = findNearestEntity(modelPt: modelPt, maxDistanceScreen: 16.0, size: geo.size, bounds: modelBounds) {
                                if nearestEntity.type == "TEXT" {
                                    state.startEditingText(entity: nearestEntity)
                                } else if state.currentTool == .select, let model = state.penPaths[nearestEntity.handle] {
                                    // Re-open a pen path for editing on the Select
                                    // tool (parametric pen lines).
                                    loadPenModel(model)
                                    penEditingClosed = model.closed
                                    editingPenHandle = nearestEntity.handle
                                    penEditDragAnchor = nil
                                    penEditDragHandle = nil
                                    penDraggingHandle = false
                                    penClosePending = false
                                    state.selectedHandles = [nearestEntity.handle]
                                    state.currentTool = .pen
                                }
                            }
                        }
                )
                .modifier(MouseTrackerModifier(mouseLocation: $mouseLocation, hoverCoords: $hoverCoords, size: geo.size, bounds: modelBounds, scale: state.canvasScale, offset: state.canvasOffset))
                .onChange(of: hoverCoords) { _, newCoords in
                    if let coords = newCoords {
                        if let nearest = findNearestEntity(modelPt: coords, maxDistanceScreen: 12.0, size: geo.size, bounds: modelBounds) {
                            state.hoveredHandle = nearest.handle
                        } else {
                            state.hoveredHandle = nil
                        }
                        
                        if let nearestMeasure = findNearestMeasurement(screenPt: mouseLocation, size: geo.size, bounds: modelBounds) {
                            hoveredMeasurementId = nearestMeasure.id
                        } else {
                            hoveredMeasurementId = nil
                        }
                    } else {
                        state.hoveredHandle = nil
                        hoveredMeasurementId = nil
                    }
                }
                .onChange(of: state.fitRequestToken) { _, _ in
                    fitToContent(viewSize: geo.size)
                }
                .onChange(of: state.zoomStepToken) { _, _ in
                    // Step zoom from the View menu — zoom about the viewport
                    // center, reusing the same offset math as the pinch handler.
                    let oldScale = state.canvasScale
                    let newScale = max(0.01, min(500.0, oldScale * state.zoomStepFactor))
                    guard newScale != oldScale else { return }
                    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    let mPt = toModel(point: center, size: geo.size, bounds: modelBounds)
                    let scaleDiff = newScale - oldScale
                    state.canvasScale = newScale
                    state.canvasOffset = CGSize(
                        width: state.canvasOffset.width - mPt.x * scaleDiff,
                        height: state.canvasOffset.height + mPt.y * scaleDiff
                    )
                }
                .onChange(of: state.isEditingText) { _, editing in
                    isTextEditorFocused = editing
                }
                .onChange(of: state.commitToolToken) { _, _ in
                    // Return/Enter confirms the active action and returns to Select.
                    if state.currentTool.isCornerTool {
                        // Confirm the fillet/chamfer (changes are already applied).
                        state.confirmCornerToolSession()
                        if state.currentTool != .select { state.currentTool = .select }
                        return
                    }
                    // Enter commits the offset and exits to Select (MAS-109).
                    if state.currentTool == .offset {
                        if !state.selectedHandles.isEmpty {
                            state.applyOffset(exitAfterApply: true)
                        }
                        return
                    }
                    // Return/Enter finishes the in-progress shape at the cursor.
                    if state.currentTool == .pen {
                        finishPenPath()
                    } else if state.currentTool == .sketchLine, let start = sketchStartPoint {
                        let end = snappedMouseLocation(size: geo.size, bounds: modelBounds).point
                        let sStart = toScreen(dx: start.x, dy: start.y, size: geo.size, bounds: modelBounds)
                        let sEnd = toScreen(dx: end.x, dy: end.y, size: geo.size, bounds: modelBounds)
                        if hypot(sStart.x - sEnd.x, sStart.y - sEnd.y) >= 5.0 {
                            commitSketchLine(start: start, end: end, size: geo.size, modelBounds: modelBounds)
                        }
                        sketchStartPoint = nil
                        sketchAwaitingSecondClick = false
                    }
                }
                .onChange(of: state.escapePressedToken) { _, _ in
                    if editingDimension != nil {
                        // Esc closes the on-creation dimension and hides its lines.
                        finishDimensioning()
                        return
                    }
                    if state.currentTool.isCornerTool {
                        // Esc cancels the fillet/chamfer — revert the session — and
                        // returns to Select.
                        state.cancelCornerToolSession()
                        if state.currentTool != .select { state.currentTool = .select }
                        return
                    }
                    // Esc drops the Offset tool without generating geometry (MAS-109).
                    if state.currentTool == .offset {
                        state.cancelOffsetTool()
                        return
                    }
                    // Esc discards a staged (un-committed) scale preview and exits.
                    if state.currentTool == .scale {
                        state.scaleFactor = 1.0
                        state.scalePivotModel = nil
                        if state.currentTool != .select { state.currentTool = .select }
                        return
                    }
                    if state.currentTool == .pen && !penAnchors.isEmpty {
                        // Esc abandons the in-progress pen path, or cancels a
                        // re-edit and restores the original (parametric pen lines).
                        resetPenState()
                    } else if state.isEditingText {
                        state.cancelTextEditing()
                    } else if gizmoDimKind != nil {
                        // Esc dismisses the precision dimension box first (MAS-57).
                        gizmoDimKind = nil
                        isGizmoDimFocused = false
                    } else if sketchStartPoint != nil {
                        sketchStartPoint = nil
                        sketchAwaitingSecondClick = false
                    } else {
                        state.selectedHandles.removeAll()
                        state.selectedFaces3D.removeAll()
                    }
                    // Escape always falls back to the Select tool — a universal
                    // shortcut to it, on top of cancelling the current action.
                    if state.currentTool != .select { state.currentTool = .select }
                }
                .onChange(of: state.currentTool) { oldTool, newTool in
                    sketchStartPoint = nil
                    sketchAwaitingSecondClick = false
                    state.activeMeasureStart = nil
                    gizmoDimKind = nil
                    // Leaving the Pen tool finishes an in-progress path (so the
                    // work isn't lost), then clears the staging state (MAS-94).
                    if oldTool == .pen && newTool != .pen {
                        if penAnchors.count >= 2 { commitPenPath(closed: editingPenHandle != nil ? penEditingClosed : false) }
                        else { resetPenState() }
                    }
                    // Create-copy defaults off each time the Move tool is activated,
                    // and any in-progress point-to-point is reset (MAS-80).
                    if newTool == .move {
                        state.moveCreateCopy = false
                        state.moveP2PActive = false
                        state.moveP2PFrom = nil
                    }
                    // Reset mirror staging when leaving/entering tools.
                    if newTool != .mirror { state.resetMirrorTool() }
                }
                .onChange(of: state.selectedHandles) { _, _ in
                    // Dismiss the precision box when the selection changes (MAS-57).
                    gizmoDimKind = nil
                }
                .onChange(of: editingDimension) { _, newDim in
                    if newDim != nil {
                        isDimensionEditorFocused = true
                        // Select the field contents so typing immediately overrides
                        // the current value — on creation and on each Tab switch (§5).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
                        }
                    } else {
                        isDimensionEditorFocused = false
                    }
                }
                .overlay(
                    ScrollWheelModifier(
                        onZoom: { event, zoomPt, zoomFactor in
                            let oldScale = state.canvasScale
                            let newScale = max(0.01, min(500.0, oldScale * zoomFactor))
                            
                            if newScale != oldScale {
                                let mPt = toModel(point: zoomPt, size: geo.size, bounds: modelBounds)
                                state.canvasScale = newScale
                                
                                let dx = mPt.x
                                let dy = mPt.y
                                let scaleDiff = newScale - oldScale
                                
                                state.canvasOffset = CGSize(
                                    width: state.canvasOffset.width - dx * scaleDiff,
                                    height: state.canvasOffset.height + dy * scaleDiff
                                )
                            }
                        },
                        onPanOffset: { offset in
                            state.canvasOffset = CGSize(
                                width: state.canvasOffset.width + offset.width,
                                height: state.canvasOffset.height + offset.height
                            )
                        },
                        onMagnify: { magnification, zoomPt in
                            let oldScale = state.canvasScale
                            let zoomFactor: CGFloat = 1.0 + magnification
                            let newScale = max(0.01, min(500.0, oldScale * zoomFactor))
                            
                            if newScale != oldScale {
                                let mPt = toModel(point: zoomPt, size: geo.size, bounds: modelBounds)
                                state.canvasScale = newScale
                                
                                let dx = mPt.x
                                let dy = mPt.y
                                let scaleDiff = newScale - oldScale
                                
                                state.canvasOffset = CGSize(
                                    width: state.canvasOffset.width - dx * scaleDiff,
                                    height: state.canvasOffset.height + dy * scaleDiff
                                )
                            }
                        },
                        onDeleteSelected: {
                            state.deleteSelectedEntities()
                        },
                        onRightClick: { pt in
                            // Select the shape under the cursor, then open the menu (MAS-62).
                            let modelPt = toModel(point: pt, size: geo.size, bounds: modelBounds)
                            if let nearest = findNearestEntity(modelPt: modelPt, maxDistanceScreen: Self.selectionHitTolerance, size: geo.size, bounds: modelBounds) {
                                if !state.selectedHandles.contains(nearest.handle) {
                                    state.selectedHandles = [nearest.handle]
                                }
                                contextMenuScreenPos = pt
                            } else {
                                contextMenuScreenPos = nil
                            }
                        }
                    )
                    .allowsHitTesting(true)
                )
                .overlay(alignment: .topLeading) {
                    if let pos = contextMenuScreenPos {
                        canvasContextMenu(at: pos)
                    }
                }
                .overlay {
                    if state.currentTool == .mirror {
                        mirrorAxisOverlay(size: geo.size, bounds: modelBounds)
                    }
                }
                .cursorStyle(state.currentTool)
                
                // Overlay Reference Canvas Images (Front Depth)
                ForEach(state.layers) { layer in
                    if layer.isReferenceImageLayer && layer.visible,
                       let img = state.getDecodedImage(for: layer),
                       layer.refImageDepth == "front" {
                        drawReferenceImage(img, for: layer, size: geo.size, bounds: modelBounds)
                    }
                }
                
                // Bounding box transform gizmo for reference image editing
                if let activeL = state.activeLayer, activeL.isReferenceImageLayer, state.isEditingRefImageTransform {
                    referenceImageGizmoOverlay(size: geo.size, modelBounds: modelBounds, layer: activeL)
                        .allowsHitTesting(false)
                }
                
                canvasOverlays(size: geo.size, modelBounds: modelBounds)
                coordinatesOverlay()
                activeToolPill()
                editingTextFieldsOverlay(size: geo.size, modelBounds: modelBounds)
            }
            .coordinateSpace(name: "canvas")
            .onChange(of: geo.size) { _, newSize in
                state.currentViewportSize = newSize
            }
            .onAppear {
                state.currentViewportSize = geo.size
            }
        }
    }

    @ViewBuilder
    private func canvasOverlays(size viewSize: CGSize, modelBounds: CGRect) -> some View {
        ZStack {
            // Translation Gizmo Layer. Hidden while a corner tool (Fillet/Chamfer)
            // is active so the move/rotate handles don't overlap and steal grabs
            // from the per-corner radius controls (MAS-101).
            if let centerModel = selectionCenterModel, !state.currentTool.isCornerTool, state.currentTool != .scale, state.currentTool != .offset, !state.isEditingRefImageTransform {
                let centerScreen = toScreen(dx: Double(centerModel.x), dy: Double(centerModel.y), size: viewSize, bounds: modelBounds)

                    GeometryReader { g in
                        let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)

                        // X-axis constraint handle (Red Line & Arrow)
                        Path { p in
                            p.move(to: c)
                            p.addLine(to: CGPoint(x: c.x + 70, y: c.y))
                        }
                        .stroke(Color.red, lineWidth: 2)
                        
                        Image(systemName: "play.fill")
                            .resizable()
                            .foregroundColor(.red)
                            .frame(width: 14, height: 16)
                            .position(x: c.x + 68, y: c.y)
                            .gesture(
                                DragGesture(coordinateSpace: .named("canvas"))
                                    .onChanged { val in
                                        gizmoDragOffset = CGSize(width: val.translation.width, height: 0)
                                        gizmoDimKind = "x"
                                        gizmoDimText = String(format: "%.2f", val.translation.width / state.canvasScale)
                                    }
                                    .onEnded { val in
                                        let dx = val.translation.width / state.canvasScale
                                        state.translateSelected(dx: dx, dy: 0)
                                        gizmoDragOffset = .zero
                                        // Keep an editable box prefilled with the applied
                                        // distance so an exact value can be typed (MAS-57).
                                        gizmoDimApplied = dx
                                        gizmoDimText = String(format: "%.2f", dx)
                                        gizmoDimKind = "x"
                                        isGizmoDimFocused = true
                                    }
                            )

                        // Y-axis constraint handle (Green Line & Arrow)
                        Path { p in
                            p.move(to: c)
                            p.addLine(to: CGPoint(x: c.x, y: c.y - 70))
                        }
                        .stroke(Color.green, lineWidth: 2)
                        
                        Image(systemName: "play.fill")
                            .resizable()
                            .foregroundColor(.green)
                            .frame(width: 14, height: 16)
                            .rotationEffect(.degrees(-90))
                            .position(x: c.x, y: c.y - 68)
                            .gesture(
                                DragGesture(coordinateSpace: .named("canvas"))
                                    .onChanged { val in
                                        gizmoDragOffset = CGSize(width: 0, height: val.translation.height)
                                        gizmoDimKind = "y"
                                        gizmoDimText = String(format: "%.2f", -val.translation.height / state.canvasScale)
                                    }
                                    .onEnded { val in
                                        let dy = -val.translation.height / state.canvasScale
                                        state.translateSelected(dx: 0, dy: dy)
                                        gizmoDragOffset = .zero
                                        gizmoDimApplied = dy
                                        gizmoDimText = String(format: "%.2f", dy)
                                        gizmoDimKind = "y"
                                        isGizmoDimFocused = true
                                    }
                            )
                        
                        // Blue Rotation handle (stem + circle).
                        let ang = gizmoDragRotation * .pi / 180.0
                        let hp = CGPoint(x: c.x + sin(ang) * 100, y: c.y - cos(ang) * 100)
                        Path { p in
                            p.move(to: c)
                            p.addLine(to: hp)
                        }
                        .stroke(Color.blue, lineWidth: 2)

                        Circle()
                            .fill(Color.blue)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .shadow(radius: 2)
                            .position(hp)
                            .gesture(
                                DragGesture(coordinateSpace: .named("canvas"))
                                    .onChanged { val in
                                        isDraggingRotation = true
                                        // Grab-relative delta: grabbing the handle is 0°, so it
                                        // never snaps/teleports to the cursor on grab.
                                        let cur = atan2(Double(val.location.x - centerScreen.x),
                                                        Double(-(val.location.y - centerScreen.y))) * 180.0 / .pi
                                        if gizmoRotationStartAngle == nil { gizmoRotationStartAngle = cur }
                                        gizmoDragRotation = cur - (gizmoRotationStartAngle ?? cur)
                                        // Live cumulative angle (MAS-57): accumulated + this drag.
                                        let live = self.wrap360(state.gizmoAccumulatedRotation - gizmoDragRotation)
                                        gizmoDimKind = "rot"
                                        gizmoDimText = String(format: "%.1f", live)
                                    }
                                    .onEnded { _ in
                                        isDraggingRotation = false
                                        let theta = gizmoDragRotation
                                        gizmoRotationStartAngle = nil
                                        gizmoDragRotation = 0.0
                                        if abs(theta) > 0.05 {
                                            // Commit the NEGATED angle: the live preview rotates the
                                            // GraphicsContext in screen space (Y-down) while the
                                            // committed model rotation is Y-up — opposite sense.
                                            // Negating makes the release land exactly where shown.
                                            state.rotateSelected(angleDegrees: -theta,
                                                                 center: [Double(centerModel.x), Double(centerModel.y)])
                                            // Accumulate (never resets between rotations) — MAS-57.
                                            state.gizmoAccumulatedRotation = self.wrap360(state.gizmoAccumulatedRotation - theta)
                                        }
                                        gizmoDimApplied = state.gizmoAccumulatedRotation
                                        gizmoDimText = String(format: "%.1f", state.gizmoAccumulatedRotation)
                                        gizmoDimKind = "rot"
                                        isGizmoDimFocused = true
                                    }
                            )
                        
                        // Center free movement box (Yellow square)
                        Rectangle()
                            .fill(Color.yellow)
                            .frame(width: 16, height: 16)
                            .border(Color.black, width: 1)
                            .position(c)
                            .gesture(
                                DragGesture(coordinateSpace: .named("canvas"))
                                    .onChanged { val in
                                        gizmoDragOffset = val.translation
                                    }
                                    .onEnded { val in
                                        let dx = val.translation.width / state.canvasScale
                                        let dy = -val.translation.height / state.canvasScale
                                        state.translateSelected(dx: dx, dy: dy)
                                        gizmoDragOffset = .zero
                                    }
                            )
                    }
                    .frame(width: 240, height: 240)
                    .offset(gizmoDragOffset)
                    .position(centerScreen)

                // Precision dimension box (MAS-57): live while dragging a non-square
                // gizmo, editable after release. Esc / outside-tap dismisses it.
                if let kind = gizmoDimKind {
                    gizmoDimBox(kind: kind, centerModel: centerModel, centerScreen: centerScreen)
                }
            }

            // Draggable fillet/chamfer arrow at the active corner (MAS-91). Lives
            // on this top overlay layer (above the canvas drag gesture) so the
            // grab isn't stolen and re-interpreted as a corner pick.
            if state.currentTool.isCornerTool {
                filletArrowOverlay(size: viewSize, bounds: modelBounds)
            }

            // Scale tool gizmo (MAS-128): a draggable corner handle that scales the
            // selection live around the pivot, plus a pivot marker and factor pill.
            if state.currentTool == .scale, !state.selectedHandles.isEmpty,
               let bbox = state.selectionBBox, let pivot = scalePivotModel {
                let pivotScreen = toScreen(dx: Double(pivot.x), dy: Double(pivot.y), size: viewSize, bounds: modelBounds)
                // Handle sits at the bbox's far corner from the pivot — scaled live.
                let cornerModel = CGPoint(x: bbox.maxX, y: bbox.maxY)
                let baseScreen = toScreen(dx: Double(cornerModel.x), dy: Double(cornerModel.y), size: viewSize, bounds: modelBounds)
                let currentScale = isDraggingScale ? gizmoDragScale : CGFloat(state.scaleFactor)
                let handleScreen = CGPoint(
                    x: pivotScreen.x + (baseScreen.x - pivotScreen.x) * currentScale,
                    y: pivotScreen.y + (baseScreen.y - pivotScreen.y) * currentScale
                )

                // Pivot marker.
                Image(systemName: "scope")
                    .font(.system(size: 16))
                    .foregroundColor(Color.accent)
                    .position(pivotScreen)
                    .allowsHitTesting(false)

                // Diagonal guide from pivot to handle.
                Path { p in p.move(to: pivotScreen); p.addLine(to: handleScreen) }
                    .stroke(Color.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(isDraggingScale ? Color.accent : Color.accent.opacity(0.85))
                    .frame(width: 14, height: 14)
                    .overlay(Rectangle().stroke(Color.white, lineWidth: 1.5))
                    .rotationEffect(.degrees(45))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .position(handleScreen)
                    .gesture(
                        DragGesture(coordinateSpace: .named("canvas"))
                            .onChanged { val in
                                let d0 = hypot(baseScreen.x - pivotScreen.x, baseScreen.y - pivotScreen.y)
                                if !isDraggingScale { isDraggingScale = true; scaleDragStartDist = d0 }
                                let d1 = hypot(val.location.x - pivotScreen.x, val.location.y - pivotScreen.y)
                                let f = max(0.05, d1 / max(d0, 0.0001))
                                gizmoDragScale = f
                                state.scaleFactor = Double(f)
                            }
                            .onEnded { _ in
                                // Don't bake on release. Keep state.scaleFactor as a
                                // live preview so the factor pill and the tool-options
                                // field persist after letting go. The scale is only
                                // committed on Apply / Enter, or when the tool is
                                // deselected; Escape discards it.
                                isDraggingScale = false
                                gizmoDragScale = 1.0
                            }
                    )

                // Live factor pill.
                Text(String(format: "×%.3f", currentScale))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.accent.opacity(0.9)))
                    .position(x: handleScreen.x + 40, y: handleScreen.y - 14)
                    .allowsHitTesting(false)
            }

            // Fillet Drag Handle Overlay — only on a just-created rectangle, not
            // on plain re-selection (MAS-62).
            if let selected = state.selectedMeasurement,
               let p1 = selected.rectP1,
               let p2 = selected.rectP2,
               selected.entityHandle == state.justCreatedRectangleHandle {
                let filletRad = selected.filletRadius
                let maxX = max(p1.x, p2.x)
                let maxY = max(p1.y, p2.y)
                let handleScreen = toScreen(dx: Double(maxX - filletRad), dy: Double(maxY - filletRad), size: viewSize, bounds: modelBounds)
                
                Circle()
                    .fill(isHoveringFilletHandle || isDraggingFillet ? Color.accent.opacity(0.8) : Color.accent)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    )
                    .shadow(radius: 2)
                    .scaleEffect(isHoveringFilletHandle || isDraggingFillet ? 1.25 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHoveringFilletHandle || isDraggingFillet)
                    .position(handleScreen)
                    .onHover { hovering in
                        isHoveringFilletHandle = hovering
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .named("canvas"))
                            .onChanged { val in
                                isDraggingFillet = true
                                let modelPt = toModel(point: val.location, size: viewSize, bounds: modelBounds)
                                let w = abs(p2.x - p1.x)
                                let h = abs(p2.y - p1.y)
                                let maxFillet = Double(min(w, h)) / 2.0
                                let newFillet = 0.5 * (Double(maxX - modelPt.x) + Double(maxY - modelPt.y))
                                let clampedFillet = max(0.0, min(maxFillet, newFillet))
                                
                                state.sketchFilletRadius = clampedFillet
                                if let idx = state.measurements.firstIndex(where: { $0.id == selected.id }) {
                                    state.measurements[idx].filletRadius = clampedFillet
                                }
                                state.selectedMeasurement?.filletRadius = clampedFillet
                            }
                            .onEnded { _ in
                                isDraggingFillet = false
                                state.updateSelectedRectangleFillet(newFillet: state.sketchFilletRadius)
                            }
                    )
            }
            
            // Offset Drag Handle Overlay
            if state.currentTool == .offset,
               let handleInfo = getOffsetHandleInfo() {
                let scaleDir: CGFloat = state.offsetSide == "left" ? 1.0 : -1.0
                let handlePt = CGPoint(
                    x: handleInfo.basePoint.x + handleInfo.normal.x * CGFloat(state.offsetDistance) * scaleDir,
                    y: handleInfo.basePoint.y + handleInfo.normal.y * CGFloat(state.offsetDistance) * scaleDir
                )
                let handleScreen = toScreen(dx: Double(handlePt.x), dy: Double(handlePt.y), size: viewSize, bounds: modelBounds)
                
                Circle()
                    .fill(isHoveringOffsetHandle || isDraggingOffset ? Color.status_warn.opacity(0.8) : Color.status_warn)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    )
                    .shadow(radius: 2)
                    .scaleEffect(isHoveringOffsetHandle || isDraggingOffset ? 1.25 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHoveringOffsetHandle || isDraggingOffset)
                    // Generous, clearly-grabbable hit area; a high-priority gesture so
                    // grabbing the handle never also triggers the canvas marquee drag
                    // underneath it (which used to clobber the selection on release —
                    // the "ghost outline drags then vanishes" bug). Mirrors the
                    // fillet arrow's handling.
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                    .position(handleScreen)
                    .onHover { hovering in
                        isHoveringOffsetHandle = hovering
                    }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                            .onChanged { val in
                                isDraggingOffset = true
                                let modelPt = toModel(point: val.location, size: viewSize, bounds: modelBounds)
                                let vecX = modelPt.x - handleInfo.basePoint.x
                                let vecY = modelPt.y - handleInfo.basePoint.y
                                let proj = vecX * handleInfo.normal.x + vecY * handleInfo.normal.y
                                state.offsetDistance = max(0.1, abs(proj))
                                state.offsetSide = proj >= 0 ? "left" : "right"
                            }
                            .onEnded { _ in
                                isDraggingOffset = false
                                // Dragging only sizes the live preview; the user
                                // commits with OK / Enter / click-away (MAS-109).
                            }
                    )

                // Floating distance pill next to the handle (MAS-109).
                Text(String(format: "%.2f mm", state.offsetDistance))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.status_warn.opacity(0.9)))
                    .position(x: handleScreen.x + 38, y: handleScreen.y - 14)
                    .allowsHitTesting(false)
            }

            // Add Holes — draggable margin handle (MAS-121). Brings the standard
            // perpendicular-arrow handle to the sewing-margin distance, which was
            // previously editable only via the numeric field.
            if state.currentTool == .addHoles,
               let handleInfo = getOffsetHandleInfo() {
                let scaleDir: CGFloat = state.holeSide == "left" ? 1.0 : -1.0
                let handlePt = CGPoint(
                    x: handleInfo.basePoint.x + handleInfo.normal.x * CGFloat(state.holeOffsetDistance) * scaleDir,
                    y: handleInfo.basePoint.y + handleInfo.normal.y * CGFloat(state.holeOffsetDistance) * scaleDir
                )
                let handleScreen = toScreen(dx: Double(handlePt.x), dy: Double(handlePt.y), size: viewSize, bounds: modelBounds)

                Circle()
                    .fill(Color.purple)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(radius: 2)
                    .position(handleScreen)
                    .gesture(
                        DragGesture(coordinateSpace: .named("canvas"))
                            .onChanged { val in
                                // Fast path: show an instant native offset ghost
                                // while dragging instead of the slow Python hole
                                // pipeline (see updateLivePreview).
                                state.isDraggingHoleOffset = true
                                let modelPt = toModel(point: val.location, size: viewSize, bounds: modelBounds)
                                let vecX = modelPt.x - handleInfo.basePoint.x
                                let vecY = modelPt.y - handleInfo.basePoint.y
                                let proj = vecX * handleInfo.normal.x + vecY * handleInfo.normal.y
                                state.holeOffsetDistance = max(0.0, abs(proj))
                                state.holeSide = proj >= 0 ? "left" : "right"
                                state.updateLivePreview()
                            }
                            .onEnded { _ in
                                // Drag finished — compute the accurate hole pattern once.
                                state.isDraggingHoleOffset = false
                                state.updateLivePreview()
                            }
                    )

                Text(String(format: "%.2f mm", state.holeOffsetDistance))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.purple.opacity(0.9)))
                    .position(x: handleScreen.x + 40, y: handleScreen.y - 14)
                    .allowsHitTesting(false)
            }

            // Glue Tab Start/End Offset Drag Handles
            if state.currentTool == .paperFolding,
               let ent = getSelectedLineEntity(),
               let s = ent.start,
               let e = ent.end {
                let p1 = CGPoint(x: s[0], y: s[1])
                let p2 = CGPoint(x: e[0], y: e[1])
                let dx = p2.x - p1.x
                let dy = p2.y - p1.y
                let L = hypot(dx, dy)
                
                if L >= 0.1 {
                    let ux = dx / L
                    let uy = dy / L
                    
                    let startOffset = CGFloat(state.glueTabStartOffset)
                    let endOffset = CGFloat(state.glueTabEndOffset)
                    
                    // Coordinates in model space
                    let h1Model = CGPoint(x: p1.x + startOffset * ux, y: p1.y + startOffset * uy)
                    let h2Model = CGPoint(x: p2.x - endOffset * ux, y: p2.y - endOffset * uy)
                    
                    // Coordinates in screen space
                    let h1Screen = toScreen(dx: Double(h1Model.x), dy: Double(h1Model.y), size: viewSize, bounds: modelBounds)
                    let h2Screen = toScreen(dx: Double(h2Model.x), dy: Double(h2Model.y), size: viewSize, bounds: modelBounds)
                    
                    // Start Offset Handle (Purple circular handle)
                    Circle()
                        .fill(isHoveringStartOffset || isDraggingStartOffset ? Color.purple.opacity(0.8) : Color.purple)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .shadow(radius: 2)
                        .scaleEffect(isHoveringStartOffset || isDraggingStartOffset ? 1.25 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHoveringStartOffset || isDraggingStartOffset)
                        .position(h1Screen)
                        .onHover { hovering in
                            isHoveringStartOffset = hovering
                        }
                        .gesture(
                            DragGesture(coordinateSpace: .named("canvas"))
                                .onChanged { val in
                                    isDraggingStartOffset = true
                                    let modelPt = toModel(point: val.location, size: viewSize, bounds: modelBounds)
                                    let vecX = modelPt.x - p1.x
                                    let vecY = modelPt.y - p1.y
                                    let proj = vecX * ux + vecY * uy
                                    state.glueTabStartOffset = max(0.0, min(Double(L) - state.glueTabEndOffset - 1.0, Double(proj)))
                                }
                                .onEnded { _ in
                                    isDraggingStartOffset = false
                                }
                        )
                        
                    // End Offset Handle (Purple circular handle)
                    Circle()
                        .fill(isHoveringEndOffset || isDraggingEndOffset ? Color.purple.opacity(0.8) : Color.purple)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .shadow(radius: 2)
                        .scaleEffect(isHoveringEndOffset || isDraggingEndOffset ? 1.25 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHoveringEndOffset || isDraggingEndOffset)
                        .position(h2Screen)
                        .onHover { hovering in
                            isHoveringEndOffset = hovering
                        }
                        .gesture(
                            DragGesture(coordinateSpace: .named("canvas"))
                                .onChanged { val in
                                    isDraggingEndOffset = true
                                    let modelPt = toModel(point: val.location, size: viewSize, bounds: modelBounds)
                                    let vecX = p2.x - modelPt.x
                                    let vecY = p2.y - modelPt.y
                                    let proj = vecX * ux + vecY * uy
                                    state.glueTabEndOffset = max(0.0, min(Double(L) - state.glueTabStartOffset - 1.0, Double(proj)))
                                }
                                .onEnded { _ in
                                    isDraggingEndOffset = false
                                }
                        )
                }
            }
            
            // Calibration Points visual markers
            if state.isCalibrationActive || state.isCalibratingDistanceInput {
                if state.calibrationPoints.count == 2 {
                    let p1 = toScreen(dx: state.calibrationPoints[0].x, dy: state.calibrationPoints[0].y, size: viewSize, bounds: modelBounds)
                    let p2 = toScreen(dx: state.calibrationPoints[1].x, dy: state.calibrationPoints[1].y, size: viewSize, bounds: modelBounds)
                    Path { path in
                        path.move(to: p1)
                        path.addLine(to: p2)
                    }
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                
                ForEach(Array(state.calibrationPoints.enumerated()), id: \.offset) { idx, pt in
                    let screenPt = toScreen(dx: pt.x, dy: pt.y, size: viewSize, bounds: modelBounds)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .position(screenPt)
                        .overlay(
                            Text("Point \(idx + 1)")
                                .font(.caption)
                                .foregroundColor(.red)
                                .offset(y: -12)
                                .position(screenPt)
                        )
                }
            }
        }
    }

    /// Always-on pill naming the active tool, pinned to the canvas top-left, so
    /// the current operation is identifiable at a glance (the toolbar only shows
    /// icons). Non-interactive so it never intercepts canvas input.
    @ViewBuilder
    private func activeToolPill() -> some View {
        VStack {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: state.currentTool.icon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(state.currentTool.rawValue.uppercased())
                        .font(PlasticityFont.label)
                        .tracking(0.5)
                }
                .foregroundColor(.text_secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.bg_panel.opacity(0.9))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
                Spacer()
            }
            Spacer()
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func coordinatesOverlay() -> some View {
        Group {
            if let coords = hoverCoords {
                HStack(spacing: 8) {
                    Text("X: \(String(format: "%.2f", coords.x)) mm")
                    Text("Y: \(String(format: "%.2f", coords.y)) mm")
                }
                .font(PlasticityFont.label)
                .foregroundColor(.text_secondary)
                .padding(6)
                .background(Color.bg_panel)
                .cornerRadius(4)
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func editingTextFieldsOverlay(size viewSize: CGSize, modelBounds: CGRect) -> some View {
        @Bindable var state = state
        Group {
            if let editing = editingDimension {
                let isParam = editing.isParametric
                TextField("", text: $editingDimensionText, onCommit: {
                    commitDimensionField(size: viewSize, modelBounds: modelBounds)
                })
                .onSubmit {
                    commitDimensionField(size: viewSize, modelBounds: modelBounds)
                }
                .onChange(of: editingDimensionText) { _, _ in dimensionFieldError = false }
                .focused($isDimensionEditorFocused)
                .onKeyPress(.tab) {
                    // Parametric dimensions are placed one at a time, so Tab just
                    // commits; auto-dimensions cycle width→height (MAS-90).
                    if isParam {
                        commitDimensionField(size: viewSize, modelBounds: modelBounds)
                    } else {
                        cycleDimension(size: viewSize, modelBounds: modelBounds)
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    // Esc drops the dimension box and returns to Select, hiding the
                    // auto-dimension lines (same as Enter).
                    finishDimensioning()
                    return .handled
                }
                .ifCondition(!isParam) { view in
                    // Auto-dimension fields are numeric-only; a letter exits them.
                    // Parametric fields must accept letters for formulas (d1, sqrt).
                    view.onKeyPress(characters: CharacterSet.letters) { _ in
                        editingDimension = nil
                        isDimensionEditorFocused = false
                        return .handled
                    }
                }
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.bg_panel)
                .foregroundColor(dimensionFieldError ? Color.status_err : Color.text_primary)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(dimensionFieldError ? Color.status_err : Color.accent, lineWidth: 1.5))
                .frame(width: isParam ? 110 : 80)
                .position(editingDimensionScreenPos)
                .shadow(radius: 4)
                .help(isParam ? "Type a value or formula — e.g. 50, d1*2+10, sqrt(d2^2+d3^2), 1 inch" : "")
            }
            
            if state.isCalibratingDistanceInput {
                TextField("", text: $state.calibrationTempDistanceText, onCommit: {
                    state.commitCalibrationDistance()
                })
                .onSubmit {
                    state.commitCalibrationDistance()
                }
                .focused($isCalibrationInputFocused)
                .onKeyPress(.escape) {
                    state.calibrationPoints.removeAll()
                    state.isCalibratingDistanceInput = false
                    return .handled
                }
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.bg_panel)
                .foregroundColor(Color.text_primary)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accent, lineWidth: 1.5))
                .frame(width: 80)
                .position(state.calibrationInputScreenPos)
                .shadow(radius: 4)
            }
            
            if state.isEditingText {
                // The inline editor is rendered to be pixel-for-pixel identical to
                // the committed text (MAS-135): same font family (incl. live
                // hover-preview), same point size (height × scale — NOT shrunk),
                // same per-line baseline, and no wrapping (text extends right; only
                // Shift+Enter adds a line, Enter commits). The box is content-sized
                // so it never clips or pushes text "up and above".
                let scale = state.canvasScale
                let family = state.fontHoverPreview ?? state.editingTextFont
                let fontSize = max(8.0, CGFloat(state.editingTextHeight) * scale)
                let nsFont = DxfCanvasView.resolveNSFont(
                    family: family, size: fontSize,
                    bold: state.editingTextBold, italic: state.editingTextItalic)
                let kerning = CGFloat(state.editingTextCharSpacing) * scale
                let ascender = nsFont.ascender
                let lineHeight = ceil(nsFont.ascender - nsFont.descender + nsFont.leading)
                let lines = state.editingTextString.isEmpty ? [""]
                    : state.editingTextString.components(separatedBy: "\n")
                let attrs: [NSAttributedString.Key: Any] = [.font: nsFont, .kern: kerning]
                let contentW = lines.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 0
                let boxW = max(40.0, ceil(contentW) + fontSize)   // caret room + slack
                let boxH = lineHeight * CGFloat(lines.count)
                // The insert point is the first line's baseline-left; the editor is
                // top-aligned with no inset, so place its top one ascender above it.
                let baseline = toScreen(dx: state.editingTextInsert.x,
                                        dy: state.editingTextInsert.y,
                                        size: viewSize, bounds: modelBounds)
                let topLeftX = baseline.x
                let topLeftY = baseline.y - ascender

                InlineTextEditor(
                    text: $state.editingTextString,
                    font: nsFont,
                    textColor: NSColor(Color.accent),
                    underline: state.editingTextUnderline,
                    kerning: kerning,
                    onCommit: { state.commitTextEditing() },
                    onCancel: { state.cancelTextEditing() }
                )
                .frame(width: boxW, height: boxH, alignment: .topLeading)
                .background(Color.bg_panel.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accent.opacity(0.7), lineWidth: 1.0))
                .position(x: topLeftX + boxW / 2, y: topLeftY + boxH / 2)
            }
        }
    }

    private func renderCanvas(_ parentContext: inout GraphicsContext, size: CGSize, modelBounds: CGRect) {
        var context = parentContext
        defer { parentContext = context }
        // Draw Grid
        if state.gridVisible {
            drawGrid(context: context, size: size, bounds: modelBounds)
        }
        
        // Draw visual origin axes at (0,0)
        let originScreen = toScreen(dx: 0.0, dy: 0.0, size: size, bounds: modelBounds)
        var xAxisPath = SwiftUI.Path()
        xAxisPath.move(to: CGPoint(x: 0, y: originScreen.y))
        xAxisPath.addLine(to: CGPoint(x: size.width, y: originScreen.y))
        context.stroke(xAxisPath, with: .color(Color.red.opacity(0.4)), lineWidth: 1.0)
        
        var yAxisPath = SwiftUI.Path()
        yAxisPath.move(to: CGPoint(x: originScreen.x, y: 0))
        yAxisPath.addLine(to: CGPoint(x: originScreen.x, y: size.height))
        context.stroke(yAxisPath, with: .color(Color.green.opacity(0.4)), lineWidth: 1.0)
        
        // Precompute layer lookup dictionary for O(1) rendering performance
        var layerLookup: [String: DXFLayer] = [:]
        for layer in state.layers {
            layerLookup[layer.id] = layer
            layerLookup[layer.name] = layer
        }
        
        let getLayerFast: (DXFEntity) -> DXFLayer? = { ent in
            if let lid = ent.layerId, let matched = layerLookup[lid] {
                return matched
            }
            return layerLookup[ent.layer]
        }

        // Draw Entities
        let viewRect = CGRect(x: 0, y: 0, width: size.width, height: size.height).insetBy(dx: -40, dy: -40)
        for ent in state.entities {
            let matchedLayer = getLayerFast(ent)
            let layerVisible: Bool = matchedLayer?.visible ?? true
            if !layerVisible { continue }

            // While dragging the radius arrow, the committed geometry for the
            // active shape is stale — the local blend preview (drawn below) stands
            // in for it, so skip the real entity to avoid a doubled outline.
            if isDraggingFilletArrow && ent.handle == state.filletSelectedHandle { continue }

            // While re-editing a pen path, its baked polyline is replaced by the
            // live editable overlay (parametric pen lines) — hide the original so
            // the user doesn't see a doubled outline.
            if ent.handle == editingPenHandle { continue }

            // Viewport culling (MAS-74): skip entities whose screen bounds fall
            // entirely outside the visible canvas. Selected entities are never
            // culled (the gizmo transform can move them into view mid-drag).
            let isSelected = state.selectedHandles.contains(ent.handle)
            if !isSelected, let sb = entityScreenBounds(ent, size: size, modelBounds: modelBounds),
               !sb.intersects(viewRect) {
                continue
            }
            let isHovered = (state.hoveredHandle == ent.handle)
            let isGuidePath = (state.currentTool == .patterning && state.patternMode == "path" && state.patternPathHandle == ent.handle)
            
            let baseColor: Color = matchedLayer?.color ?? Color.text_primary
            let strokeColor: Color
            if isSelected {
                strokeColor = Color.accent
            } else if isGuidePath {
                strokeColor = Color.orange
            } else if isHovered {
                strokeColor = Color.accent_hover
            } else {
                strokeColor = baseColor
            }
            let strokeWidth = isSelected ? 1.8 : (isGuidePath ? 1.8 : (isHovered ? 1.4 : 0.8))

            // Perf (MAS-74): only selected entities need an isolated layer (to
            // carry the live gizmo drag/rotation transform). Drawing the bulk of
            // an imported file directly — no per-entity offscreen `drawLayer` —
            // dramatically cuts compositing cost on complex SVGs.
            if isSelected {
                context.drawLayer { context in
                    let dxOffset = gizmoDragOffset.width
                    let dyOffset = gizmoDragOffset.height
                    context.translateBy(x: dxOffset, y: dyOffset)

                    if let centerModel = selectionCenterModel {
                        let centerScreen = toScreen(dx: Double(centerModel.x), dy: Double(centerModel.y), size: size, bounds: modelBounds)
                        context.translateBy(x: centerScreen.x, y: centerScreen.y)
                        context.rotate(by: Angle(degrees: gizmoDragRotation))
                        context.translateBy(x: -centerScreen.x, y: -centerScreen.y)
                    }

                    // Live scale preview around the pivot (MAS-128) — identity when
                    // not scaling, so it never disturbs move/rotate.
                    let currentScale = isDraggingScale ? gizmoDragScale : CGFloat(state.scaleFactor)
                    if currentScale != 1.0, let pivot = scalePivotModel {
                        let ps = toScreen(dx: Double(pivot.x), dy: Double(pivot.y), size: size, bounds: modelBounds)
                        context.translateBy(x: ps.x, y: ps.y)
                        context.scaleBy(x: currentScale, y: currentScale)
                        context.translateBy(x: -ps.x, y: -ps.y)
                    }

                    drawEntity(ent, baseColor: baseColor, strokeColor: strokeColor, strokeWidth: strokeWidth, size: size, modelBounds: modelBounds, context: &context)
                }
            } else {
                drawEntity(ent, baseColor: baseColor, strokeColor: strokeColor, strokeWidth: strokeWidth, size: size, modelBounds: modelBounds, context: &context)
            }
        }
        
        // Lag-free local preview of the corner being dragged (fillet perf): the
        // committed entity is hidden above, so draw the freshly-blended outline
        // here directly from the parametric model — no Python, no reload.
        if isDraggingFilletArrow, let h = state.filletSelectedHandle,
           let model = state.parametricShapes[h] {
            let pts = parametricOutlinePoints(model)
            if pts.count >= 2 {
                var path = SwiftUI.Path()
                path.move(to: toScreen(dx: Double(pts[0].x), dy: Double(pts[0].y), size: size, bounds: modelBounds))
                for p in pts.dropFirst() {
                    path.addLine(to: toScreen(dx: Double(p.x), dy: Double(p.y), size: size, bounds: modelBounds))
                }
                if model.closed { path.closeSubpath() }
                context.stroke(path, with: .color(Color.accent), lineWidth: 1.8)
            }
        }

        // Trim tool hover preview (MAS-98): highlight, in red, the exact piece the
        // cursor is over — i.e. what a click/drag would remove.
        if state.currentTool == .trim {
            let modelPt = toModel(point: mouseLocation, size: size, bounds: modelBounds)
            if let target = trimTargetUnderCursor(modelPt: modelPt, size: size, modelBounds: modelBounds),
               target.killPath.count >= 2 {
                var hp = SwiftUI.Path()
                hp.move(to: toScreen(dx: Double(target.killPath[0].x), dy: Double(target.killPath[0].y), size: size, bounds: modelBounds))
                for p in target.killPath.dropFirst() {
                    hp.addLine(to: toScreen(dx: Double(p.x), dy: Double(p.y), size: size, bounds: modelBounds))
                }
                context.stroke(hp, with: .color(Color.status_err), style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round))
            }
        }

        // Patterning v2 live ghost preview (MAS-113): dashed translucent copies of
        // the selection at every instance position, updated as the panel/handles
        // change. Faithful (re-draws the real entities transformed), not a bbox.
        if state.currentTool == .patterning, !state.selectedHandles.isEmpty {
            drawPatterningGhost(size: size, modelBounds: modelBounds, context: &context)
        }

        // Draw Live Preview Entities (Dashed Orange Lines)
        for ent in state.previewEntities {
            let strokeColor = Color.status_warn
            let strokeStyle = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [4, 4])
            drawPreviewEntity(ent, strokeColor: strokeColor, strokeStyle: strokeStyle, size: size, modelBounds: modelBounds, context: &context)
        }
        
        // Draw Glue Tab Preview
        if state.currentTool == .paperFolding,
           let ent = getSelectedLineEntity() {
            drawGlueTabPreview(ent, size: size, modelBounds: modelBounds, context: &context)
        }
        
        // Draw Locked Measurement Lines
        for measure in state.measurements {
            if measure.isAutoDimension {
                if let handle = measure.entityHandle {
                    let isSelected = state.selectedHandles.contains(handle)
                    let isBeingEdited = (editingDimension?.entityHandle == handle)
                    if !isSelected && !isBeingEdited {
                        continue
                    }
                } else {
                    continue
                }
                // Hide the selected entity's auto-dimension while rotating so no
                // extra "ghost" line shows during the spin.
                if isDraggingRotation { continue }
            }
            
            let isSelected = state.selectedMeasurement?.id == measure.id
            let isHovered = hoveredMeasurementId == measure.id
            let isMeasuringSelectedEntity = (measure.entityHandle != nil && state.selectedHandles.contains(measure.entityHandle!))
            
            context.drawLayer { context in
                if isMeasuringSelectedEntity {
                    let dxOffset = gizmoDragOffset.width
                    let dyOffset = gizmoDragOffset.height
                    context.translateBy(x: dxOffset, y: dyOffset)
                    
                    if let centerModel = selectionCenterModel {
                        let centerScreen = toScreen(dx: Double(centerModel.x), dy: Double(centerModel.y), size: size, bounds: modelBounds)
                        context.translateBy(x: centerScreen.x, y: centerScreen.y)
                        context.rotate(by: Angle(degrees: gizmoDragRotation))
                        context.translateBy(x: -centerScreen.x, y: -centerScreen.y)
                    }
                }
                
                drawMeasurement(measure, isSelected: isSelected, isHovered: isHovered, size: size, modelBounds: modelBounds, context: &context)
            }
        }
        
        // Draw Live Measurement Line
        if state.currentTool == .measure, let startModel = state.activeMeasureStart {
            let startScreen = toScreen(dx: startModel.x, dy: startModel.y, size: size, bounds: modelBounds)
            var mPath = SwiftUI.Path()
            mPath.move(to: startScreen)
            mPath.addLine(to: mouseLocation)
            context.stroke(mPath, with: .color(Color.status_warn), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
            
            let endModel = toModel(point: mouseLocation, size: size, bounds: modelBounds)
            let dist = Double(hypot(startModel.x - endModel.x, startModel.y - endModel.y))
            let labelText = String(format: "%.2f mm", dist)
            
            let midScreen = CGPoint(
                x: (startScreen.x + mouseLocation.x) / 2,
                y: (startScreen.y + mouseLocation.y) / 2
            )
            context.draw(
                Text(labelText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.status_warn),
                at: CGPoint(x: midScreen.x, y: midScreen.y - 10),
                anchor: .center
            )
        }
        
        // Draw Sketch Tools Live Preview
        if state.currentTool == .sketchLine, let startModel = sketchStartPoint {
            let snapped = snappedMouseLocation(size: size, bounds: modelBounds)
            let endModel = snapped.point
            let startScreen = toScreen(dx: startModel.x, dy: startModel.y, size: size, bounds: modelBounds)
            let endScreen = toScreen(dx: endModel.x, dy: endModel.y, size: size, bounds: modelBounds)
            
            var path = SwiftUI.Path()
            path.move(to: startScreen)
            path.addLine(to: endScreen)
            context.stroke(path, with: .color(Color.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            
            let dist = Double(hypot(startModel.x - endModel.x, startModel.y - endModel.y))
            let labelText = String(format: "L: %.2f mm", dist)
            context.draw(Text(labelText).font(.system(size: 10, weight: .bold)).foregroundColor(.accent), at: CGPoint(x: endScreen.x, y: endScreen.y - 10), anchor: .center)
        } else if state.currentTool == .sketchCircle, let startModel = sketchStartPoint {
            let snapped = snappedMouseLocation(size: size, bounds: modelBounds)
            let endModel = snapped.point
            let startScreen = toScreen(dx: startModel.x, dy: startModel.y, size: size, bounds: modelBounds)
            let endScreen = toScreen(dx: endModel.x, dy: endModel.y, size: size, bounds: modelBounds)
            let rModel = Double(hypot(startModel.x - endModel.x, startModel.y - endModel.y))
            let rScreen = CGFloat(rModel) * state.canvasScale
            
            var path = SwiftUI.Path()
            path.addEllipse(in: CGRect(x: startScreen.x - rScreen, y: startScreen.y - rScreen, width: rScreen * 2, height: rScreen * 2))
            context.stroke(path, with: .color(Color.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            
            var radLine = SwiftUI.Path()
            radLine.move(to: startScreen)
            radLine.addLine(to: endScreen)
            context.stroke(radLine, with: .color(Color.accent.opacity(0.5)), lineWidth: 1.0)
            
            let labelText = String(format: "R: %.2f mm", rModel)
            context.draw(Text(labelText).font(.system(size: 10, weight: .bold)).foregroundColor(.accent), at: CGPoint(x: endScreen.x, y: endScreen.y - 10), anchor: .center)
        } else if state.currentTool == .sketchPolygon, let centerModel = sketchStartPoint {
            // Live preview: center + cursor define radius and rotation (MAS-118).
            let snapped = snappedMouseLocation(size: size, bounds: modelBounds)
            let endModel = snapped.point
            let r = Double(hypot(centerModel.x - endModel.x, centerModel.y - endModel.y))
            let rot = snappedPolygonRotation(Double(atan2(endModel.y - centerModel.y, endModel.x - centerModel.x)), sides: state.polygonSides)
            let pts = polygonPoints(center: centerModel, radius: r, rotation: rot, sides: state.polygonSides)
            if pts.count >= 3 {
                var path = SwiftUI.Path()
                path.move(to: toScreen(dx: pts[0].x, dy: pts[0].y, size: size, bounds: modelBounds))
                for p in pts.dropFirst() {
                    path.addLine(to: toScreen(dx: p.x, dy: p.y, size: size, bounds: modelBounds))
                }
                path.closeSubpath()
                context.stroke(path, with: .color(Color.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            let endScreen = toScreen(dx: endModel.x, dy: endModel.y, size: size, bounds: modelBounds)
            context.draw(Text("Sides: \(state.polygonSides)  •  R: \(String(format: "%.2f", r)) mm")
                .font(.system(size: 10, weight: .bold)).foregroundColor(.accent),
                at: CGPoint(x: endScreen.x, y: endScreen.y - 12), anchor: .center)
        } else if state.currentTool == .sketchRectangle, let startModel = sketchStartPoint {
            let snapped = snappedMouseLocation(size: size, bounds: modelBounds)
            let endModel = snapped.point
            let p1 = toScreen(dx: startModel.x, dy: startModel.y, size: size, bounds: modelBounds)
            let p2 = toScreen(dx: endModel.x, dy: endModel.y, size: size, bounds: modelBounds)
            
            let pts = pointsOnRoundedRectangle(p1: startModel, p2: endModel, r: state.sketchFilletRadius)
            if pts.count >= 2 {
                var path = SwiftUI.Path()
                let pStart = toScreen(dx: pts[0].x, dy: pts[0].y, size: size, bounds: modelBounds)
                path.move(to: pStart)
                for i in 1..<pts.count {
                    let p = toScreen(dx: pts[i].x, dy: pts[i].y, size: size, bounds: modelBounds)
                    path.addLine(to: p)
                }
                path.closeSubpath()
                context.stroke(path, with: .color(Color.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            
            let w = abs(endModel.x - startModel.x)
            let h = abs(endModel.y - startModel.y)
            let labelText = String(format: "W: %.2f | H: %.2f mm", w, h)
            context.draw(Text(labelText).font(.system(size: 10, weight: .bold)).foregroundColor(.accent), at: CGPoint(x: p2.x, y: p2.y - 10), anchor: .center)
        } else if state.currentTool == .sketchText, let startModel = sketchStartPoint {
            let snapped = snappedMouseLocation(size: size, bounds: modelBounds)
            let endModel = snapped.point
            let startScreen = toScreen(dx: startModel.x, dy: startModel.y, size: size, bounds: modelBounds)
            let endScreen = toScreen(dx: endModel.x, dy: endModel.y, size: size, bounds: modelBounds)
            
            let rect = CGRect(
                x: min(startScreen.x, endScreen.x),
                y: min(startScreen.y, endScreen.y),
                width: abs(startScreen.x - endScreen.x),
                height: abs(startScreen.y - endScreen.y)
            )
            var boxPath = SwiftUI.Path()
            boxPath.addRect(rect)
            context.stroke(boxPath, with: .color(Color.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            
            let w = abs(endModel.x - startModel.x)
            let h = abs(endModel.y - startModel.y)
            let labelText = String(format: "W: %.2f | H: %.2f mm", w, h)
            context.draw(Text(labelText).font(.system(size: 10, weight: .bold)).foregroundColor(.accent), at: CGPoint(x: endScreen.x, y: endScreen.y - 10), anchor: .center)
        }
        
        // Pen tool live path (MAS-94): committed bezier/line segments, the
        // rubber-band to the cursor, anchor squares, and handle dots.
        if state.currentTool == .pen, !penAnchors.isEmpty {
            func scr(_ p: CGPoint) -> CGPoint { toScreen(dx: p.x, dy: p.y, size: size, bounds: modelBounds) }

            if penAnchors.count >= 2 {
                var path = SwiftUI.Path()
                path.move(to: scr(penAnchors[0].point))
                for i in 0..<(penAnchors.count - 1) {
                    let a = penAnchors[i], b = penAnchors[i + 1]
                    if a.handleOut == nil && b.handleIn == nil {
                        path.addLine(to: scr(b.point))
                    } else {
                        path.addCurve(to: scr(b.point),
                                      control1: scr(a.handleOut ?? a.point),
                                      control2: scr(b.handleIn ?? b.point))
                    }
                }
                // Re-editing a closed loop: draw the closing segment too.
                if editingPenHandle != nil, penEditingClosed, penAnchors.count >= 3 {
                    let a = penAnchors[penAnchors.count - 1], b = penAnchors[0]
                    if a.handleOut == nil && b.handleIn == nil {
                        path.addLine(to: scr(b.point))
                    } else {
                        path.addCurve(to: scr(b.point),
                                      control1: scr(a.handleOut ?? a.point),
                                      control2: scr(b.handleIn ?? b.point))
                    }
                }
                context.stroke(path, with: .color(Color.accent), lineWidth: 1.5)
            }

            // Rubber-band preview from the last anchor to the cursor (not while
            // re-editing a closed loop — there is nothing to extend).
            if let last = penAnchors.last, !penDraggingHandle, !(editingPenHandle != nil && penEditingClosed) {
                var rb = SwiftUI.Path()
                rb.move(to: scr(last.point))
                if let hOut = last.handleOut {
                    rb.addCurve(to: mouseLocation, control1: scr(hOut), control2: mouseLocation)
                } else {
                    rb.addLine(to: mouseLocation)
                }
                context.stroke(rb, with: .color(Color.accent.opacity(0.5)), style: StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
            }

            // Handles + anchor markers.
            for (idx, a) in penAnchors.enumerated() {
                let s = scr(a.point)
                if let hOut = a.handleOut {
                    let ho = scr(hOut), hi = scr(a.handleIn ?? a.point)
                    var hl = SwiftUI.Path(); hl.move(to: hi); hl.addLine(to: ho)
                    context.stroke(hl, with: .color(Color.accent.opacity(0.6)), lineWidth: 1.0)
                    for hp in [ho, hi] {
                        var d = SwiftUI.Path(); d.addEllipse(in: CGRect(x: hp.x - 2.5, y: hp.y - 2.5, width: 5, height: 5))
                        context.fill(d, with: .color(Color.accent))
                    }
                }
                let isClosable = (idx == 0 && penAnchors.count >= 2)
                let nearFirst = isClosable && hypot(mouseLocation.x - s.x, mouseLocation.y - s.y) < 10
                var sq = SwiftUI.Path(); sq.addRect(CGRect(x: s.x - 2.5, y: s.y - 2.5, width: 5, height: 5))
                context.fill(sq, with: .color(nearFirst ? Color.status_ok : Color.accent))
                if nearFirst {
                    var ring = SwiftUI.Path(); ring.addEllipse(in: CGRect(x: s.x - 7, y: s.y - 7, width: 14, height: 14))
                    context.stroke(ring, with: .color(Color.status_ok), lineWidth: 1.5)
                }
            }
        }

        // Draw Snapping Hover Indicator (only when snapping is on)
        if state.snapActive, let hover = hoverCoords {
            let hoverScreen = toScreen(dx: Double(hover.x), dy: Double(hover.y), size: size, bounds: modelBounds)
            if let snap = getSnappedPoint(for: hoverScreen, size: size, bounds: modelBounds) {
                let snapPt = snap.snappedScreenPt
                let snapRect = CGRect(x: snapPt.x - 4, y: snapPt.y - 4, width: 8, height: 8)
                var snapPath = SwiftUI.Path()
                snapPath.addRect(snapRect)
                context.stroke(snapPath, with: .color(Color.orange), lineWidth: 2.0)
                
                let font = Font.system(size: 9, weight: .semibold)
                let text = context.resolve(Text(snap.type.rawValue).font(font).foregroundColor(.orange))
                context.draw(text, at: CGPoint(x: snapPt.x + 8, y: snapPt.y - 4), anchor: .leading)
            }
        }
        
        // Draw Selection Rectangle
        if let start = dragSelectionStart, let end = dragSelectionEnd {
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(start.x - end.x),
                height: abs(start.y - end.y)
            )
            var boxPath = SwiftUI.Path()
            boxPath.addRect(rect)
            context.fill(boxPath, with: .color(Color.accent.opacity(0.12)))
            context.stroke(boxPath, with: .color(Color.accent), style: StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
        }
        
        // Draw Fillet Control Arrow
        drawFilletControlArrow(&context, size: size, modelBounds: modelBounds)
        
        // Draw Offset Control Arrow (Perpendicular style)
        drawOffsetControlArrow(&context, size: size, modelBounds: modelBounds)

        // Draw editable vertex handles for selected shapes (MAS-62)
        drawVertexHandles(&context, size: size, modelBounds: modelBounds)

        // Draw fillet/chamfer corner pick handles (MAS-62)
        drawFilletCornerHandles(&context, size: size, modelBounds: modelBounds)
        
        // Draw neon-cyan live image tracing preview
        if state.isTracingRefImage, let activeL = state.activeLayer, activeL.isReferenceImageLayer {
            drawTracePreview(&context, size: size, modelBounds: modelBounds, layer: activeL)
        }
    }

    /// Small square handles at the vertices of selected lines/polylines. Hollow
    /// for a still-parametric rectangle (a hint that it must be Expanded before
    /// its corners can move), filled for a freely-editable shape (MAS-62).
    private func drawVertexHandles(_ context: inout GraphicsContext, size: CGSize, modelBounds: CGRect) {
        guard state.currentTool == .select else { return }
        for handle in state.selectedHandles {
            guard let ent = state.entities.first(where: { $0.handle == handle }) else { continue }
            // Pen paths are re-edited by double-click (parametric pen lines), so
            // skip their per-vertex dots — for a curve those are dense flattened
            // points the user can't meaningfully grab.
            if state.penPaths[handle] != nil { continue }
            // For a parametric shape, the editable vertices include all the dense
            // flattened points along each fillet/chamfer arc — those represent
            // nothing the user can grab, so show only the sharp base corners.
            let verts: [[Double]]
            if let model = state.parametricShapes[handle] {
                verts = model.base
            } else {
                verts = ent.editableVertices
            }
            guard !verts.isEmpty else { continue }
            let isRect = state.isRectangleHandle(handle)
            for v in verts where v.count >= 2 {
                let s = toScreen(dx: v[0], dy: v[1], size: size, bounds: modelBounds)
                let r: CGFloat = 3.5
                let rect = CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)
                var p = SwiftUI.Path()
                p.addRect(rect)
                if isRect {
                    context.fill(p, with: .color(Color.bg_base))
                    context.stroke(p, with: .color(Color.accent), lineWidth: 1.5)
                } else {
                    context.fill(p, with: .color(Color.accent))
                    context.stroke(p, with: .color(.white), lineWidth: 1.0)
                }
            }
        }
    }

    /// Corner candidates for the corner tools: a parametric shape uses its sharp
    /// base corners (so a filleted corner is still grabbable at its original
    /// point); a plain polyline uses its vertices (MAS-62). `hasMod` = currently
    /// filleted/chamfered.
    private func cornerHandles(for ent: DXFEntity) -> [(index: Int, pt: [Double], hasMod: Bool)] {
        if let model = state.parametricShapes[ent.handle] {
            let targets: [Int] = model.closed
                ? Array(0..<model.base.count)
                : (model.base.count >= 3 ? Array(1..<(model.base.count - 1)) : [])
            let modSet = Set(model.corners.map { $0.index })
            return targets.compactMap { i in i < model.base.count ? (i, model.base[i], modSet.contains(i)) : nil }
        }
        let verts = ent.editableVertices
        return ent.filletableCornerIndices.filter { $0 < verts.count }.map { ($0, verts[$0], false) }
    }

    // MARK: - Trim tool geometry (MAS-98)

    /// The straight edges of a trimmable entity in model space (a LINE is one
    /// edge; a polyline is its consecutive vertex pairs plus the closing edge).
    private func trimEdges(of ent: DXFEntity) -> [(CGPoint, CGPoint)] {
        let t = ent.type.uppercased()
        if t == "LINE", let s = ent.start, let e = ent.end, s.count >= 2, e.count >= 2 {
            return [(CGPoint(x: s[0], y: s[1]), CGPoint(x: e[0], y: e[1]))]
        }
        if t == "LWPOLYLINE" || t == "POLYLINE" {
            let v = ent.editableVertices
            guard v.count >= 2 else { return [] }
            var edges: [(CGPoint, CGPoint)] = []
            for i in 0..<(v.count - 1) {
                edges.append((CGPoint(x: v[i][0], y: v[i][1]), CGPoint(x: v[i+1][0], y: v[i+1][1])))
            }
            if (ent.closed ?? false), v.count > 2, let f = v.first, let l = v.last {
                edges.append((CGPoint(x: l[0], y: l[1]), CGPoint(x: f[0], y: f[1])))
            }
            return edges
        }
        return []
    }

    private func distancePointToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let l2 = dx*dx + dy*dy
        if l2 < 1e-12 { return hypot(Double(p.x - a.x), Double(p.y - a.y)) }
        var t = (Double(p.x - a.x)*dx + Double(p.y - a.y)*dy) / l2
        t = max(0, min(1, t))
        return hypot(Double(p.x) - (Double(a.x) + dx*t), Double(p.y) - (Double(a.y) + dy*t))
    }

    /// Parameter t∈(0,1) where segment p0→p1 crosses q0→q1 (nil if no crossing).
    private func segIntersectParam(_ p0: CGPoint, _ p1: CGPoint, _ q0: CGPoint, _ q1: CGPoint) -> Double? {
        let rx = Double(p1.x - p0.x), ry = Double(p1.y - p0.y)
        let sx = Double(q1.x - q0.x), sy = Double(q1.y - q0.y)
        let denom = rx*sy - ry*sx
        if abs(denom) < 1e-12 { return nil }
        let qpx = Double(q0.x - p0.x), qpy = Double(q0.y - p0.y)
        let t = (qpx*sy - qpy*sx) / denom
        let u = (qpx*ry - qpy*rx) / denom
        if t >= -1e-9 && t <= 1 + 1e-9 && u >= -1e-9 && u <= 1 + 1e-9 { return t }
        return nil
    }

    private func circleIntersectParams(_ p0: CGPoint, _ p1: CGPoint, cx: Double, cy: Double, r: Double) -> [Double] {
        let rx = Double(p1.x - p0.x), ry = Double(p1.y - p0.y)
        let a = rx*rx + ry*ry
        if a < 1e-12 { return [] }
        let fx = Double(p0.x) - cx, fy = Double(p0.y) - cy
        let b = 2*(fx*rx + fy*ry)
        let c = fx*fx + fy*fy - r*r
        let disc = b*b - 4*a*c
        if disc < 0 { return [] }
        let sq = disc.squareRoot()
        return [(-b - sq)/(2*a), (-b + sq)/(2*a)].filter { $0 > 1e-9 && $0 < 1 - 1e-9 }
    }

    /// For the Trim tool: the entity edge nearest `modelPt` and the exact
    /// sub-segment a click there would remove — bounded by intersections with
    /// other geometry (or the edge's own ends). Mirrors the Python trim so the
    /// hover highlight matches what actually gets cut.
    private func trimTargetUnderCursor(modelPt: CGPoint, size: CGSize, modelBounds: CGRect)
        -> (handle: String, segIndex: Int, killPath: [CGPoint])? {
        let maxDist = Double(12.0 / state.canvasScale)
        var bestDist = maxDist

        // Nearest straight edge (line / polyline edge).
        var bestSeg: (handle: String, segIndex: Int, a: CGPoint, b: CGPoint)? = nil
        for ent in state.entities {
            for (i, seg) in trimEdges(of: ent).enumerated() {
                let d = distancePointToSegment(modelPt, seg.0, seg.1)
                if d < bestDist { bestDist = d; bestSeg = (ent.handle, i, seg.0, seg.1) }
            }
        }

        // Nearest circle / arc (radial distance to the curve; arcs only count
        // when the cursor is within their angular sweep). Circle trimming routes
        // through the Python op by click point, so we only need the handle and a
        // faithful red highlight of the span that a click would remove.
        var bestCirc: DXFEntity? = nil
        for ent in state.entities {
            let t = ent.type.uppercased()
            guard t == "CIRCLE" || t == "ARC", let c = ent.center, let r = ent.radius, c.count >= 2 else { continue }
            let dr = abs(hypot(Double(modelPt.x) - c[0], Double(modelPt.y) - c[1]) - r)
            if dr >= bestDist { continue }
            if t == "ARC", let sa = ent.start_angle, let ea = ent.end_angle {
                let ang = atan2(Double(modelPt.y) - c[1], Double(modelPt.x) - c[0])
                if !angleInArc(ang, sa, ea) { continue }
            }
            bestDist = dr; bestCirc = ent
        }

        if let ce = bestCirc {
            if let kill = circleKillPath(ent: ce, clickModel: modelPt) {
                return (ce.handle, 0, kill)
            }
            return nil
        }

        // Pen curves preview the whole portion a click removes (curves-as-curves).
        if let b = bestSeg, state.penPaths[b.handle] != nil,
           let ent = state.entities.first(where: { $0.handle == b.handle }),
           let kill = wholeCurveKillPath(ent: ent, clickModel: modelPt), kill.count >= 2 {
            return (b.handle, b.segIndex, kill)
        }

        guard let b = bestSeg else { return nil }
        let rx = Double(b.b.x - b.a.x), ry = Double(b.b.y - b.a.y)
        let rr = rx*rx + ry*ry
        guard rr > 1e-12 else { return nil }
        let tClick = max(0.0, min(1.0, ((Double(modelPt.x) - Double(b.a.x))*rx + (Double(modelPt.y) - Double(b.a.y))*ry)/rr))
        var cuts: [Double] = []
        for ent in state.entities where ent.handle != b.handle {
            for seg in trimEdges(of: ent) {
                if let t = segIntersectParam(b.a, b.b, seg.0, seg.1) { cuts.append(t) }
            }
            if ent.type.uppercased() == "CIRCLE", let c = ent.center, let r = ent.radius, c.count >= 2 {
                cuts.append(contentsOf: circleIntersectParams(b.a, b.b, cx: c[0], cy: c[1], r: r))
            } else if ent.type.uppercased() == "ARC", let c = ent.center, let r = ent.radius, c.count >= 2,
                      let sa = ent.start_angle, let ea = ent.end_angle {
                for t in circleIntersectParams(b.a, b.b, cx: c[0], cy: c[1], r: r) {
                    let ix = Double(b.a.x) + rx*t, iy = Double(b.a.y) + ry*t
                    if angleInArc(atan2(iy - c[1], ix - c[0]), sa, ea) { cuts.append(t) }
                }
            }
        }
        let interior = cuts.filter { $0 > 1e-6 && $0 < 1 - 1e-6 }.sorted()
        var lo = 0.0, hi = 1.0
        for t in interior where t <= tClick { lo = t }
        for t in interior.reversed() where t >= tClick { hi = t }
        func at(_ t: Double) -> CGPoint { CGPoint(x: Double(b.a.x) + rx*t, y: Double(b.a.y) + ry*t) }
        return (b.handle, b.segIndex, [at(lo), at(hi)])
    }

    private func norm2pi(_ a: Double) -> Double {
        let m = a.truncatingRemainder(dividingBy: 2 * .pi)
        return m < 0 ? m + 2 * .pi : m
    }

    private func angleInArc(_ theta: Double, _ startDeg: Double, _ endDeg: Double) -> Bool {
        let s = norm2pi(startDeg * .pi / 180)
        var sweep = norm2pi(endDeg * .pi / 180 - startDeg * .pi / 180)
        if sweep < 1e-9 { sweep = 2 * .pi }
        return norm2pi(theta - s) <= sweep + 1e-9
    }

    private func segCircleAngles(_ q0: CGPoint, _ q1: CGPoint, cx: Double, cy: Double, R: Double) -> [Double] {
        let dx = Double(q1.x - q0.x), dy = Double(q1.y - q0.y)
        let a = dx*dx + dy*dy
        if a < 1e-12 { return [] }
        let fx = Double(q0.x) - cx, fy = Double(q0.y) - cy
        let b = 2*(fx*dx + fy*dy)
        let c = fx*fx + fy*fy - R*R
        let disc = b*b - 4*a*c
        if disc < 1e-9 { return [] }   // miss or tangent
        let sq = disc.squareRoot()
        var out: [Double] = []
        for u in [(-b - sq)/(2*a), (-b + sq)/(2*a)] where u >= -1e-9 && u <= 1 + 1e-9 {
            out.append(atan2(Double(q0.y) + dy*u - cy, Double(q0.x) + dx*u - cx))
        }
        return out
    }

    private func circleCircleAngles(cx: Double, cy: Double, R: Double, ox: Double, oy: Double, oR: Double) -> [(ang: Double, x: Double, y: Double)] {
        let d = hypot(ox - cx, oy - cy)
        if d < 1e-9 || d > R + oR - 1e-7 || d < abs(R - oR) + 1e-7 { return [] }
        let a = (R*R - oR*oR + d*d) / (2*d)
        let h2 = R*R - a*a
        if h2 <= 1e-12 { return [] }
        let h = h2.squareRoot()
        let bx = cx + a*(ox - cx)/d, by = cy + a*(oy - cy)/d
        let px = -(oy - cy)/d, py = (ox - cx)/d
        var out: [(Double, Double, Double)] = []
        for sgn in [1.0, -1.0] {
            let ix = bx + sgn*h*px, iy = by + sgn*h*py
            out.append((atan2(iy - cy, ix - cx), ix, iy))
        }
        return out
    }

    /// Angles (rad, sorted, deduped) where the host circle/arc of radius R about
    /// (cx,cy) is crossed by every other entity — mirrors the Python trim so the
    /// hover highlight matches the cut.
    private func circleCrossingAngles(cx: Double, cy: Double, R: Double, exclude: String) -> [Double] {
        var angs: [Double] = []
        for ent in state.entities where ent.handle != exclude {
            let t = ent.type.uppercased()
            if t == "CIRCLE", let c = ent.center, let r = ent.radius, c.count >= 2 {
                for hit in circleCircleAngles(cx: cx, cy: cy, R: R, ox: c[0], oy: c[1], oR: r) { angs.append(hit.ang) }
            } else if t == "ARC", let c = ent.center, let r = ent.radius, c.count >= 2,
                      let sa = ent.start_angle, let ea = ent.end_angle {
                for hit in circleCircleAngles(cx: cx, cy: cy, R: R, ox: c[0], oy: c[1], oR: r) {
                    if angleInArc(atan2(hit.y - c[1], hit.x - c[0]), sa, ea) { angs.append(hit.ang) }
                }
            } else {
                for seg in trimEdges(of: ent) { angs += segCircleAngles(seg.0, seg.1, cx: cx, cy: cy, R: R) }
            }
        }
        let normd = angs.map { norm2pi($0) }.sorted()
        var dedup: [Double] = []
        for a in normd where dedup.isEmpty || abs(a - dedup.last!) > 1e-6 { dedup.append(a) }
        if dedup.count >= 2, (dedup[0] + 2 * .pi - dedup.last!) < 1e-6 { dedup.removeLast() }
        return dedup
    }

    /// Clamped projection of `p` onto segment a→b: (t in [0,1], distance).
    private func projectT(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (Double, Double) {
        let rx = Double(b.x - a.x), ry = Double(b.y - a.y)
        let rr = rx*rx + ry*ry
        if rr < 1e-12 { return (0.0, hypot(Double(p.x - a.x), Double(p.y - a.y))) }
        let t = max(0.0, min(1.0, (Double(p.x - a.x)*rx + Double(p.y - a.y)*ry) / rr))
        return (t, hypot(Double(p.x) - (Double(a.x) + rx*t), Double(p.y) - (Double(a.y) + ry*t)))
    }

    /// Sorted interior crossing params of edge a→b against every other entity.
    private func edgeCutParams(_ a: CGPoint, _ b: CGPoint, exclude: String) -> [Double] {
        let rx = Double(b.x - a.x), ry = Double(b.y - a.y)
        var cuts: [Double] = []
        for ent in state.entities where ent.handle != exclude {
            for seg in trimEdges(of: ent) {
                if let t = segIntersectParam(a, b, seg.0, seg.1) { cuts.append(t) }
            }
            let tt = ent.type.uppercased()
            if tt == "CIRCLE", let c = ent.center, let r = ent.radius, c.count >= 2 {
                cuts.append(contentsOf: circleIntersectParams(a, b, cx: c[0], cy: c[1], r: r))
            } else if tt == "ARC", let c = ent.center, let r = ent.radius, c.count >= 2,
                      let sa = ent.start_angle, let ea = ent.end_angle {
                for t in circleIntersectParams(a, b, cx: c[0], cy: c[1], r: r) {
                    let ix = Double(a.x) + rx*t, iy = Double(a.y) + ry*t
                    if angleInArc(atan2(iy - c[1], ix - c[0]), sa, ea) { cuts.append(t) }
                }
            }
        }
        return cuts.filter { $0 > 1e-6 && $0 < 1 - 1e-6 }.sorted()
    }

    /// Model-space polyline tracing the whole portion a trim click removes from a
    /// pen curve — mirrors the Python whole-curve trim (curves-as-curves).
    private func wholeCurveKillPath(ent: DXFEntity, clickModel: CGPoint) -> [CGPoint]? {
        let pts = ent.editableVertices.map { CGPoint(x: $0[0], y: $0[1]) }
        guard pts.count >= 2 else { return nil }
        let n = pts.count
        let closed = (ent.closed ?? false) && n > 2
        var edges: [(CGPoint, CGPoint)] = []
        for i in 0..<(n - 1) { edges.append((pts[i], pts[i + 1])) }
        if closed { edges.append((pts[n - 1], pts[0])) }
        let E = edges.count
        guard E > 0 else { return nil }

        var ci = 0, ct = 0.0, bestd = Double.greatestFiniteMagnitude
        for (i, e) in edges.enumerated() {
            let (t, d) = projectT(clickModel, e.0, e.1)
            if d < bestd { bestd = d; ci = i; ct = t }
        }
        let clickPos = Double(ci) + ct

        var cuts: [Double] = []
        for (i, e) in edges.enumerated() {
            for t in edgeCutParams(e.0, e.1, exclude: ent.handle) { cuts.append(Double(i) + t) }
        }
        cuts = Array(Set(cuts.map { ($0 * 1e9).rounded() / 1e9 })).sorted()

        func at(_ pos: Double) -> CGPoint {
            if !closed && pos >= Double(E) { return pts[n - 1] }
            var e = Int(floor(pos))
            e = closed ? ((e % E) + E) % E : max(0, min(E - 1, e))
            let t = pos - floor(pos)
            let (a, b) = edges[e]
            return CGPoint(x: Double(a.x) + (Double(b.x) - Double(a.x)) * t,
                           y: Double(a.y) + (Double(b.y) - Double(a.y)) * t)
        }
        func subpath(_ lo: Double, _ hi: Double) -> [CGPoint] {
            var out = [at(lo)]
            var k = Int(floor(lo)) + 1
            while Double(k) < hi - 1e-9 {
                if Double(k) > lo + 1e-9 { out.append(pts[((k % n) + n) % n]) }
                k += 1
            }
            out.append(at(hi))
            return out
        }

        if cuts.isEmpty { return closed ? pts + [pts[0]] : pts }   // whole curve removed
        if closed {
            let below = cuts.filter { $0 <= clickPos }
            let above = cuts.filter { $0 > clickPos }
            let lower = below.last ?? (cuts.last! - Double(E))
            let upper = above.first ?? (cuts.first! + Double(E))
            return subpath(lower, upper)
        }
        let below = cuts.filter { $0 <= clickPos }
        let above = cuts.filter { $0 >= clickPos }
        let lower = below.last ?? 0.0
        let upper = above.first ?? Double(E)
        return subpath(lower, upper)
    }

    /// Model-space polyline tracing the span a trim click would remove from a
    /// circle or arc (for the red hover highlight).
    private func circleKillPath(ent: DXFEntity, clickModel: CGPoint) -> [CGPoint]? {
        guard let c = ent.center, let R = ent.radius, c.count >= 2 else { return nil }
        let cx = c[0], cy = c[1]
        let angs = circleCrossingAngles(cx: cx, cy: cy, R: R, exclude: ent.handle)
        let click = norm2pi(atan2(Double(clickModel.y) - cy, Double(clickModel.x) - cx))
        func pt(_ a: Double) -> CGPoint { CGPoint(x: cx + R*cos(a), y: cy + R*sin(a)) }
        func tess(_ a0: Double, _ a1: Double) -> [CGPoint] {
            var hi = a1; if hi < a0 { hi += 2 * .pi }
            let span = hi - a0
            let steps = max(2, Int((span / (.pi/24)).rounded(.up)))
            return (0...steps).map { pt(a0 + span * Double($0) / Double(steps)) }
        }
        if ent.type.uppercased() == "CIRCLE" {
            if angs.isEmpty { return tess(0, 2 * .pi - 1e-9) }   // whole circle removed
            let k = angs.count
            var lo = angs[k - 1], hi = angs[0]
            for i in 0..<k {
                let a0 = angs[i], a1 = angs[(i + 1) % k]
                let span = norm2pi(a1 - a0)
                if norm2pi(click - a0) <= span + 1e-12 { lo = a0; hi = a1; break }
            }
            return tess(lo, hi)
        }
        // ARC
        guard let saD = ent.start_angle, let eaD = ent.end_angle else { return nil }
        let s = norm2pi(saD * .pi / 180)
        var sweep = norm2pi(eaD * .pi / 180 - saD * .pi / 180)
        if sweep < 1e-9 { sweep = 2 * .pi }
        let cuts = angs.map { norm2pi($0 - s) }.filter { $0 > 1e-9 && $0 < sweep - 1e-9 }.sorted()
        let clickOff = min(max(norm2pi(click - s), 0), sweep)
        let bounds = [0.0] + cuts + [sweep]
        var lo = 0.0, hi = sweep
        for i in 0..<(bounds.count - 1) where bounds[i] <= clickOff && clickOff <= bounds[i + 1] {
            lo = bounds[i]; hi = bounds[i + 1]; break
        }
        return tess(s + lo, s + hi)
    }

    /// Corner picking for the Fillet/Chamfer tools — toggles the nearest corner
    /// (parametrically, so it stays editable/convertible) (MAS-62). When the click
    /// misses every polyline corner, fall back to joining two separate lines that
    /// meet near the click into one filletable corner — so the tools work on the
    /// junction of two lines, imported geometry, etc.
    private func pickFilletCorner(at point: CGPoint, size: CGSize, modelBounds: CGRect) {
        var bestHandle: String? = nil
        var bestIndex = -1
        var bestDist: CGFloat = 10.0
        for ent in state.entities {
            for c in cornerHandles(for: ent) {
                let s = toScreen(dx: c.pt[0], dy: c.pt[1], size: size, bounds: modelBounds)
                let d = hypot(point.x - s.x, point.y - s.y)
                if d < bestDist { bestDist = d; bestHandle = ent.handle; bestIndex = c.index }
            }
        }
        if let h = bestHandle, bestIndex >= 0 {
            state.toggleCorner(handle: h, index: bestIndex)
            return
        }
        // No existing polyline corner under the cursor: try to join two lines.
        let modelPt = toModel(point: point, size: size, bounds: modelBounds)
        state.joinLinesAndFillet(at: modelPt)
    }

    /// Flattened model-space outline of a parametric corner shape, mirroring the
    /// Python `op_apply_corners` blend (G1 fillet arcs tessellated, chamfers as a
    /// straight cut). Used for the lag-free live preview while dragging the radius
    /// arrow (fillet perf).
    private func parametricOutlinePoints(_ model: ParametricCornerShape) -> [CGPoint] {
        let base = model.base
        let n = base.count
        guard n >= 2 else { return [] }
        let closed = model.closed
        let cmap = Dictionary(model.corners.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })

        func neighbors(_ i: Int) -> (P: [Double], N: [Double])? {
            if closed && n > 2 { return (base[(i - 1 + n) % n], base[(i + 1) % n]) }
            if i > 0 && i < n - 1 { return (base[i - 1], base[i + 1]) }
            return nil
        }

        // Desired tangent each corner wants, then the shared-edge resolution that
        // mirrors `op_apply_corners`: the larger blend keeps its full reach (up to
        // the mathematical limit), the smaller stops where it meets it.
        var dt = [Double](repeating: 0, count: n)
        var kinds = [String](repeating: "fillet", count: n)
        for i in 0..<n {
            guard let mod = cmap[i], mod.value > 1e-9, let nb = neighbors(i) else { continue }
            let V = base[i]
            let u1 = normalize(dx: nb.P[0] - V[0], dy: nb.P[1] - V[1])
            let u2 = normalize(dx: nb.N[0] - V[0], dy: nb.N[1] - V[1])
            let dot = max(-1.0, min(1.0, u1.0 * u2.0 + u1.1 * u2.1))
            let phi = acos(dot)
            if phi < 1e-3 || phi > .pi - 1e-3 { continue }
            let half = phi / 2.0
            let l1 = hypot(nb.P[0] - V[0], nb.P[1] - V[1])
            let l2 = hypot(nb.N[0] - V[0], nb.N[1] - V[1])
            let raw = mod.kind == "chamfer" ? mod.value : mod.value / tan(half)
            dt[i] = max(0, min(raw, l1, l2))
            kinds[i] = mod.kind
        }
        let edges: [(Int, Int)] = (closed && n > 2) ? (0..<n).map { ($0, ($0 + 1) % n) }
                                                    : (0..<max(0, n - 1)).map { ($0, $0 + 1) }
        for _ in 0..<2 {
            for (a, b) in edges {
                let L = hypot(base[a][0] - base[b][0], base[a][1] - base[b][1])
                if dt[a] + dt[b] > L + 1e-9 {
                    if dt[a] >= dt[b] { dt[b] = max(0, L - dt[a]) }
                    else { dt[a] = max(0, L - dt[b]) }
                }
            }
        }

        var out: [CGPoint] = []
        for i in 0..<n {
            if dt[i] > 1e-9, let nb = neighbors(i),
               let pts = cornerBlendPoints(P: nb.P, V: base[i], N: nb.N, kind: kinds[i], t: dt[i]) {
                out.append(contentsOf: pts)
            } else if base[i].count >= 2 {
                out.append(CGPoint(x: base[i][0], y: base[i][1]))
            }
        }
        return out
    }

    /// One corner's blend as flattened points given the final tangent setback `t`
    /// (fillet → arc samples, chamfer → two tangent points). Mirrors Python
    /// `_corner_blend`.
    private func cornerBlendPoints(P: [Double], V: [Double], N: [Double], kind: String, t: Double) -> [CGPoint]? {
        guard P.count >= 2, V.count >= 2, N.count >= 2, t > 1e-9 else { return nil }
        let u1 = normalize(dx: P[0] - V[0], dy: P[1] - V[1])
        let u2 = normalize(dx: N[0] - V[0], dy: N[1] - V[1])
        let dot = max(-1.0, min(1.0, u1.0 * u2.0 + u1.1 * u2.1))
        let phi = acos(dot)
        if phi < 1e-3 || phi > .pi - 1e-3 { return nil }
        let half = phi / 2.0
        if kind == "chamfer" {
            return [CGPoint(x: V[0] + u1.0 * t, y: V[1] + u1.1 * t),
                    CGPoint(x: V[0] + u2.0 * t, y: V[1] + u2.1 * t)]
        }
        let r = t * tan(half)
        let T1 = CGPoint(x: V[0] + u1.0 * t, y: V[1] + u1.1 * t)
        let bis = normalize(dx: u1.0 + u2.0, dy: u1.1 + u2.1)
        let cen = CGPoint(x: V[0] + bis.0 * (r / sin(half)), y: V[1] + bis.1 * (r / sin(half)))
        let T2 = CGPoint(x: V[0] + u2.0 * t, y: V[1] + u2.1 * t)
        let a1 = atan2(T1.y - cen.y, T1.x - cen.x)
        let a2 = atan2(T2.y - cen.y, T2.x - cen.x)
        var da = a2 - a1
        while da <= -.pi { da += 2 * .pi }
        while da > .pi { da -= 2 * .pi }
        let seg = 10
        return (0...seg).map { k in
            let ang = a1 + da * Double(k) / Double(seg)
            return CGPoint(x: cen.x + r * cos(ang), y: cen.y + r * sin(ang))
        }
    }

    /// Round corner handles shown while a corner tool is active; filleted/
    /// chamfered corners are filled, the rest hollow (MAS-62).
    private func drawFilletCornerHandles(_ context: inout GraphicsContext, size: CGSize, modelBounds: CGRect) {
        guard state.currentTool.isCornerTool else { return }
        for ent in state.entities {
            for c in cornerHandles(for: ent) {
                let s = toScreen(dx: c.pt[0], dy: c.pt[1], size: size, bounds: modelBounds)
                let r: CGFloat = c.hasMod ? 5.0 : 3.5
                var p = SwiftUI.Path()
                p.addEllipse(in: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2))
                if c.hasMod {
                    context.fill(p, with: .color(Color.accent))
                    context.stroke(p, with: .color(.white), lineWidth: 1.5)
                } else {
                    context.fill(p, with: .color(Color.bg_base))
                    context.stroke(p, with: .color(Color.accent.opacity(0.7)), lineWidth: 1.0)
                }
            }
        }
    }

    /// Right-click context menu (MAS-62). Offers Expand on a parametric
    /// rectangle (converting it to a freely-editable polyline) plus Delete.
    @ViewBuilder
    private func canvasContextMenu(at pos: CGPoint) -> some View {
        // The right-click menu over a selection (MAS-77). Other features append
        // their own conditional entries here (mirror break-link MAS-55, reload
        // from disk MAS-76, convert lines MAS-58).
        let hasSelection = !state.selectedHandles.isEmpty
        let hasMirrorLink = state.selectedHandles.contains { state.mirrorLink(for: $0) != nil }
        let hasImported = state.selectedHandles.contains { state.importedSource(for: $0) != nil }
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { contextMenuScreenPos = nil }
            VStack(alignment: .leading, spacing: 0) {
                if hasSelection {
                    contextMenuButton("Duplicate", systemImage: "plus.square.on.square") {
                        state.duplicateSelectedEntities(); contextMenuScreenPos = nil
                    }
                    contextMenuButton("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        state.reflectSelectedEntities(axis: "horizontal"); contextMenuScreenPos = nil
                    }
                    contextMenuButton("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                        state.reflectSelectedEntities(axis: "vertical"); contextMenuScreenPos = nil
                    }
                    if state.selectedHandles.contains(where: { state.isRectangleHandle($0) }) {
                        contextMenuButton("Expand", systemImage: "arrow.up.left.and.arrow.down.right") {
                            state.expandSelectedRectangle(); contextMenuScreenPos = nil
                        }
                    }

                    // Convert Lines submenu shortcut (MAS-58): only when the
                    // selection contains straight segments.
                    if state.selectionHasConvertibleLines {
                        contextMenuDivider()
                        contextMenuButton("Convert to Dashed", systemImage: "line.diagonal") {
                            state.quickConvertSelectedLines(to: "dashed"); contextMenuScreenPos = nil
                        }
                    }

                    // Boolean combine (MAS-144): only when 2+ watertight closed
                    // paths are selected.
                    if state.selectionCanBoolean {
                        contextMenuDivider()
                        contextMenuButton("Union", systemImage: "plus.circle") {
                            state.booleanCombineSelection("union"); contextMenuScreenPos = nil
                        }
                        contextMenuButton("Subtract", systemImage: "minus.circle") {
                            state.booleanCombineSelection("subtract"); contextMenuScreenPos = nil
                        }
                        contextMenuButton("Intersect", systemImage: "circle.lefthalf.filled") {
                            state.booleanCombineSelection("intersect"); contextMenuScreenPos = nil
                        }
                    }

                    // Explode compound path into individual loops (MAS-145) —
                    // the counterpart to Union, sits beside Combine.
                    if state.selectionHasClosedPolyline {
                        contextMenuDivider()
                        contextMenuButton("Explode", systemImage: "square.split.diagonal") {
                            state.explodeSelectedCompound(); contextMenuScreenPos = nil
                        }
                    }

                    // Stroke ↔ Fill conversion (MAS-146).
                    if state.selectionHasFillableStroke || state.selectionHasFilledRegion {
                        contextMenuDivider()
                        if state.selectionHasFillableStroke {
                            contextMenuButton("Convert to Fill", systemImage: "square.fill") {
                                state.convertSelectionToFill(); contextMenuScreenPos = nil
                            }
                        }
                        if state.selectionHasFilledRegion {
                            contextMenuButton("Convert to Stroke", systemImage: "square") {
                                state.convertSelectionToStroke(); contextMenuScreenPos = nil
                            }
                        }
                    }

                    if hasMirrorLink {
                        contextMenuDivider()
                        contextMenuButton("Break Mirror Link", systemImage: "link.badge.plus") {
                            state.breakMirrorLinkForSelection(); contextMenuScreenPos = nil
                        }
                    }
                    if hasImported {
                        contextMenuButton("Reload from Disk", systemImage: "arrow.clockwise") {
                            state.reloadSelectedImportFromDisk(); contextMenuScreenPos = nil
                        }
                    }

                    contextMenuDivider()
                    contextMenuButton("Delete", systemImage: "trash") {
                        state.deleteSelectedEntities(); contextMenuScreenPos = nil
                    }
                }
            }
            .frame(width: 190, alignment: .leading)
            .background(Color.bg_panel)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.border_strong, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .offset(x: min(pos.x, 2000), y: pos.y)
        }
    }

    private func contextMenuDivider() -> some View {
        Divider().background(Color.border_subtle).padding(.vertical, 2)
    }

    /// Draggable arrow at the last-selected corner that sets only that corner's
    /// fillet/chamfer value (MAS-91). Points inward along the corner bisector;
    /// dragging inward grows the value, outward shrinks it.
    @ViewBuilder
    private func filletArrowOverlay(size: CGSize, bounds: CGRect) -> some View {
        if let geo = filletArrowGeometry(size: size, bounds: bounds) {
            ZStack {
                // Stem from the corner to the handle.
                Path { p in
                    p.move(to: geo.corner)
                    p.addLine(to: geo.handle)
                }
                .stroke(Color.status_warn, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .allowsHitTesting(false)

                // Inward-pointing arrowhead (visual only).
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color.status_warn)
                    .rotationEffect(.radians(atan2(geo.inScreen.y, geo.inScreen.x) + .pi / 2))
                    .position(geo.handle)
                    .allowsHitTesting(false)

                // The grab target: a generous, clearly-grabbable circle. A 28pt
                // hit area + contentShape make it easy to catch, and a
                // high-priority gesture wins over the canvas drag so grabbing it
                // never deselects the active corner (MAS-91).
                Circle()
                    .fill(Color.status_warn)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .frame(width: 28, height: 28)        // larger hit area
                    .contentShape(Circle())
                    .position(geo.handle)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                            .onChanged { val in
                                isDraggingFilletArrow = true
                                let vx = val.location.x - geo.corner.x
                                let vy = val.location.y - geo.corner.y
                                let proj = vx * geo.inScreen.x + vy * geo.inScreen.y
                                let newRadius = max(0, Double(proj) / Double(state.canvasScale))
                                state.filletToolRadius = newRadius
                                // Live, local-only update — committed once on release.
                                state.setActiveCornerValueLocal(newRadius)
                            }
                            .onEnded { _ in
                                isDraggingFilletArrow = false
                                state.commitActiveCornerValue()
                            }
                    )
            }
        }
    }

    /// Plain (non-ViewBuilder) geometry for the active corner's fillet arrow.
    private func filletArrowGeometry(size: CGSize, bounds: CGRect)
        -> (corner: CGPoint, handle: CGPoint, inScreen: CGPoint)? {
        guard let handle = state.filletSelectedHandle,
              let idx = state.activeCornerIndex,
              let model = state.parametricShapes[handle],
              idx >= 0, idx < model.base.count,
              let corner = model.corners.first(where: { $0.index == idx }) else { return nil }
        let n = model.base.count
        let cur = model.base[idx]
        let prev = model.base[(idx - 1 + n) % n]
        let nxt = model.base[(idx + 1) % n]
        let d1 = normalize(dx: prev[0] - cur[0], dy: prev[1] - cur[1])
        let d2 = normalize(dx: nxt[0] - cur[0], dy: nxt[1] - cur[1])
        var bx = d1.0 + d2.0, by = d1.1 + d2.1
        let bl = hypot(bx, by)
        guard bl > 1e-6 else { return nil }
        bx /= bl; by /= bl
        let cornerScreen = toScreen(dx: cur[0], dy: cur[1], size: size, bounds: bounds)
        let inScreen = CGPoint(x: bx, y: -by)   // y flips screen-side
        let radiusPx = max(18.0, corner.value * Double(state.canvasScale))
        let handlePt = CGPoint(x: cornerScreen.x + inScreen.x * radiusPx,
                               y: cornerScreen.y + inScreen.y * radiusPx)
        return (cornerScreen, handlePt, inScreen)
    }

    private func normalize(dx: Double, dy: Double) -> (Double, Double) {
        let l = hypot(dx, dy)
        return l > 1e-9 ? (dx / l, dy / l) : (0, 0)
    }

    /// Draws the in-progress mirror axis: the committed points and the line that
    /// extends across the canvas through them (MAS-55).
    @ViewBuilder
    private func mirrorAxisOverlay(size: CGSize, bounds: CGRect) -> some View {
        let start = state.mirrorAxisStart
        let end = state.mirrorAxisEnd
        return ZStack {
            if let a = start {
                let pa = toScreen(dx: Double(a.x), dy: Double(a.y), size: size, bounds: bounds)
                if let b = end {
                    let pb = toScreen(dx: Double(b.x), dy: Double(b.y), size: size, bounds: bounds)
                    // Extend the segment well past both endpoints to read as an axis.
                    let dx = pb.x - pa.x, dy = pb.y - pa.y
                    let len = max(1, hypot(dx, dy))
                    let ux = dx / len, uy = dy / len
                    let ext: CGFloat = 4000
                    Path { p in
                        p.move(to: CGPoint(x: pa.x - ux * ext, y: pa.y - uy * ext))
                        p.addLine(to: CGPoint(x: pb.x + ux * ext, y: pb.y + uy * ext))
                    }
                    .stroke(Color.accent, style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))

                    // Dynamic ghost of the mirrored geometry (MAS-119): reflect the
                    // selection across the axis using a Canvas so any entity type
                    // previews faithfully, the moment a valid axis exists.
                    Canvas { ctx, _ in
                        let selected = state.entities.filter { state.selectedHandles.contains($0.handle) }
                        let theta = atan2(Double(pb.y - pa.y), Double(pb.x - pa.x))
                        ctx.translateBy(x: pa.x, y: pa.y)
                        ctx.rotate(by: Angle(radians: theta))
                        ctx.scaleBy(x: 1, y: -1)               // reflect across the axis
                        ctx.rotate(by: Angle(radians: -theta))
                        ctx.translateBy(x: -pa.x, y: -pa.y)
                        let ghost = Color.accent.opacity(0.5)
                        for ent in selected {
                            drawEntity(ent, baseColor: ghost, strokeColor: ghost, strokeWidth: 1.0,
                                       size: size, modelBounds: bounds, context: &ctx)
                        }
                    }
                    .allowsHitTesting(false)

                    Circle().fill(Color.accent).frame(width: 7, height: 7).position(pb)
                }
                Circle().fill(Color.accent).frame(width: 7, height: 7).position(pa)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func contextMenuButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        ContextMenuButtonRow(title: title, systemImage: systemImage, action: action)
    }

    /// A single row of the canvas right-click menu. Highlights on hover so the
    /// user can see what a click will select before committing.
    private struct ContextMenuButtonRow: View {
        let title: String
        let systemImage: String
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage).frame(width: 16)
                    Text(title)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .foregroundColor(isHovering ? Color.accent : Color.text_primary)
                .font(PlasticityFont.body)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovering ? Color.accent.opacity(0.16) : Color.clear)
                )
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { isHovering = $0 }
        }
    }

    private func handleDragChanged(val: DragGesture.Value, size: CGSize, modelBounds: CGRect) {
        if let activeL = state.activeLayer, activeL.isReferenceImageLayer, state.isEditingRefImageTransform {
            handleRefImageDragChanged(val: val, layer: activeL, size: size, modelBounds: modelBounds)
            return
        }
        
        // Trim tool (MAS-98): click — or drag across — to cut whatever edge the
        // cursor passes over at its crossings, removing only the sub-segment under
        // the cursor. Runs on every move so a held drag trims each crossed piece;
        // `isProcessing` serializes the worker so trims don't stack.
        if state.currentTool == .trim {
            if !isDragging { isDragging = true }
            let modelPt = toModel(point: val.location, size: size, bounds: modelBounds)
            if !state.isProcessing,
               let target = trimTargetUnderCursor(modelPt: modelPt, size: size, modelBounds: modelBounds) {
                state.trimSegment(handle: target.handle, segIndex: target.segIndex, at: modelPt)
            }
            return
        }

        if !isDragging {
            isDragging = true

            let point = val.startLocation

            // Fillet/Chamfer tools: a click toggles the nearest corner
            // (no marquee, no translate) — applies live & parametrically (MAS-62).
            if state.currentTool.isCornerTool {
                pickFilletCorner(at: point, size: size, modelBounds: modelBounds)
                return
            }

            // Pen tool (MAS-94): each press places an anchor; dragging from it
            // extrudes a symmetric bezier handle (smooth point). Pressing on the
            // first anchor (with ≥2 placed) closes the path on release.
            if state.currentTool == .pen {
                let option = NSEvent.modifierFlags.contains(.option)
                
                // Find if we are near any existing anchor point (within 12px snap tolerance).
                var nearPointIdx: Int? = nil
                for (i, a) in penAnchors.enumerated() {
                    let s = toScreen(dx: a.point.x, dy: a.point.y, size: size, bounds: modelBounds)
                    if hypot(point.x - s.x, point.y - s.y) <= 12.0 {
                        nearPointIdx = i
                        break
                    }
                }
                
                if option {
                    if let idx = nearPointIdx {
                        if idx < penAnchors.count {
                            penAnchors.remove(at: idx)
                        }
                    }
                    penDraggingHandle = false
                    penDraggingHandleIdx = nil
                    return
                }
                
                if let idx = nearPointIdx {
                    // Clicking near an existing anchor
                    if editingPenHandle != nil {
                        if let hit = penHitTest(screen: point, size: size, modelBounds: modelBounds) {
                            switch hit.kind {
                            case "anchor": penEditDragAnchor = hit.idx
                            case "handleOut": penEditDragHandle = (hit.idx, true)
                            case "handleIn": penEditDragHandle = (hit.idx, false)
                            default: break
                            }
                            penDraggingHandle = false
                            return
                        }
                    } else {
                        // Creation mode: click near the first anchor closes/completes the path.
                        let isClosedEdit = (editingPenHandle != nil && penEditingClosed)
                        if penAnchors.count >= 2 && !isClosedEdit && idx == 0 {
                            penClosePending = true
                            penDraggingHandle = false
                            return
                        }
                    }
                    // Clicking other anchors in creation mode does nothing.
                    return
                } else {
                    // Not near any existing anchor. Check if near the line (path).
                    if let nearest = findNearestPointOnPenPath(screenPt: point, size: size, modelBounds: modelBounds),
                       nearest.screenDist <= 12.0 {
                        let insertIdx = nearest.segmentIdx + 1
                        penAnchors.insert(PenAnchor(point: nearest.modelPt), at: insertIdx)
                        penDraggingHandle = true
                        penDraggingHandleIdx = insertIdx
                        self.mouseLocation = point
                        self.hoverCoords = nearest.modelPt
                        return
                    }
                    
                    // Not near the line or any anchor. Standard behavior: append.
                    let isClosedEdit = (editingPenHandle != nil && penEditingClosed)
                    if isClosedEdit { return }
                    
                    let modelPt = snappedModelPoint(forScreen: point, ref: penAnchors.last?.point, size: size, bounds: modelBounds)
                    penAnchors.append(PenAnchor(point: modelPt))
                    penDraggingHandle = true
                    penDraggingHandleIdx = penAnchors.count - 1
                    self.mouseLocation = point
                    self.hoverCoords = modelPt
                    return
                }
            }

            // Move tool point-to-point (MAS-80): when armed, the next two clicks
            // define the from→to translation. Otherwise the move tool selects.
            if state.currentTool == .move {
                if state.moveP2PActive {
                    // Snap each pick to exact geometry (endpoint/midpoint/center) so
                    // the from→to translation is precise, not cursor-approximate —
                    // point-to-point must be exact (MAS-127). Falls back to the raw
                    // model point only when nothing snappable is nearby.
                    let modelPt = getSnappedPoint(for: point, size: size, bounds: modelBounds)?.snappedModelPt
                        ?? toModel(point: point, size: size, bounds: modelBounds)
                    state.moveP2PClick(modelPt)
                    return
                }
                // fall through to normal select behavior below.
            }

            // Mirror tool (MAS-55): pick shapes until a selection exists, then the
            // next clicks define the two axis points. Shift always adds to the
            // selection so you can keep choosing shapes.
            if state.currentTool == .mirror {
                let modelPt = toModel(point: point, size: size, bounds: modelBounds)
                let shift = NSEvent.modifierFlags.contains(.shift)
                if state.mirrorLineMode {
                    // Mirror Line mode (MAS-119): pick an existing straight line as
                    // the axis; otherwise fall back to two-point axis placement.
                    if let nearest = findNearestEntity(modelPt: modelPt, maxDistanceScreen: 16.0, size: size, bounds: modelBounds),
                       nearest.type == "LINE", let s = nearest.start, let e = nearest.end,
                       !state.selectedHandles.contains(nearest.handle) {
                        state.setMirrorAxisFromLine(start: CGPoint(x: s[0], y: s[1]), end: CGPoint(x: e[0], y: e[1]))
                    } else {
                        state.mirrorAxisClick(modelPt)
                    }
                } else {
                    // Objects mode (default): click to select/toggle shapes to mirror.
                    if let nearest = findNearestEntity(modelPt: modelPt, maxDistanceScreen: 16.0, size: size, bounds: modelBounds) {
                        if shift {
                            if state.selectedHandles.contains(nearest.handle) { state.selectedHandles.remove(nearest.handle) }
                            else { state.selectedHandles.insert(nearest.handle) }
                        } else {
                            state.selectedHandles = [nearest.handle]
                        }
                    } else if !shift {
                        state.selectedHandles.removeAll()
                    }
                }
                return
            }

            // Endpoint dragging is the LOWEST-priority interaction (MAS-78): you
            // must click the dot *precisely* (≈ its 4px radius, not a fat 16px
            // halo), and only with the Select tool. With the measure/sketch
            // tools a click at an endpoint starts a new line snapped to it
            // instead of hijacking the existing endpoint. Auto-dimensions belong
            // to their shape and are never draggable (MAS-61).
            let startScreenTolerance: CGFloat = 6.0
            var foundEndpoint = false
            var foundVertex = false

            // 0. Free vertex editing (MAS-62): clicking precisely on a vertex of a
            //    selected line/polyline grabs it. A rectangle still captures the
            //    grab (so it doesn't translate) but won't deform — it stays a
            //    rectangle until right-click → Expand.
            if state.currentTool == .select {
                vertexSearch: for handle in state.selectedHandles {
                    guard let ent = state.entities.first(where: { $0.handle == handle }) else { continue }
                    for (i, v) in ent.editableVertices.enumerated() where v.count >= 2 {
                        let vScreen = toScreen(dx: v[0], dy: v[1], size: size, bounds: modelBounds)
                        if hypot(point.x - vScreen.x, point.y - vScreen.y) < 7.0 {
                            editingVertexHandle = handle
                            editingVertexIndex = i
                            editingVertexIsRect = state.isRectangleHandle(handle)
                            foundVertex = true
                            break vertexSearch
                        }
                    }
                }
            }

            // 1. Check if clicking precisely on a measurement endpoint to drag it.
            if state.currentTool == .select && !foundVertex {
                for measure in state.measurements {
                    if measure.isAutoDimension { continue }
                    let startScreen = toScreen(dx: measure.start.x, dy: measure.start.y, size: size, bounds: modelBounds)
                    let endScreen = toScreen(dx: measure.end.x, dy: measure.end.y, size: size, bounds: modelBounds)

                    if hypot(point.x - startScreen.x, point.y - startScreen.y) < startScreenTolerance {
                        state.saveToHistory()
                        editingMeasureId = measure.id
                        editingIsStart = true
                        foundEndpoint = true
                        break
                    } else if hypot(point.x - endScreen.x, point.y - endScreen.y) < startScreenTolerance {
                        state.saveToHistory()
                        editingMeasureId = measure.id
                        editingIsStart = false
                        foundEndpoint = true
                        break
                    }
                }
            }
            
            // 2. Check if clicking on/near a selected entity to drag-translate it
            var clickedOnSelected = false
            let hasNoActiveHandles = !foundEndpoint && !foundVertex
            let isSelectTool = state.currentTool == .select
            let hasSelectedHandles = !state.selectedHandles.isEmpty
            if hasNoActiveHandles && isSelectTool && hasSelectedHandles {
                let clickedModelPt = toModel(point: point, size: size, bounds: modelBounds)
                if let nearest = findNearestEntity(modelPt: clickedModelPt, maxDistanceScreen: 16.0, size: size, bounds: modelBounds),
                   state.selectedHandles.contains(nearest.handle) {
                    clickedOnSelected = true
                    isDraggingSelection = true
                    dragStartModelPt = clickedModelPt
                }
            }
            
            // 3. Default drag mode initialization
            let shouldStartDefaultDrag = hasNoActiveHandles && (!clickedOnSelected)
            if shouldStartDefaultDrag {
                editingMeasureId = nil
                isDraggingFillet = false
                isDraggingOffset = false
                isDraggingSelection = false
                
                if state.currentTool == .pan || NSEvent.modifierFlags.contains(.option) {
                    dragStartOffset = state.canvasOffset
                } else if state.currentTool == .sketchLine || state.currentTool == .sketchCircle || state.currentTool == .sketchRectangle || state.currentTool == .sketchText || state.currentTool == .sketchPolygon {
                    if sketchStartPoint != nil {
                        // A start already exists → this gesture is the second click
                        // (or a chained line segment); it commits rather than re-arming.
                        sketchAwaitingSecondClick = false
                    } else {
                        // First click: set the start point and wait for the second.
                        let startPt = val.startLocation
                        if state.snapActive, let snap = getSnappedPoint(for: startPt, size: size, bounds: modelBounds) {
                            sketchStartPoint = snap.snappedModelPt
                        } else {
                            sketchStartPoint = toModel(point: startPt, size: size, bounds: modelBounds)
                        }
                        sketchAwaitingSecondClick = true
                    }
                } else if state.currentTool != .measure && state.currentTool != .offset {
                    // Offset never marquee-selects: you pick the profile by clicking
                    // (chain-select grabs the whole loop), and a stray canvas drag
                    // must never wipe the active selection out from under the tool.
                    dragSelectionStart = val.startLocation
                }
            }
        }
        
        // Update mouse location and hover coordinates during drag
        self.mouseLocation = val.location
        self.hoverCoords = toModel(point: val.location, size: size, bounds: modelBounds)
        
        // Handle active dragging updates
        if state.currentTool == .pen {
            // Re-editing: drag an existing anchor (moving its handles with it) or
            // reshape a bezier handle (parametric pen lines).
            if let ai = penEditDragAnchor, ai < penAnchors.count {
                var mp = toModel(point: val.location, size: size, bounds: modelBounds)
                if state.snapActive, let snap = getSnappedPoint(for: val.location, size: size, bounds: modelBounds) {
                    mp = snap.snappedModelPt
                }
                let old = penAnchors[ai].point
                let dx = mp.x - old.x, dy = mp.y - old.y
                penAnchors[ai].point = mp
                if let h = penAnchors[ai].handleOut {
                    penAnchors[ai].handleOut = CGPoint(x: h.x + dx, y: h.y + dy)
                }
                return
            }
            if let hd = penEditDragHandle, hd.idx < penAnchors.count {
                let mp = toModel(point: val.location, size: size, bounds: modelBounds)
                let pt = penAnchors[hd.idx].point
                // The incoming handle is the mirror of handleOut, so dragging it
                // sets handleOut to the reflected point (keeps a smooth point).
                penAnchors[hd.idx].handleOut = hd.isOut ? mp : CGPoint(x: 2 * pt.x - mp.x, y: 2 * pt.y - mp.y)
                return
            }
            // Dragging after placing an anchor extrudes its outgoing bezier
            // handle (the incoming handle is the mirror — symmetric smooth point).
            if penDraggingHandle, let dragIdx = penDraggingHandleIdx, dragIdx < penAnchors.count, !penClosePending {
                let dragDist = hypot(val.translation.width, val.translation.height)
                if dragDist > 3.0 {
                    penAnchors[dragIdx].handleOut = toModel(point: val.location, size: size, bounds: modelBounds)
                }
            }
            return
        } else if let vHandle = editingVertexHandle {
            // Rectangles don't deform — they stay rectangular until Expand (MAS-62).
            if !editingVertexIsRect {
                var modelPt = toModel(point: val.location, size: size, bounds: modelBounds)
                if state.snapActive, let snap = getSnappedPoint(for: val.location, size: size, bounds: modelBounds) {
                    modelPt = snap.snappedModelPt
                }
                state.setEntityVertexLocal(handle: vHandle, index: editingVertexIndex, to: modelPt)
            }
        } else if isDraggingSelection {
            gizmoDragOffset = val.translation
        } else if let editId = editingMeasureId {
            let modelPt = toModel(point: val.location, size: size, bounds: modelBounds)
            if let idx = state.measurements.firstIndex(where: { $0.id == editId }) {
                if editingIsStart {
                    state.measurements[idx].start = modelPt
                } else {
                    state.measurements[idx].end = modelPt
                }
                state.measurements[idx].distanceMm = Double(hypot(state.measurements[idx].start.x - state.measurements[idx].end.x, state.measurements[idx].start.y - state.measurements[idx].end.y))
            }
        } else if state.currentTool == .pan || NSEvent.modifierFlags.contains(.option) {
            state.canvasOffset = CGSize(
                width: dragStartOffset.width + val.translation.width,
                height: dragStartOffset.height + val.translation.height
            )
        } else if state.currentTool == .sketchLine || state.currentTool == .sketchCircle || state.currentTool == .sketchRectangle || state.currentTool == .sketchText || state.currentTool == .sketchPolygon {
            // mouseLocation is already updated above
        } else if state.currentTool != .measure && !state.currentTool.isCornerTool {
            dragSelectionEnd = val.location
        }
    }

    // MARK: - Pen tool (MAS-94)

    private func cubicBezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    /// Flattens the pen anchors into a polyline point list: straight segments
    /// where both adjoining handles are absent, sampled cubic beziers otherwise.
    private func penFlattenedPoints(closed: Bool) -> [[Double]] {
        guard penAnchors.count >= 2 else { return [] }
        var pts: [[Double]] = []
        func append(_ p: CGPoint) {
            if let last = pts.last, abs(last[0] - Double(p.x)) < 1e-7, abs(last[1] - Double(p.y)) < 1e-7 { return }
            pts.append([Double(p.x), Double(p.y)])
        }
        let segs = closed ? penAnchors.count : penAnchors.count - 1
        append(penAnchors[0].point)
        for i in 0..<segs {
            let a = penAnchors[i]
            let b = penAnchors[(i + 1) % penAnchors.count]
            if a.handleOut == nil && b.handleIn == nil {
                append(b.point)
            } else {
                let c1 = a.handleOut ?? a.point
                let c2 = b.handleIn ?? b.point
                let steps = 18
                for s in 1...steps {
                    append(cubicBezier(a.point, c1, c2, b.point, CGFloat(s) / CGFloat(steps)))
                }
            }
        }
        // Closed polylines carry the closure implicitly; drop a trailing point
        // that coincides with the start.
        if closed, pts.count > 2, let f = pts.first, let l = pts.last,
           abs(f[0] - l[0]) < 1e-6, abs(f[1] - l[1]) < 1e-6 {
            pts.removeLast()
        }
        return pts
    }

    /// The current pen anchors as a persistable parametric model.
    private func currentPenModel(closed: Bool) -> PenPathModel {
        PenPathModel(anchors: penAnchors.map { a in
            PenPathAnchor(point: [Double(a.point.x), Double(a.point.y)],
                          handleIn: nil,
                          handleOut: a.handleOut.map { [Double($0.x), Double($0.y)] })
        }, closed: closed)
    }

    /// Loads a stored pen model back into the live anchors for editing.
    private func loadPenModel(_ m: PenPathModel) {
        penAnchors = m.anchors.map { pa in
            var a = PenAnchor(point: CGPoint(x: pa.point[0], y: pa.point[1]))
            if let h = pa.handleOut, h.count >= 2 { a.handleOut = CGPoint(x: h[0], y: h[1]) }
            return a
        }
    }

    private func resetPenState() {
        penAnchors = []
        penDraggingHandle = false
        penDraggingHandleIdx = nil
        penClosePending = false
        editingPenHandle = nil
        penEditDragAnchor = nil
        penEditDragHandle = nil
    }

    /// Commits the in-progress pen path. A fresh path is added as a new editable
    /// polyline; a re-edited one (parametric pen lines) updates its own entity in
    /// place. Either way the parametric anchors are stored so it stays editable.
    private func commitPenPath(closed: Bool) {
        let model = currentPenModel(closed: closed)
        let pts = penFlattenedPoints(closed: closed)
        let editHandle = editingPenHandle
        resetPenState()
        guard pts.count >= 2 else {
            if let h = editHandle {
                state.penPaths[h] = nil
                state.deleteEntity(handle: h)
            }
            if state.currentTool == .pen {
                state.currentTool = .select
            }
            return
        }
        if let h = editHandle {
            state.penPaths[h] = model
            state.applyPenEdit(handle: h, points: pts)
        } else {
            Task {
                if let h = await state.addSketchedEntity(type: "path", params: ["points": pts, "closed": closed]) {
                    await MainActor.run { state.penPaths[h] = model }
                }
            }
        }
        if state.currentTool == .pen {
            state.currentTool = .select
        }
    }

    /// Finishes the current pen path: closes if it ends on the first anchor,
    /// otherwise commits an open path. A re-edited path keeps its closed-ness.
    private func finishPenPath() {
        guard penAnchors.count >= 2 else { resetPenState(); return }
        commitPenPath(closed: editingPenHandle != nil ? penEditingClosed : false)
    }

    /// Hit-tests the pen anchors and bezier handles under a screen point, for
    /// re-editing (parametric pen lines). Handles take priority over anchors.
    private func penHitTest(screen p: CGPoint, size: CGSize, modelBounds: CGRect) -> (kind: String, idx: Int)? {
        let r: CGFloat = 8.0
        for (i, a) in penAnchors.enumerated() {
            guard let hOut = a.handleOut else { continue }
            let ho = toScreen(dx: hOut.x, dy: hOut.y, size: size, bounds: modelBounds)
            if hypot(p.x - ho.x, p.y - ho.y) < r { return ("handleOut", i) }
            if let hIn = a.handleIn {
                let hi = toScreen(dx: hIn.x, dy: hIn.y, size: size, bounds: modelBounds)
                if hypot(p.x - hi.x, p.y - hi.y) < r { return ("handleIn", i) }
            }
        }
        for (i, a) in penAnchors.enumerated() {
            let s = toScreen(dx: a.point.x, dy: a.point.y, size: size, bounds: modelBounds)
            if hypot(p.x - s.x, p.y - s.y) < r { return ("anchor", i) }
        }
        return nil
    }

    /// Finds the closest point on the active pen path, returning the segment index
    /// (the index of the start anchor of the segment), the model point on the segment,
    /// and the distance in screen pixels.
    private func findNearestPointOnPenPath(screenPt: CGPoint, size: CGSize, modelBounds: CGRect) -> (segmentIdx: Int, modelPt: CGPoint, screenDist: CGFloat)? {
        guard penAnchors.count >= 2 else { return nil }
        
        let queryModelPt = toModel(point: screenPt, size: size, bounds: modelBounds)
        var bestResult: (segmentIdx: Int, modelPt: CGPoint, screenDist: CGFloat)? = nil
        
        let isClosed = (editingPenHandle != nil && penEditingClosed)
        let segs = isClosed ? penAnchors.count : penAnchors.count - 1
        
        for i in 0..<segs {
            let a = penAnchors[i]
            let b = penAnchors[(i + 1) % penAnchors.count]
            
            var segPts: [CGPoint] = [a.point]
            if a.handleOut == nil && b.handleIn == nil {
                segPts.append(b.point)
            } else {
                let c1 = a.handleOut ?? a.point
                let c2 = b.handleIn ?? b.point
                let steps = 18
                for s in 1...steps {
                    segPts.append(cubicBezier(a.point, c1, c2, b.point, CGFloat(s) / CGFloat(steps)))
                }
            }
            
            for j in 0..<(segPts.count - 1) {
                let p0 = segPts[j]
                let p1 = segPts[j + 1]
                let closestModel = closestPointOnSegment(p: queryModelPt, a: p0, b: p1)
                let closestScreen = toScreen(dx: Double(closestModel.x), dy: Double(closestModel.y), size: size, bounds: modelBounds)
                let dist = hypot(screenPt.x - closestScreen.x, screenPt.y - closestScreen.y)
                
                if let best = bestResult {
                    if dist < best.screenDist {
                        bestResult = (segmentIdx: i, modelPt: closestModel, screenDist: dist)
                    }
                } else {
                    bestResult = (segmentIdx: i, modelPt: closestModel, screenDist: dist)
                }
            }
        }
        
        return bestResult
    }

    /// Creates a line entity from `start`→`end` and focuses its length dimension.
    /// Used by both the second-click commit and the Return shortcut, which
    /// finishes the line at wherever the cursor currently is.
    private func commitSketchLine(start: CGPoint, end: CGPoint, size: CGSize, modelBounds: CGRect) {
        let dist = Double(hypot(start.x - end.x, start.y - end.y))
        Task {
            if let handle = await state.addSketchedEntity(type: "line", params: [
                "start": [Double(start.x), Double(start.y)],
                "end": [Double(end.x), Double(end.y)]
            ]) {
                await MainActor.run {
                    let lenMeasure = MeasurementLine(
                        start: start, end: end, distanceMm: dist,
                        isAutoDimension: true, entityHandle: handle, dimensionType: "length"
                    )
                    state.measurements.append(lenMeasure)
                    editingDimension = lenMeasure
                    editingDimensionText = String(format: "%.2f", lenMeasure.distanceMm)
                    let s = toScreen(dx: lenMeasure.start.x, dy: lenMeasure.start.y, size: size, bounds: modelBounds)
                    let e = toScreen(dx: lenMeasure.end.x, dy: lenMeasure.end.y, size: size, bounds: modelBounds)
                    editingDimensionScreenPos = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
                    isDimensionEditorFocused = true
                }
            }
        }
    }

    private func handleDragEnded(val: DragGesture.Value, size: CGSize, modelBounds: CGRect) {
        if let activeL = state.activeLayer, activeL.isReferenceImageLayer, state.isEditingRefImageTransform {
            handleRefImageDragEnded(val: val, layer: activeL, size: size, modelBounds: modelBounds)
            return
        }
        
        isDragging = false

        // Pen tool (MAS-94): a press on the first anchor closes & commits the
        // path; otherwise the anchor just placed stays and the path continues.
        if state.currentTool == .pen {
            penDraggingHandle = false
            penDraggingHandleIdx = nil
            // Releasing an edit drag keeps the path live (commit on finish).
            if penEditDragAnchor != nil || penEditDragHandle != nil {
                penEditDragAnchor = nil
                penEditDragHandle = nil
                return
            }
            if penClosePending {
                penClosePending = false
                commitPenPath(closed: true)
            }
            return
        }

        if let vHandle = editingVertexHandle {
            // Persist the moved vertex once on release (rectangles never changed).
            if !editingVertexIsRect {
                state.commitEntityVertices(handle: vHandle)
            }
            editingVertexHandle = nil
            return
        }
        if editingMeasureId != nil {
            editingMeasureId = nil
            return
        }
        if isDraggingSelection {
            isDraggingSelection = false
            gizmoDragOffset = .zero
            // Only an actual drag moves the selection. A click (no real movement)
            // falls through to the click-select path below, so clicking a selected
            // shape just re-selects it instead of pushing a zero-length move onto
            // the undo stack (MAS-116).
            if hypot(val.translation.width, val.translation.height) >= 4.0 {
                let startModel = toModel(point: val.startLocation, size: size, bounds: modelBounds)
                let currentModel = toModel(point: val.location, size: size, bounds: modelBounds)
                state.translateSelected(dx: currentModel.x - startModel.x, dy: currentModel.y - startModel.y)
                return
            }
        }
        
        if state.currentTool == .sketchLine || state.currentTool == .sketchCircle || state.currentTool == .sketchRectangle || state.currentTool == .sketchText || state.currentTool == .sketchPolygon {
            if let start = sketchStartPoint {
                let snapped = snappedMouseLocation(size: size, bounds: modelBounds)
                let end = snapped.point
                let dragDist = hypot(val.translation.width, val.translation.height)
                let isClick = dragDist < 5.0

                // Click-to-click: the first click only sets the start (armed in
                // handleDragChanged); wait here for the second click to commit. A
                // real drag still commits in one gesture.
                if isClick && sketchAwaitingSecondClick {
                    sketchAwaitingSecondClick = false
                    return
                }
                // Reject degenerate shapes (start ≈ end) — fixes the "flat line + dot".
                let sStart = toScreen(dx: start.x, dy: start.y, size: size, bounds: modelBounds)
                let sEnd = toScreen(dx: end.x, dy: end.y, size: size, bounds: modelBounds)
                if hypot(sStart.x - sEnd.x, sStart.y - sEnd.y) < 5.0 {
                    if state.currentTool != .sketchLine { sketchStartPoint = nil }
                    sketchAwaitingSecondClick = false
                    return
                }

                do {
                    if state.currentTool == .sketchText {
                        let textHeight = Double(abs(end.y - start.y))
                        let textWidth = Double(abs(end.x - start.x))
                        let textInsert = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
                        state.startEditingNewText(insert: textInsert, height: textHeight, width: textWidth)
                    } else if state.currentTool == .sketchLine {
                        let dist = Double(hypot(start.x - end.x, start.y - end.y))
                        Task {
                            if let handle = await state.addSketchedEntity(type: "line", params: [
                                "start": [Double(start.x), Double(start.y)],
                                "end": [Double(end.x), Double(end.y)]
                            ]) {
                                await MainActor.run {
                                    let lenMeasure = MeasurementLine(
                                        start: start,
                                        end: end,
                                        distanceMm: dist,
                                        isAutoDimension: true,
                                        entityHandle: handle,
                                        dimensionType: "length"
                                    )
                                    state.measurements.append(lenMeasure)
                                    
                                    // Focus the length dimension
                                    editingDimension = lenMeasure
                                    editingDimensionText = String(format: "%.2f", lenMeasure.distanceMm)
                                    let startScreen = toScreen(dx: lenMeasure.start.x, dy: lenMeasure.start.y, size: size, bounds: modelBounds)
                                    let endScreen = toScreen(dx: lenMeasure.end.x, dy: lenMeasure.end.y, size: size, bounds: modelBounds)
                                    editingDimensionScreenPos = CGPoint(
                                        x: (startScreen.x + endScreen.x) / 2,
                                        y: (startScreen.y + endScreen.y) / 2
                                    )
                                    isDimensionEditorFocused = true
                                }
                            }
                        }
                    } else if state.currentTool == .sketchCircle {
                        let radius = Double(hypot(start.x - end.x, start.y - end.y))
                        Task {
                            if let handle = await state.addSketchedEntity(type: "circle", params: [
                                "center": [Double(start.x), Double(start.y)],
                                "radius": radius
                            ]) {
                                let endRad = CGPoint(x: start.x + CGFloat(radius), y: start.y)
                                await MainActor.run {
                                    let radMeasure = MeasurementLine(
                                        start: start,
                                        end: endRad,
                                        distanceMm: radius,
                                        isAutoDimension: true,
                                        entityHandle: handle,
                                        dimensionType: "radius"
                                    )
                                    state.measurements.append(radMeasure)
                                    
                                    // Focus the radius dimension
                                    editingDimension = radMeasure
                                    editingDimensionText = String(format: "%.2f", radMeasure.distanceMm)
                                    let startScreen = toScreen(dx: radMeasure.start.x, dy: radMeasure.start.y, size: size, bounds: modelBounds)
                                    let endScreen = toScreen(dx: radMeasure.end.x, dy: radMeasure.end.y, size: size, bounds: modelBounds)
                                    editingDimensionScreenPos = CGPoint(
                                        x: (startScreen.x + endScreen.x) / 2,
                                        y: (startScreen.y + endScreen.y) / 2
                                    )
                                    isDimensionEditorFocused = true
                                }
                            }
                        }
                    } else if state.currentTool == .sketchPolygon {
                        // Bake the polygon as a closed, editable LWPOLYLINE (MAS-118).
                        let r = Double(hypot(start.x - end.x, start.y - end.y))
                        let rot = snappedPolygonRotation(Double(atan2(end.y - start.y, end.x - start.x)), sides: state.polygonSides)
                        let pts = polygonPoints(center: start, radius: r, rotation: rot, sides: state.polygonSides)
                        if pts.count >= 3 {
                            let coords = pts.map { [Double($0.x), Double($0.y)] }
                            Task {
                                _ = await state.addSketchedEntity(type: "path", params: ["points": coords, "closed": true])
                            }
                        }
                        sketchStartPoint = nil
                        sketchAwaitingSecondClick = false
                        return
                    } else if state.currentTool == .sketchRectangle {
                        Task {
                            // Create a SHARP rectangle; the fillet (if any) is applied
                            // parametrically below so it's a true arc and stays
                            // editable/convertible by the corner tools (MAS-62).
                            if let handle = await state.addSketchedEntity(type: "rectangle", params: [
                                "p1": [Double(start.x), Double(start.y)],
                                "p2": [Double(end.x), Double(end.y)],
                                "fillet_radius": 0.0
                            ]) {
                                let w = abs(end.x - start.x)
                                let h = abs(end.y - start.y)
                                let pBottomLeft = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
                                let pBottomRight = CGPoint(x: max(start.x, end.x), y: min(start.y, end.y))
                                let pTopLeft = CGPoint(x: min(start.x, end.x), y: max(start.y, end.y))
                                let pTopRight = CGPoint(x: max(start.x, end.x), y: max(start.y, end.y))
                                
                                await MainActor.run {
                                    let wMeasure = MeasurementLine(
                                        start: pBottomLeft,
                                        end: pBottomRight,
                                        distanceMm: Double(w),
                                        isAutoDimension: true,
                                        entityHandle: handle,
                                        dimensionType: "width",
                                        rectP1: pBottomLeft,
                                        rectP2: pTopRight,
                                        filletRadius: state.sketchFilletRadius
                                    )
                                    let hMeasure = MeasurementLine(
                                        start: pBottomLeft,
                                        end: pTopLeft,
                                        distanceMm: Double(h),
                                        isAutoDimension: true,
                                        entityHandle: handle,
                                        dimensionType: "height",
                                        rectP1: pBottomLeft,
                                        rectP2: pTopRight,
                                        filletRadius: state.sketchFilletRadius
                                    )
                                    state.measurements.append(wMeasure)
                                    state.measurements.append(hMeasure)
                                    // The fillet drag handle shows only now, on a
                                    // freshly drawn rectangle (MAS-62).
                                    state.justCreatedRectangleHandle = handle

                                    // Register the parametric corner model (sharp
                                    // base = 4 corners); apply the on-creation
                                    // fillet as true arcs if a radius was set.
                                    let r0 = state.sketchFilletRadius
                                    let base: [[Double]] = [
                                        [Double(pBottomLeft.x), Double(pBottomLeft.y)],
                                        [Double(pBottomRight.x), Double(pBottomRight.y)],
                                        [Double(pTopRight.x), Double(pTopRight.y)],
                                        [Double(pTopLeft.x), Double(pTopLeft.y)]
                                    ]
                                    let mods: [CornerMod] = r0 > 1e-9
                                        ? (0..<4).map { CornerMod(index: $0, kind: "fillet", value: r0, continuity: "G1") }
                                        : []
                                    state.parametricShapes[handle] = ParametricCornerShape(base: base, closed: true, corners: mods)
                                    if r0 > 1e-9 { state.applyParametricShape(handle: handle) }

                                    // Focus the width dimension
                                    editingDimension = wMeasure
                                    editingDimensionText = String(format: "%.2f", wMeasure.distanceMm)
                                    let startScreen = toScreen(dx: wMeasure.start.x, dy: wMeasure.start.y, size: size, bounds: modelBounds)
                                    let endScreen = toScreen(dx: wMeasure.end.x, dy: wMeasure.end.y, size: size, bounds: modelBounds)
                                    editingDimensionScreenPos = CGPoint(
                                        x: (startScreen.x + endScreen.x) / 2,
                                        y: (startScreen.y + endScreen.y) / 2
                                    )
                                    isDimensionEditorFocused = true
                                }
                            }
                        }
                    }
                }
                
                // Single line: the second click finishes the line. The user stays
                // on the Line tool, and the next click starts a fresh line (no chain).
                sketchStartPoint = nil
                sketchAwaitingSecondClick = false
            }
            return
        }
        
        let dragDist = hypot(val.translation.width, val.translation.height)
        if dragDist < 4.0 {
            // CLICK
            let point = val.startLocation
            if state.currentTool == .scale && state.pickingScalePivot {
                // Set the custom scale point (MAS-128) and stop picking.
                state.scalePivotModel = snappedModelPoint(forScreen: point, ref: nil, size: size, bounds: modelBounds)
                state.scaleFromCenter = false
                state.pickingScalePivot = false
            } else if state.currentTool == .patterning && state.pickingPatternPivot {
                // Set the circular-pattern center (MAS-113) and stop picking.
                state.patternPivotModel = snappedModelPoint(forScreen: point, ref: nil, size: size, bounds: modelBounds)
                state.pickingPatternPivot = false
            } else if state.currentTool == .patterning && state.pickingPatternPath {
                // Set the guide path and stop picking.
                let clickedModelPt = toModel(point: point, size: size, bounds: modelBounds)
                if let nearest = findNearestEntity(modelPt: clickedModelPt, maxDistanceScreen: 16.0, size: size, bounds: modelBounds) {
                    state.patternPathHandle = nearest.handle
                    state.pickingPatternPath = false
                }
            } else if state.currentTool == .select || state.currentTool == .move || state.currentTool == .offset || state.currentTool == .addThickness || state.currentTool == .addHoles || state.currentTool == .cleanup || state.currentTool == .paperFolding || state.currentTool == .convertLines || state.currentTool == .scale || state.currentTool == .patterning {
                let clickedModelPt = toModel(point: point, size: size, bounds: modelBounds)
                
                // Check for dimension line click selection first
                // Any deliberate selection click dismisses the creation-only
                // fillet handle so it never returns on re-select (MAS-62).
                state.justCreatedRectangleHandle = nil
                if let nearestMeasure = findNearestMeasurement(screenPt: point, size: size, bounds: modelBounds, excludeAuto: true) {
                    state.selectedMeasurement = nearestMeasure
                } else {
                    state.selectedMeasurement = nil

                    if let nearest = findNearestEntity(modelPt: clickedModelPt, maxDistanceScreen: Self.selectionHitTolerance, size: size, bounds: modelBounds) {
                        if state.chainSelectionEnabled {
                            state.triggerChainSelect(seedHandle: nearest.handle)
                        } else {
                            if NSEvent.modifierFlags.contains(.shift) {
                                if state.selectedHandles.contains(nearest.handle) {
                                    state.selectedHandles.remove(nearest.handle)
                                } else {
                                    state.selectedHandles.insert(nearest.handle)
                                }
                            } else {
                                state.selectedHandles = [nearest.handle]
                            }
                        }
                    } else {
                        // Offset is a modal tool: clicking empty space confirms the
                        // pending offset and returns to Select — matching Enter/OK,
                        // with Esc/Cancel to discard. Standard click-away-to-commit.
                        if state.currentTool == .offset && !state.selectedHandles.isEmpty {
                            state.applyOffset(exitAfterApply: true)
                        } else if !NSEvent.modifierFlags.contains(.shift) {
                            state.selectedHandles.removeAll()
                        }
                    }
                }
            } else if state.isCalibrationActive {
                let modelPt = snappedModelPoint(forScreen: point, ref: nil, size: size, bounds: modelBounds)
                state.calibrationPoints.append(modelPt)
                if state.calibrationPoints.count == 2 {
                    state.isCalibrationActive = false
                    
                    let p1 = state.calibrationPoints[0]
                    let p2 = state.calibrationPoints[1]
                    let measured = Double(hypot(p2.x - p1.x, p2.y - p1.y))
                    
                    let midModel = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                    let screenPos = toScreen(dx: midModel.x, dy: midModel.y, size: size, bounds: modelBounds)
                    
                    state.calibrationInputScreenPos = screenPos
                    state.calibrationTempDistanceText = String(format: "%.2f", measured)
                    state.isCalibratingDistanceInput = true
                    isCalibrationInputFocused = true
                }
            } else if state.currentTool == .measure {
                // Place at the snap point under the cursor (or ortho-constrained),
                // not the raw cursor — snapping now actually drives placement.
                let clickedModelPt = snappedModelPoint(forScreen: point, ref: state.activeMeasureStart, size: size, bounds: modelBounds)
                if let startModel = state.activeMeasureStart {
                    let dist = Double(hypot(startModel.x - clickedModelPt.x, startModel.y - clickedModelPt.y))
                    let newMeasure = MeasurementLine(start: startModel, end: clickedModelPt, distanceMm: dist)
                    state.measurements.append(newMeasure)
                    state.activeMeasureStart = nil
                } else {
                    state.activeMeasureStart = clickedModelPt
                }
            } else if state.currentTool == .dimension {
                placeDimension(at: point, size: size, modelBounds: modelBounds)
            }
        } else {
            // DRAG RELEASE
            if state.currentTool != .pan && state.currentTool != .measure && state.currentTool != .offset && !NSEvent.modifierFlags.contains(.option) {
                let p1 = toModel(point: val.startLocation, size: size, bounds: modelBounds)
                let p2 = toModel(point: val.location, size: size, bounds: modelBounds)
                let modelSelRect = CGRect(
                    x: min(p1.x, p2.x),
                    y: min(p1.y, p2.y),
                    width: abs(p1.x - p2.x),
                    height: abs(p1.y - p2.y)
                )
                
                var layerLookup: [String: DXFLayer] = [:]
                for layer in state.layers {
                    layerLookup[layer.id] = layer
                    layerLookup[layer.name] = layer
                }
                
                var boxSelected: Set<String> = []
                for ent in state.entities {
                    let matched = ent.layerId.flatMap { layerLookup[$0] } ?? layerLookup[ent.layer]
                    let visible = matched?.visible ?? true
                    if visible && entityIntersectsRect(ent: ent, rect: modelSelRect) {
                        boxSelected.insert(ent.handle)
                    }
                }
                
                if NSEvent.modifierFlags.contains(.shift) {
                    state.selectedHandles.formUnion(boxSelected)
                } else {
                    state.selectedHandles = boxSelected
                }
            }
        }
        dragSelectionStart = nil
        dragSelectionEnd = nil
    }

    private func drawFilletControlArrow(_ context: inout GraphicsContext, size: CGSize, modelBounds: CGRect) {
        guard let selected = state.selectedMeasurement,
              let p1 = selected.rectP1,
              let p2 = selected.rectP2,
              selected.entityHandle == state.justCreatedRectangleHandle else { return }
              
        let filletRad = selected.filletRadius
        let maxX = max(p1.x, p2.x)
        let maxY = max(p1.y, p2.y)
        
        let cornerScreen = toScreen(dx: Double(maxX), dy: Double(maxY), size: size, bounds: modelBounds)
        let handleScreen = toScreen(dx: Double(maxX - filletRad), dy: Double(maxY - filletRad), size: size, bounds: modelBounds)
        
        var linePath = SwiftUI.Path()
        linePath.move(to: cornerScreen)
        linePath.addLine(to: handleScreen)
        context.stroke(linePath, with: .color(Color.accent), lineWidth: 1.5)
        
        if isDraggingFillet {
            let pts = pointsOnRoundedRectangle(p1: p1, p2: p2, r: state.sketchFilletRadius)
            if pts.count >= 2 {
                let strokeColor = Color.status_warn
                let strokeStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 4])
                var previewPath = SwiftUI.Path()
                let pStart = toScreen(dx: pts[0].x, dy: pts[0].y, size: size, bounds: modelBounds)
                previewPath.move(to: pStart)
                for i in 1..<pts.count {
                    let p = toScreen(dx: pts[i].x, dy: pts[i].y, size: size, bounds: modelBounds)
                    previewPath.addLine(to: p)
                }
                previewPath.closeSubpath()
                context.stroke(previewPath, with: .color(strokeColor), style: strokeStyle)
            }
        }
    }

    private func drawOffsetControlArrow(_ context: inout GraphicsContext, size: CGSize, modelBounds: CGRect) {
        guard state.currentTool == .offset,
              let handleInfo = getOffsetHandleInfo() else { return }
              
        let startScreen = toScreen(dx: Double(handleInfo.basePoint.x), dy: Double(handleInfo.basePoint.y), size: size, bounds: modelBounds)
        
        let scaleDir: CGFloat = state.offsetSide == "left" ? 1.0 : -1.0
        let handlePt = CGPoint(
            x: handleInfo.basePoint.x + handleInfo.normal.x * CGFloat(state.offsetDistance) * scaleDir,
            y: handleInfo.basePoint.y + handleInfo.normal.y * CGFloat(state.offsetDistance) * scaleDir
        )
        let handleScreen = toScreen(dx: Double(handlePt.x), dy: Double(handlePt.y), size: size, bounds: modelBounds)
        
        var linePath = SwiftUI.Path()
        linePath.move(to: startScreen)
        linePath.addLine(to: handleScreen)
        context.stroke(linePath, with: .color(Color.status_warn), lineWidth: 1.5)
        
        // Draw arrow head pointing along the normal
        var arrowPath = SwiftUI.Path()
        let dx: CGFloat = handleScreen.x - startScreen.x
        let dy: CGFloat = handleScreen.y - startScreen.y
        let len: CGFloat = CGFloat(hypot(Double(dx), Double(dy)))
        if len > CGFloat(0.001) {
            let ux: CGFloat = dx / len
            let uy: CGFloat = dy / len
            let px: CGFloat = -uy
            let py: CGFloat = ux
            
            let arrowTip: CGPoint = handleScreen
            let arrowBase = CGPoint(x: handleScreen.x - ux * CGFloat(8.0), y: handleScreen.y - uy * CGFloat(8.0))
            let arrowLeft = CGPoint(x: arrowBase.x - px * CGFloat(5.0), y: arrowBase.y - py * CGFloat(5.0))
            let arrowRight = CGPoint(x: arrowBase.x + px * CGFloat(5.0), y: arrowBase.y + py * CGFloat(5.0))
            
            arrowPath.move(to: arrowTip)
            arrowPath.addLine(to: arrowLeft)
            arrowPath.addLine(to: arrowRight)
            arrowPath.closeSubpath()
            context.fill(arrowPath, with: .color(Color.status_warn))
        }
        // NOTE: the real offset preview is the concentric `previewEntities` ghost
        // drawn in renderCanvas (computed natively in OffsetGeometry). A legacy
        // drag-only overlay used to live here that just *translated* each selected
        // entity along the normal — a same-size shifted copy, not a true offset —
        // which flickered over the correct preview while dragging. It's removed.
    }
    
    struct OffsetHandleInfo {
        let basePoint: CGPoint // Model space
        let normal: CGPoint    // Model space
    }
    
    private func getOffsetHandleInfo() -> OffsetHandleInfo? {
        for handle in state.selectedHandles {
            guard let ent = state.entities.first(where: { $0.handle == handle }) else { continue }
            if ent.type == "LINE", let s = ent.start, let e = ent.end {
                let startPt = CGPoint(x: s[0], y: s[1])
                let endPt = CGPoint(x: e[0], y: e[1])
                let midPt = CGPoint(x: (startPt.x + endPt.x)/2, y: (startPt.y + endPt.y)/2)
                let dx = endPt.x - startPt.x
                let dy = endPt.y - startPt.y
                let len = hypot(dx, dy)
                if len > 1e-5 {
                    let normal = CGPoint(x: -dy / len, y: dx / len)
                    return OffsetHandleInfo(basePoint: midPt, normal: normal)
                }
            } else if let vertices = ent.vertices, vertices.count >= 2 {
                let startPt = CGPoint(x: vertices[0][0], y: vertices[0][1])
                let endPt = CGPoint(x: vertices[1][0], y: vertices[1][1])
                let midPt = CGPoint(x: (startPt.x + endPt.x)/2, y: (startPt.y + endPt.y)/2)
                let dx = endPt.x - startPt.x
                let dy = endPt.y - startPt.y
                let len = hypot(dx, dy)
                if len > 1e-5 {
                    let normal = CGPoint(x: -dy / len, y: dx / len)
                    return OffsetHandleInfo(basePoint: midPt, normal: normal)
                }
            }
        }
        if let center = selectionCenterModel {
            return OffsetHandleInfo(basePoint: center, normal: CGPoint(x: 1, y: 0))
        }
        return nil
    }

    // Geometry calculations
    private func getBounds(_ ents: [DXFEntity]) -> CGRect {
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        
        for ent in ents {
            if ent.type == "LINE", let s = ent.start, let e = ent.end {
                minX = min(minX, s[0], e[0])
                maxX = max(maxX, s[0], e[0])
                minY = min(minY, s[1], e[1])
                maxY = max(maxY, s[1], e[1])
            } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
                minX = min(minX, center[0] - radius)
                maxX = max(maxX, center[0] + radius)
                minY = min(minY, center[1] - radius)
                maxY = max(maxY, center[1] + radius)
            } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius {
                minX = min(minX, center[0] - radius)
                maxX = max(maxX, center[0] + radius)
                minY = min(minY, center[1] - radius)
                maxY = max(maxY, center[1] + radius)
            } else if let vertices = ent.vertices {
                for pt in vertices {
                    minX = min(minX, pt[0])
                    maxX = max(maxX, pt[0])
                    minY = min(minY, pt[1])
                    maxY = max(maxY, pt[1])
                }
            }
        }
        
        if minX == .infinity {
            return CGRect(x: -50, y: -50, width: 100, height: 100)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    private func toScreen(dx: Double, dy: Double, size: CGSize, bounds: CGRect) -> CGPoint {
        let screenX = dx * state.canvasScale + size.width / 2 + state.canvasOffset.width
        let screenY = -dy * state.canvasScale + size.height / 2 + state.canvasOffset.height
        return CGPoint(x: screenX, y: screenY)
    }

    /// Screen-space bounding box of an entity for viewport culling (MAS-74).
    /// Returns nil when the entity has no usable coordinates (always drawn).
    private func entityScreenBounds(_ ent: DXFEntity, size: CGSize, modelBounds: CGRect) -> CGRect? {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        func add(_ x: Double, _ y: Double) {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
        switch ent.type.uppercased() {
        case "LINE":
            guard let s = ent.start, let e = ent.end, s.count >= 2, e.count >= 2 else { return nil }
            add(s[0], s[1]); add(e[0], e[1])
        case "CIRCLE", "ARC":
            guard let c = ent.center, c.count >= 2, let r = ent.radius else { return nil }
            add(c[0] - r, c[1] - r); add(c[0] + r, c[1] + r)
        case "LWPOLYLINE", "POLYLINE":
            guard let v = ent.vertices, !v.isEmpty else { return nil }
            for p in v where p.count >= 2 { add(p[0], p[1]) }
        case "TEXT":
            guard let s = ent.start, s.count >= 2 else { return nil }
            let h = ent.height ?? 5.0
            add(s[0], s[1]); add(s[0] + h * 40, s[1] + h)   // generous width estimate
        default:
            return nil
        }
        if minX > maxX { return nil }
        // Project the model bbox corners to screen (y flips, so min/max swap).
        let p1 = toScreen(dx: minX, dy: minY, size: size, bounds: modelBounds)
        let p2 = toScreen(dx: maxX, dy: maxY, size: size, bounds: modelBounds)
        return CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                      width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }

    /// Wraps an angle into [0, 360) so the rotation box reads naturally (MAS-57).
    private func wrap360(_ a: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// The precision movement/rotation dimension box (MAS-57). Looks and behaves
    /// like the shape dimension editor: type an exact value + Enter to apply.
    @ViewBuilder
    private func gizmoDimBox(kind: String, centerModel: CGPoint, centerScreen: CGPoint) -> some View {
        let suffix = (kind == "rot") ? "°" : "mm"
        HStack(spacing: 2) {
            TextField("", text: $gizmoDimText)
                .textFieldStyle(.plain)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .focused($isGizmoDimFocused)
                .onSubmit { applyGizmoDim(kind: kind, centerModel: centerModel) }
            Text(suffix).font(.system(size: 11)).foregroundColor(Color.text_secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.bg_input)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accent, lineWidth: 1))
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(Color.text_primary)
        .position(x: centerScreen.x, y: centerScreen.y - 28)
    }

    /// Applies the typed exact value: absolute distance from the pre-drag origin
    /// for X/Y, absolute angle (mod 360) for rotation (MAS-57).
    private func applyGizmoDim(kind: String, centerModel: CGPoint) {
        guard let value = Double(gizmoDimText) else { return }
        switch kind {
        case "x":
            let extra = value - gizmoDimApplied
            if abs(extra) > 1e-9 { state.translateSelected(dx: CGFloat(extra), dy: 0) }
            gizmoDimApplied = value
        case "y":
            let extra = value - gizmoDimApplied
            if abs(extra) > 1e-9 { state.translateSelected(dx: 0, dy: CGFloat(extra)) }
            gizmoDimApplied = value
        case "rot":
            let target = wrap360(value)             // 730 → 10
            let delta = target - state.gizmoAccumulatedRotation
            if abs(delta) > 1e-9 {
                state.rotateSelected(angleDegrees: delta,
                                     center: [Double(centerModel.x), Double(centerModel.y)])
                state.gizmoAccumulatedRotation = target
            }
            gizmoDimApplied = target
            gizmoDimText = String(format: "%.1f", target)
        default:
            break
        }
    }

    /// Zooms/pans the canvas so all current geometry fits within `viewSize` with
    /// a margin (used after a multi-file distribute import so every file is
    /// visible at once — "all viewable"). Inverts `toScreen`'s transform.
    private func fitToContent(viewSize: CGSize) {
        guard viewSize.width > 1, viewSize.height > 1 else { return }
        // MAS-122: with nothing on the canvas, Home returns to the default opening
        // view — 1:1 scale at the origin, exactly how a fresh window opens — rather
        // than leaving the user wherever they happened to pan/zoom.
        guard !state.entities.isEmpty else {
            state.canvasScale = 1.0
            state.canvasOffset = .zero
            return
        }
        let b = robustContentBounds() ?? getBounds(state.entities)
        let bw = max(b.width, 0.001)
        let bh = max(b.height, 0.001)
        let margin: CGFloat = 0.82
        let scale = max(0.01, min(viewSize.width * margin / bw, viewSize.height * margin / bh))
        state.canvasScale = scale
        // Centre the content's midpoint in the viewport (see toScreen()).
        state.canvasOffset = CGSize(width: -b.midX * scale, height: b.midY * scale)
    }

    /// Per-entity bounding box (model space), excluding invisible POINT markers.
    private func entityBBox(_ ent: DXFEntity) -> CGRect? {
        if ent.type == "POINT" { return nil }
        if ent.type == "LINE", let s = ent.start, let e = ent.end {
            return CGRect(x: min(s[0], e[0]), y: min(s[1], e[1]), width: abs(e[0] - s[0]), height: abs(e[1] - s[1]))
        } else if (ent.type == "CIRCLE" || ent.type == "ARC"), let c = ent.center, let r = ent.radius {
            return CGRect(x: c[0] - r, y: c[1] - r, width: 2 * r, height: 2 * r)
        } else if let v = ent.vertices, !v.isEmpty {
            let xs = v.map { $0[0] }, ys = v.map { $0[1] }
            let minx = xs.min()!, maxx = xs.max()!, miny = ys.min()!, maxy = ys.max()!
            return CGRect(x: minx, y: miny, width: maxx - minx, height: maxy - miny)
        }
        return nil
    }

    /// Content bounds for fitting, ignoring far-stray entities (centre > 4× the
    /// median centre-distance) so a lone mark can't zoom the whole view out —
    /// mirrors the Python `robust_shape_bounds` used for distribution (MAS-13).
    private func robustContentBounds() -> CGRect? {
        let boxes = state.entities.compactMap { entityBBox($0) }
        guard !boxes.isEmpty else { return nil }
        if boxes.count <= 2 {
            return boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        }
        let centers = boxes.map { CGPoint(x: $0.midX, y: $0.midY) }
        let mcx = centers.map { $0.x }.sorted()[centers.count / 2]
        let mcy = centers.map { $0.y }.sorted()[centers.count / 2]
        let dists = centers.map { hypot($0.x - mcx, $0.y - mcy) }
        let med = dists.sorted()[dists.count / 2]
        let threshold = max(med * 4.0, 1.0)
        var result: CGRect? = nil
        for (i, b) in boxes.enumerated() where dists[i] <= threshold {
            result = result.map { $0.union(b) } ?? b
        }
        return result
    }
    
    private func toModel(point: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
        let dx = (point.x - size.width / 2 - state.canvasOffset.width) / state.canvasScale
        let dy = -(point.y - size.height / 2 - state.canvasOffset.height) / state.canvasScale
        return CGPoint(x: dx, y: dy)
    }
    
    /// Adaptive grid (MAS-73). Minor spacing is chosen as the smallest "nice"
    /// value (1·2·5 × 10ⁿ mm) whose on-screen size is at least `minMinorPx`, so
    /// the apparent density stays roughly constant at every zoom level instead
    /// of going dense when zoomed out / sparse when zoomed in. Major lines always
    /// land on decade boundaries (10ⁿ mm), giving a stable 10/5/2-subdivision
    /// look as you scroll through the zoom range. Minor lines fade in as they
    /// grow past the threshold so the level change doesn't pop.
    private func drawGrid(context: GraphicsContext, size: CGSize, bounds: CGRect) {
        let scale = state.canvasScale
        guard scale > 0, size.width > 1, size.height > 1 else { return }

        // Pixels-per-mm == canvasScale (see toScreen). Pick the nice minor step.
        let minMinorPx: CGFloat = 9.0
        let raw = minMinorPx / scale                       // mm spanning minMinorPx
        let mag = pow(10.0, floor(log10(max(raw, 1e-9))))  // decade below `raw`
        let norm = raw / mag                               // in [1, 10)
        let stepNorm: CGFloat = norm <= 1 ? 1 : (norm <= 2 ? 2 : (norm <= 5 ? 5 : 10))
        let minorSpacing = stepNorm * mag
        let majorSpacing = 10.0 * mag                      // always a clean decade

        // Fade the minor lines in over the first ~1.6× past the threshold so the
        // step from one density level to the next is smooth, not a hard pop.
        let minorPx = minorSpacing * scale
        let fade = max(0.0, min(1.0, (minorPx - minMinorPx) / (minMinorPx * 0.6)))

        // Visible model range, snapped to the minor grid.
        let tl = toModel(point: CGPoint.zero, size: size, bounds: bounds)
        let br = toModel(point: CGPoint(x: size.width, y: size.height), size: size, bounds: bounds)
        let startX = floor(min(tl.x, br.x) / minorSpacing) * minorSpacing
        let endX = ceil(max(tl.x, br.x) / minorSpacing) * minorSpacing
        let startY = floor(min(tl.y, br.y) / minorSpacing) * minorSpacing
        let endY = ceil(max(tl.y, br.y) / minorSpacing) * minorSpacing

        let minorColor = Color.border_subtle.opacity(fade)

        func isMajorLine(_ v: CGFloat) -> Bool {
            // True when v sits on a decade boundary (within a fraction of a minor).
            let m = abs(v.truncatingRemainder(dividingBy: majorSpacing))
            return min(m, majorSpacing - m) < minorSpacing * 0.5
        }

        var minorPath = SwiftUI.Path()
        var majorPath = SwiftUI.Path()

        var x = startX
        while x <= endX {
            let start = toScreen(dx: x, dy: startY, size: size, bounds: bounds)
            let end = toScreen(dx: x, dy: endY, size: size, bounds: bounds)
            if isMajorLine(x) {
                majorPath.move(to: start)
                majorPath.addLine(to: end)
            } else {
                minorPath.move(to: start)
                minorPath.addLine(to: end)
            }
            x += minorSpacing
        }

        var y = startY
        while y <= endY {
            let start = toScreen(dx: startX, dy: y, size: size, bounds: bounds)
            let end = toScreen(dx: endX, dy: y, size: size, bounds: bounds)
            if isMajorLine(y) {
                majorPath.move(to: start)
                majorPath.addLine(to: end)
            } else {
                minorPath.move(to: start)
                minorPath.addLine(to: end)
            }
            y += minorSpacing
        }

        // Draw minor lines in one draw call
        context.stroke(minorPath, with: .color(minorColor), lineWidth: 0.4)
        // Draw major lines in one draw call
        context.stroke(majorPath, with: .color(Color.border_strong), lineWidth: 0.8)
    }
    
    private func pointsOnArc(center: CGPoint, radius: Double, startAngle: Double, endAngle: Double, numSegments: Int = 16) -> [CGPoint] {
        var pts: [CGPoint] = []
        let sa = startAngle
        var ea = endAngle
        if ea < sa {
            ea += 360.0
        }
        let step = (ea - sa) / Double(numSegments)
        for i in 0...numSegments {
            let angleDeg = sa + Double(i) * step
            let angleRad = angleDeg * .pi / 180.0
            let x = center.x + CGFloat(cos(angleRad) * radius)
            let y = center.y + CGFloat(sin(angleRad) * radius)
            pts.append(CGPoint(x: x, y: y))
        }
        return pts
    }

    private func pointsOnRoundedRectangle(p1: CGPoint, p2: CGPoint, r: Double) -> [CGPoint] {
        let minX = min(p1.x, p2.x)
        let maxX = max(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        let maxY = max(p1.y, p2.y)
        let w = maxX - minX
        let h = maxY - minY
        let actualR = max(0.0, min(r, Double(w) / 2.0, Double(h) / 2.0))
        
        if actualR < 1e-4 {
            return [
                CGPoint(x: minX, y: minY),
                CGPoint(x: maxX, y: minY),
                CGPoint(x: maxX, y: maxY),
                CGPoint(x: minX, y: maxY)
            ]
        }
        
        var pts: [CGPoint] = []
        // Corner 1: Bottom-Right
        for i in 0...8 {
            let angle = (270.0 + Double(i) * 11.25) * .pi / 180.0
            pts.append(CGPoint(
                x: maxX - CGFloat(actualR) + CGFloat(cos(angle) * actualR),
                y: minY + CGFloat(actualR) + CGFloat(sin(angle) * actualR)
            ))
        }
        // Corner 2: Top-Right
        for i in 0...8 {
            let angle = (0.0 + Double(i) * 11.25) * .pi / 180.0
            pts.append(CGPoint(
                x: maxX - CGFloat(actualR) + CGFloat(cos(angle) * actualR),
                y: maxY - CGFloat(actualR) + CGFloat(sin(angle) * actualR)
            ))
        }
        // Corner 3: Top-Left
        for i in 0...8 {
            let angle = (90.0 + Double(i) * 11.25) * .pi / 180.0
            pts.append(CGPoint(
                x: minX + CGFloat(actualR) + CGFloat(cos(angle) * actualR),
                y: maxY - CGFloat(actualR) + CGFloat(sin(angle) * actualR)
            ))
        }
        // Corner 4: Bottom-Left
        for i in 0...8 {
            let angle = (180.0 + Double(i) * 11.25) * .pi / 180.0
            pts.append(CGPoint(
                x: minX + CGFloat(actualR) + CGFloat(cos(angle) * actualR),
                y: minY + CGFloat(actualR) + CGFloat(sin(angle) * actualR)
            ))
        }
        return pts
    }

    private func entityIntersectsRect(ent: DXFEntity, rect: CGRect) -> Bool {
        if ent.type == "LINE", let s = ent.start, let e = ent.end {
            let p1 = CGPoint(x: s[0], y: s[1])
            let p2 = CGPoint(x: e[0], y: e[1])
            return rect.contains(p1) || rect.contains(p2) || lineIntersectsRect(p1: p1, p2: p2, rect: rect)
        } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
            let c = CGPoint(x: center[0], y: center[1])
            let containsCircle = rect.contains(CGPoint(x: c.x - radius, y: c.y - radius)) &&
                                 rect.contains(CGPoint(x: c.x + radius, y: c.y + radius))
            if containsCircle { return true }
            
            let pts = pointsOnArc(center: c, radius: radius, startAngle: 0, endAngle: 360, numSegments: 24)
            for i in 0..<(pts.count - 1) {
                if rect.contains(pts[i]) { return true }
                if lineIntersectsRect(p1: pts[i], p2: pts[i+1], rect: rect) { return true }
            }
            return false
        } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius,
                  let sa = ent.start_angle, let ea = ent.end_angle {
            let c = CGPoint(x: center[0], y: center[1])
            let pts = pointsOnArc(center: c, radius: radius, startAngle: sa, endAngle: ea, numSegments: 16)
            for i in 0..<(pts.count - 1) {
                if rect.contains(pts[i]) { return true }
                if lineIntersectsRect(p1: pts[i], p2: pts[i+1], rect: rect) { return true }
            }
            return false
        } else if ent.type == "TEXT", let start = ent.start, let textHeight = ent.height {
            let textLen = Double(ent.text?.count ?? 6)
            let textWidth = textLen * textHeight * 0.6
            let p1 = CGPoint(x: start[0], y: start[1])
            let p2 = CGPoint(x: start[0] + textWidth, y: start[1] + textHeight)
            let textRect = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
            return rect.intersects(textRect)
        } else if let vertices = ent.vertices {
            for i in 0..<vertices.count {
                let p = CGPoint(x: vertices[i][0], y: vertices[i][1])
                if rect.contains(p) { return true }
            }
            for i in 0..<vertices.count {
                let nextIdx = (i + 1) % vertices.count
                if nextIdx == 0 && ent.closed != true {
                    continue
                }
                let p1 = CGPoint(x: vertices[i][0], y: vertices[i][1])
                let p2 = CGPoint(x: vertices[nextIdx][0], y: vertices[nextIdx][1])
                if lineIntersectsRect(p1: p1, p2: p2, rect: rect) { return true }
            }
        }
        return false
    }

    private func lineIntersectsRect(p1: CGPoint, p2: CGPoint, rect: CGRect) -> Bool {
        if rect.contains(p1) || rect.contains(p2) { return true }
        let left = CGPoint(x: rect.minX, y: rect.minY)
        let right = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        return segmentsIntersect(p1, p2, left, right) ||
               segmentsIntersect(p1, p2, left, bottomLeft) ||
               segmentsIntersect(p1, p2, right, bottomRight) ||
               segmentsIntersect(p1, p2, bottomLeft, bottomRight)
    }

    private func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        let r_x = b.x - a.x
        let r_y = b.y - a.y
        let s_x = d.x - c.x
        let s_y = d.y - c.y
        
        let r_cross_s = r_x * s_y - r_y * s_x
        if abs(r_cross_s) < 1e-9 {
            return false // Parallel or collinear
        }
        
        let t = ((c.x - a.x) * s_y - (c.y - a.y) * s_x) / r_cross_s
        let u = ((c.x - a.x) * r_y - (c.y - a.y) * r_x) / r_cross_s
        
        return t >= 0 && t <= 1 && u >= 0 && u <= 1
    }

    private func findNearestMeasurement(screenPt: CGPoint, size: CGSize, bounds: CGRect, maxDistanceScreen: CGFloat = 12.0, excludeAuto: Bool = false) -> MeasurementLine? {
        var nearest: MeasurementLine? = nil
        var minDist = maxDistanceScreen

        for measure in state.measurements {
            // Auto-dimensions lie on top of their entity (e.g. a sketched line),
            // so for plain selection they must not intercept the click — the user
            // expects clicking the line to select the line (double-click still
            // edits the dimension, which passes excludeAuto:false).
            if excludeAuto && measure.isAutoDimension { continue }
            let a = toScreen(dx: measure.start.x, dy: measure.start.y, size: size, bounds: bounds)
            let b = toScreen(dx: measure.end.x, dy: measure.end.y, size: size, bounds: bounds)
            
            let l2 = (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
            let dist: CGFloat
            if l2 == 0 {
                dist = hypot(screenPt.x - a.x, screenPt.y - a.y)
            } else {
                var t = ((screenPt.x - a.x) * (b.x - a.x) + (screenPt.y - a.y) * (b.y - a.y)) / l2
                t = max(0, min(1, t))
                let proj = CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
                dist = hypot(screenPt.x - proj.x, screenPt.y - proj.y)
            }
            
            if dist < minDist {
                minDist = dist
                nearest = measure
            }
        }
        return nearest
    }

    private func findNearestEntity(modelPt: CGPoint, maxDistanceScreen: CGFloat, size: CGSize, bounds: CGRect) -> DXFEntity? {
        var nearest: DXFEntity? = nil
        var minDistanceScreen = maxDistanceScreen
        
        var layerLookup: [String: DXFLayer] = [:]
        for layer in state.layers {
            layerLookup[layer.id] = layer
            layerLookup[layer.name] = layer
        }
        
        for ent in state.entities {
            let matched = ent.layerId.flatMap { layerLookup[$0] } ?? layerLookup[ent.layer]
            let visible = matched?.visible ?? true
            if !visible { continue }
            
            var distModel = Double.infinity
            if ent.type == "LINE", let s = ent.start, let e = ent.end {
                distModel = distanceToSegment(pt: modelPt, start: CGPoint(x: s[0], y: s[1]), end: CGPoint(x: e[0], y: e[1]))
            } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
                let d = distance(modelPt, CGPoint(x: center[0], y: center[1]))
                distModel = abs(d - radius)
            } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius,
                      let sa = ent.start_angle, let ea = ent.end_angle {
                let d = distance(modelPt, CGPoint(x: center[0], y: center[1]))
                let dx = modelPt.x - CGFloat(center[0])
                let dy = modelPt.y - CGFloat(center[1])
                var angle = atan2(dy, dx) * 180.0 / .pi
                if angle < 0 { angle += 360.0 }
                
                let inArc: Bool
                if sa <= ea {
                    inArc = (angle >= sa && angle <= ea)
                } else {
                    inArc = (angle >= sa || angle <= ea)
                }
                
                if inArc {
                    distModel = abs(d - radius)
                } else {
                    distModel = Double.infinity
                }
            } else if ent.type == "TEXT", let start = ent.start, let textHeight = ent.height {
                let textLen = Double(ent.text?.count ?? 6)
                let textWidth = max(textLen * textHeight * 0.6, textHeight)
                // Whole bounding-box hit (distance 0 inside) so clicking anywhere
                // on the text selects the entire entity, not just its baseline.
                let minX = start[0], maxX = start[0] + textWidth
                let minY = start[1], maxY = start[1] + textHeight
                let cx = min(max(Double(modelPt.x), minX), maxX)
                let cy = min(max(Double(modelPt.y), minY), maxY)
                distModel = hypot(Double(modelPt.x) - cx, Double(modelPt.y) - cy)
            } else if let vertices = ent.vertices {
                for i in 0..<vertices.count {
                    let nextIdx = (i + 1) % vertices.count
                    if nextIdx == 0 && ent.closed != true {
                        continue
                    }
                    let d = distanceToSegment(pt: modelPt, start: CGPoint(x: vertices[i][0], y: vertices[i][1]), end: CGPoint(x: vertices[nextIdx][0], y: vertices[nextIdx][1]))
                    distModel = min(distModel, d)
                }
            }
            
            let distScreen = CGFloat(distModel) * state.canvasScale
            if distScreen < minDistanceScreen {
                minDistanceScreen = distScreen
                nearest = ent
            }
        }
        if let nearest = nearest { return nearest }

        // Fallback (MAS-116): no outline landed within tolerance — select a CLOSED
        // shape whose filled interior the click is inside, so clicking *inside* a
        // rectangle/polygon/circle selects it instead of only its hairline border.
        // Purely additive: it never overrides a boundary hit, so existing
        // selections are unchanged. The smallest containing shape wins, so an
        // inner shape is picked over an enclosing one.
        var bestArea = Double.infinity
        var contained: DXFEntity? = nil
        for ent in state.entities {
            let matched = ent.layerId.flatMap { layerLookup[$0] } ?? layerLookup[ent.layer]
            if !(matched?.visible ?? true) { continue }

            var area = Double.infinity
            var inside = false
            if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
                if distance(modelPt, CGPoint(x: center[0], y: center[1])) <= radius {
                    inside = true
                    area = Double.pi * radius * radius
                }
            } else if ent.closed == true, let vertices = ent.vertices, vertices.count >= 3 {
                let pts = vertices.map { CGPoint(x: $0[0], y: $0[1]) }
                if pointInPolygon(modelPt, polygon: pts) {
                    inside = true
                    area = polygonArea(pts)
                }
            }
            if inside && area < bestArea {
                bestArea = area
                contained = ent
            }
        }
        return contained
    }

    /// Even-odd point-in-polygon test (ray casting) in model space.
    private func pointInPolygon(_ p: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i], pj = polygon[j]
            if (pi.y > p.y) != (pj.y > p.y) {
                let slope = (p.y - pi.y) / (pj.y - pi.y)
                let xCross = pi.x + slope * (pj.x - pi.x)
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Absolute area of a (possibly non-convex) polygon via the shoelace formula.
    private func polygonArea(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return .infinity }
        var sum: CGFloat = 0
        var j = pts.count - 1
        for i in 0..<pts.count {
            sum += (pts[j].x + pts[i].x) * (pts[j].y - pts[i].y)
            j = i
        }
        return Double(abs(sum) / 2.0)
    }

    private func distanceToSegment(pt: CGPoint, start: CGPoint, end: CGPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 1e-6 {
            return distance(pt, start)
        }
        var t = ((pt.x - start.x) * dx + (pt.y - start.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return distance(pt, proj)
    }
    
    private func distance(_ p1: CGPoint, _ p2: CGPoint) -> Double {
        Double(hypot(p1.x - p2.x, p1.y - p2.y))
    }
    
    // MARK: - Snapping & Dimension Cycling Logic
    
    struct SnapResult {
        let snappedModelPt: CGPoint
        let snappedScreenPt: CGPoint
        let type: SnapType
        
        enum SnapType: String {
            case endpoint = "Endpoint"
            case midpoint = "Midpoint"
            case center = "Center"
            case coincident = "Coincident"
        }
    }
    
    struct SnapCandidate {
        let modelPoint: CGPoint
        let type: SnapResult.SnapType
    }
    
    private func closestPointOnSegment(p: CGPoint, a: CGPoint, b: CGPoint) -> CGPoint {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
        let abLenSq = ab.x * ab.x + ab.y * ab.y
        if abLenSq < 1e-9 { return a }
        var t = (ap.x * ab.x + ap.y * ab.y) / abLenSq
        t = max(0.0, min(1.0, t))
        return CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
    }
    
    private func closestPointOnCircle(p: CGPoint, center: CGPoint, radius: CGFloat) -> CGPoint {
        let dx = p.x - center.x
        let dy = p.y - center.y
        let dist = hypot(dx, dy)
        if dist < 1e-9 {
            return CGPoint(x: center.x + radius, y: center.y)
        }
        return CGPoint(x: center.x + radius * dx / dist, y: center.y + radius * dy / dist)
    }
    
    private func closestPointOnArc(p: CGPoint, center: CGPoint, radius: CGFloat, startAngle: Double, endAngle: Double) -> CGPoint {
        let dx = p.x - center.x
        let dy = p.y - center.y
        let angleRad = atan2(dy, dx)
        var angleDeg = angleRad * 180.0 / .pi
        if angleDeg < 0 { angleDeg += 360 }
        
        var s = startAngle
        var e = endAngle
        if e < s { e += 360 }
        
        var testAngle = angleDeg
        if testAngle < s { testAngle += 360 }
        
        if testAngle >= s && testAngle <= e {
            return CGPoint(x: center.x + radius * cos(angleRad), y: center.y + radius * sin(angleRad))
        } else {
            let sRad = startAngle * .pi / 180.0
            let eRad = endAngle * .pi / 180.0
            let ptS = CGPoint(x: center.x + radius * cos(sRad), y: center.y + radius * sin(sRad))
            let ptE = CGPoint(x: center.x + radius * cos(eRad), y: center.y + radius * sin(eRad))
            let distS = hypot(p.x - ptS.x, p.y - ptS.y)
            let distE = hypot(p.x - ptE.x, p.y - ptE.y)
            return distS < distE ? ptS : ptE
        }
    }
    
    func getSnapCandidates(for queryModelPt: CGPoint) -> [SnapCandidate] {
        var list: [SnapCandidate] = []
        var layerLookup: [String: DXFLayer] = [:]
        for layer in state.layers {
            layerLookup[layer.id] = layer
            layerLookup[layer.name] = layer
        }
        for ent in state.entities {
            let matched = ent.layerId.flatMap { layerLookup[$0] } ?? layerLookup[ent.layer]
            let layerVisible = matched?.visible ?? true
            if !layerVisible { continue }
            
            if ent.type == "LINE", let s = ent.start, let e = ent.end {
                let ptS = CGPoint(x: s[0], y: s[1])
                let ptE = CGPoint(x: e[0], y: e[1])
                list.append(SnapCandidate(modelPoint: ptS, type: .endpoint))
                list.append(SnapCandidate(modelPoint: ptE, type: .endpoint))
                list.append(SnapCandidate(modelPoint: CGPoint(x: (ptS.x + ptE.x)/2, y: (ptS.y + ptE.y)/2), type: .midpoint))
                
                let coinc = closestPointOnSegment(p: queryModelPt, a: ptS, b: ptE)
                list.append(SnapCandidate(modelPoint: coinc, type: .coincident))
            } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
                let ptC = CGPoint(x: center[0], y: center[1])
                let r = CGFloat(radius)
                list.append(SnapCandidate(modelPoint: ptC, type: .center))
                
                let coinc = closestPointOnCircle(p: queryModelPt, center: ptC, radius: r)
                list.append(SnapCandidate(modelPoint: coinc, type: .coincident))
            } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius,
                      let sa = ent.start_angle, let ea = ent.end_angle {
                let ptC = CGPoint(x: center[0], y: center[1])
                let r = CGFloat(radius)
                list.append(SnapCandidate(modelPoint: ptC, type: .center))
                
                let saRad = sa * .pi / 180.0
                let eaRad = ea * .pi / 180.0
                let ptS = CGPoint(x: ptC.x + r * cos(saRad), y: ptC.y + r * sin(saRad))
                let ptE = CGPoint(x: ptC.x + r * cos(eaRad), y: ptC.y + r * sin(eaRad))
                list.append(SnapCandidate(modelPoint: ptS, type: .endpoint))
                list.append(SnapCandidate(modelPoint: ptE, type: .endpoint))
                
                var diff = ea - sa
                if diff < 0 { diff += 360 }
                let midAngle = sa + diff / 2
                let midRad = midAngle * .pi / 180.0
                let ptM = CGPoint(x: ptC.x + r * cos(midRad), y: ptC.y + r * sin(midRad))
                list.append(SnapCandidate(modelPoint: ptM, type: .midpoint))
                
                let coinc = closestPointOnArc(p: queryModelPt, center: ptC, radius: r, startAngle: sa, endAngle: ea)
                list.append(SnapCandidate(modelPoint: coinc, type: .coincident))
            } else if let vertices = ent.vertices, vertices.count >= 2 {
                let pts = vertices.map { CGPoint(x: $0[0], y: $0[1]) }
                if let cornerSnaps = state.cornerSnapPoints[ent.handle], !cornerSnaps.isEmpty {
                    // Parametric shape: snap only to the meaningful points — each
                    // blend's two tangent ends + its center, plus sharp corners —
                    // not to every flattened arc vertex (MAS-62). On-curve
                    // coincident snapping still works along the outline.
                    for sp in cornerSnaps {
                        list.append(SnapCandidate(modelPoint: CGPoint(x: sp.x, y: sp.y),
                                                  type: sp.role == "center" ? .midpoint : .endpoint))
                    }
                    let n = pts.count
                    let segCount = ent.closed == true ? n : n - 1
                    for i in 0..<segCount {
                        let a = pts[i]; let b = pts[(i + 1) % n]
                        list.append(SnapCandidate(modelPoint: closestPointOnSegment(p: queryModelPt, a: a, b: b), type: .coincident))
                    }
                } else {
                    for p in pts {
                        list.append(SnapCandidate(modelPoint: p, type: .endpoint))
                    }
                    for i in 0..<(pts.count - 1) {
                        let a = pts[i]
                        let b = pts[i+1]
                        list.append(SnapCandidate(modelPoint: CGPoint(x: (a.x + b.x)/2, y: (a.y + b.y)/2), type: .midpoint))

                        let coinc = closestPointOnSegment(p: queryModelPt, a: a, b: b)
                        list.append(SnapCandidate(modelPoint: coinc, type: .coincident))
                    }
                    if ent.closed == true {
                        let a = pts[pts.count - 1]
                        let b = pts[0]
                        list.append(SnapCandidate(modelPoint: CGPoint(x: (a.x + b.x)/2, y: (a.y + b.y)/2), type: .midpoint))
                        let coinc = closestPointOnSegment(p: queryModelPt, a: a, b: b)
                        list.append(SnapCandidate(modelPoint: coinc, type: .coincident))
                    }
                }
            }
        }
        return list
    }
    
    func getSnappedPoint(for screenPt: CGPoint, size: CGSize, bounds: CGRect) -> SnapResult? {
        let queryModelPt = toModel(point: screenPt, size: size, bounds: bounds)
        let candidates = getSnapCandidates(for: queryModelPt)
        
        var bestCandidate: SnapResult? = nil
        
        for cand in candidates {
            let candScreen = toScreen(dx: Double(cand.modelPoint.x), dy: Double(cand.modelPoint.y), size: size, bounds: bounds)
            let dist = hypot(screenPt.x - candScreen.x, screenPt.y - candScreen.y)
            if dist <= 12.0 {
                let res = SnapResult(snappedModelPt: cand.modelPoint, snappedScreenPt: candScreen, type: cand.type)
                if let best = bestCandidate {
                    let bestPri = getPriority(best.type)
                    let candPri = getPriority(res.type)
                    if candPri < bestPri {
                        bestCandidate = res
                    } else if candPri == bestPri {
                        let bestDist = hypot(screenPt.x - best.snappedScreenPt.x, screenPt.y - best.snappedScreenPt.y)
                        if dist < bestDist {
                            bestCandidate = res
                        }
                    }
                } else {
                    bestCandidate = res
                }
            }
        }
        
        return bestCandidate
    }
    
    private func getPriority(_ type: SnapResult.SnapType) -> Int {
        switch type {
        case .endpoint: return 0
        case .midpoint: return 1
        case .center: return 2
        case .coincident: return 3
        }
    }
    
    func snappedMouseLocation(size: CGSize, bounds: CGRect) -> (point: CGPoint, snap: SnapResult?) {
        // A real geometry snap (endpoint/midpoint/centre) under the cursor wins.
        if state.snapActive, let snap = getSnappedPoint(for: mouseLocation, size: size, bounds: bounds) {
            return (snap.snappedModelPt, snap)
        }
        var modelPt = toModel(point: mouseLocation, size: size, bounds: bounds)
        // Otherwise faintly snap a line/ruler segment to 90° increments.
        if state.snapActive, let ref = orthoReferencePoint() {
            modelPt = orthoConstrained(from: ref, to: modelPt)
        }
        return (modelPt, nil)
    }

    /// The segment start for ortho (90°) snapping — only for line/ruler tools.
    private func orthoReferencePoint() -> CGPoint? {
        if state.currentTool == .sketchLine { return sketchStartPoint }
        if state.currentTool == .measure { return state.activeMeasureStart }
        return nil
    }

    /// If the segment `ref → pt` is within ~7° of a 0/90/180/270° axis, rotate
    /// `pt` (keeping its distance) exactly onto that axis; otherwise unchanged.
    private func orthoConstrained(from ref: CGPoint, to pt: CGPoint) -> CGPoint {
        let dx = pt.x - ref.x, dy = pt.y - ref.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return pt }
        let deg = atan2(dy, dx) * 180.0 / .pi
        let nearest = (deg / 90.0).rounded() * 90.0
        if abs(nearest - deg) < 7.0 {
            let r = nearest * .pi / 180.0
            return CGPoint(x: ref.x + CGFloat(cos(r)) * len, y: ref.y + CGFloat(sin(r)) * len)
        }
        return pt
    }

    /// Snapped model point for a screen click (placement), honouring `snapEnabled`
    /// and ortho relative to an optional reference (e.g. the ruler's first point).
    private func snappedModelPoint(forScreen point: CGPoint, ref: CGPoint?, size: CGSize, bounds: CGRect) -> CGPoint {
        if state.snapActive, let s = getSnappedPoint(for: point, size: size, bounds: bounds) {
            return s.snappedModelPt
        }
        var m = toModel(point: point, size: size, bounds: bounds)
        if state.snapActive, let ref = ref {
            m = orthoConstrained(from: ref, to: m)
        }
        return m
    }
    
    private func cycleDimension(size: CGSize, modelBounds: CGRect) {
        guard let editing = editingDimension else { return }

        // Commit the current field value FIRST. For a parametric rectangle this
        // resizes the shape and regenerates its auto-dimensions, so any list we
        // captured beforehand would be stale (MAS-90: tabbing width→height used
        // a stale rectP2 and silently dropped the height edit).
        if let val = Double(editingDimensionText) {
            state.selectedMeasurement = state.measurements.first(where: { $0.id == editing.id }) ?? editing
            state.updateSelectedDimensionValue(newValue: val)
        }

        // Re-read the freshly regenerated auto-dimensions and advance to the next.
        let related = state.measurements.filter { $0.entityHandle == editing.entityHandle && $0.isAutoDimension }
        guard !related.isEmpty else { editingDimension = nil; isDimensionEditorFocused = false; return }

        let nextDim: MeasurementLine
        if let idx = related.firstIndex(where: { $0.id == editing.id }) {
            nextDim = related[(idx + 1) % related.count]
        } else {
            // The edited dimension was replaced during regeneration — fall back to
            // the next one of a different type (e.g. width → height).
            nextDim = related.first(where: { $0.dimensionType != editing.dimensionType }) ?? related[0]
        }

        editingDimension = nextDim
        editingDimensionText = String(format: "%.2f", nextDim.distanceMm)
        let startScreen = toScreen(dx: nextDim.start.x, dy: nextDim.start.y, size: size, bounds: modelBounds)
        let endScreen = toScreen(dx: nextDim.end.x, dy: nextDim.end.y, size: size, bounds: modelBounds)
        editingDimensionScreenPos = CGPoint(
            x: (startScreen.x + endScreen.x) / 2,
            y: (startScreen.y + endScreen.y) / 2
        )
        isDimensionEditorFocused = true
    }

    /// Dimension tool click (MAS-110 §1). Context-aware: clicking a line creates a
    /// linear length dimension, a circle/arc creates a radius dimension; clicking
    /// empty space starts a two-point linear distance (reference) dimension. Entity
    /// dimensions open the floating formula field so a typed value/formula drives
    /// the geometry; reference dimensions are placed at their measured value.
    private func placeDimension(at point: CGPoint, size: CGSize, modelBounds: CGRect) {
        let modelPt = toModel(point: point, size: size, bounds: modelBounds)

        if let ent = findNearestEntity(modelPt: modelPt, maxDistanceScreen: 14.0, size: size, bounds: modelBounds) {
            dimensionFirstPoint = nil
            if ent.type == "LINE", let s = ent.start, let e = ent.end {
                let a = CGPoint(x: s[0], y: s[1]), b = CGPoint(x: e[0], y: e[1])
                let len = Double(hypot(a.x - b.x, a.y - b.y))
                beginParametricDimension(start: a, end: b, value: len, type: "length",
                                         handle: ent.handle, size: size, modelBounds: modelBounds)
                return
            }
            if (ent.type == "CIRCLE" || ent.type == "ARC"), let c = ent.center, let r = ent.radius {
                let center = CGPoint(x: c[0], y: c[1])
                let edge = CGPoint(x: center.x + CGFloat(r), y: center.y)
                beginParametricDimension(start: center, end: edge, value: r, type: "radius",
                                         handle: ent.handle, size: size, modelBounds: modelBounds)
                return
            }
        }

        // Two-point linear (reference) distance.
        let snapped = snappedModelPoint(forScreen: point, ref: dimensionFirstPoint, size: size, bounds: modelBounds)
        if let first = dimensionFirstPoint {
            dimensionFirstPoint = nil
            let dist = Double(hypot(first.x - snapped.x, first.y - snapped.y))
            guard dist > 1e-6 else { return }
            state.saveToHistory()
            let varName = state.dimensionEngine.nextVarName()
            state.dimensionEngine.addNumeric(value: dist, id: varName, driven: true)
            let m = MeasurementLine(start: first, end: snapped, distanceMm: dist,
                                    isAutoDimension: false, dimensionType: "reference",
                                    varName: varName, expression: String(format: "%g", dist),
                                    driven: true, isParametric: true, offsetDistance: 0)
            state.measurements.append(m)
        } else {
            dimensionFirstPoint = snapped
        }
    }

    /// Seeds a driving entity dimension and opens the floating field for explicit
    /// (typed) value/formula entry.
    private func beginParametricDimension(start: CGPoint, end: CGPoint, value: Double,
                                          type: String, handle: String,
                                          size: CGSize, modelBounds: CGRect) {
        state.saveToHistory()
        let varName = state.dimensionEngine.nextVarName()
        state.dimensionEngine.addNumeric(value: value, id: varName, driven: false)
        // Offset the dimension line clear of the geometry (~26 px) (MAS-110 §2).
        let offModel = Double(26.0 / max(state.canvasScale, 0.0001))
        let m = MeasurementLine(start: start, end: end, distanceMm: value,
                                isAutoDimension: false, entityHandle: handle,
                                dimensionType: type, varName: varName,
                                expression: String(format: "%g", value),
                                driven: false, isParametric: true, offsetDistance: offModel)
        state.measurements.append(m)
        state.selectedMeasurement = m
        editingDimension = m
        editingDimensionText = String(format: "%.2f", value)
        let s = toScreen(dx: start.x, dy: start.y, size: size, bounds: modelBounds)
        let e = toScreen(dx: end.x, dy: end.y, size: size, bounds: modelBounds)
        editingDimensionScreenPos = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2 - 24)
        dimensionFieldError = false
        isDimensionEditorFocused = true
    }

    /// Routes an Enter/Tab on the floating dimension field. Parametric dimensions
    /// (placed by the Dimension tool) go through the formula engine — invalid input
    /// flashes red and keeps focus; a valid value commits, closes the box, and
    /// leaves the persistent Dimension tool active (MAS-110 / MAS-111). Auto
    /// dimensions keep the legacy numeric commit.
    private func commitDimensionField(size: CGSize, modelBounds: CGRect) {
        guard let editing = editingDimension else { return }
        if editing.isParametric {
            if let err = state.commitDimensionExpression(measureId: editing.id, rawExpression: editingDimensionText) {
                // Invalid — flash red, keep focus for correction (MAS-111).
                state.errorMessage = err.errorDescription
                dimensionFieldError = true
                isDimensionEditorFocused = true
                return
            }
            // Success: close the box but stay in the Dimension tool, ready for the
            // next pick (persistent-tool behavior).
            editingDimension = nil
            isDimensionEditorFocused = false
            dimensionFieldError = false
            state.selectedMeasurement = nil
            return
        }
        commitDimensionEdit()
    }

    private func commitDimensionEdit() {
        if let editing = editingDimension {
            if let val = Double(editingDimensionText) {
                // Use the live measurement (its rectP1/rectP2 may have been updated
                // by a prior Tab commit) rather than the captured copy (MAS-90).
                state.selectedMeasurement = state.measurements.first(where: { $0.id == editing.id }) ?? editing
                state.updateSelectedDimensionValue(newValue: val)
            }
        }
        // Enter finalizes the shape: drop back to the Select tool and deselect so
        // the auto-dimension lines disappear (they only show while selected).
        finishDimensioning()
    }

    /// Ends the on-creation dimensioning step: closes the editor, returns to the
    /// Select tool, and clears the selection so auto-dimensions hide. Shared by
    /// Enter (commit) and Escape (dismiss).
    private func finishDimensioning() {
        editingDimension = nil
        isDimensionEditorFocused = false
        state.justCreatedRectangleHandle = nil
        state.selectedMeasurement = nil
        state.selectedHandles.removeAll()
        if state.currentTool != .select { state.currentTool = .select }
    }

    private func getSelectedLineEntity() -> DXFEntity? {
        if state.selectedHandles.count == 1,
           let handle = state.selectedHandles.first,
           let ent = state.entities.first(where: { $0.handle == handle }),
           ent.type == "LINE",
           ent.start != nil,
           ent.end != nil {
            return ent
        }
        return nil
    }

    private func drawGlueTabPreview(_ ent: DXFEntity, size: CGSize, modelBounds: CGRect, context: inout GraphicsContext) {
        guard let s = ent.start, let e = ent.end else { return }
        let p1 = CGPoint(x: s[0], y: s[1])
        let p2 = CGPoint(x: e[0], y: e[1])
        
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let L = hypot(dx, dy)
        if L < 0.1 { return }
        
        let ux = dx / L
        let uy = dy / L
        
        let height = CGFloat(state.glueTabHeight)
        let tabType = state.glueTabType
        let side = state.glueTabSide
        let startOffset = CGFloat(state.glueTabStartOffset)
        let endOffset = CGFloat(state.glueTabEndOffset)
        
        if startOffset + endOffset >= L { return }
        
        let nx: CGFloat
        let ny: CGFloat
        if side == "left" {
            nx = uy
            ny = -ux
        } else {
            nx = -uy
            ny = ux
        }
        
        let p1_tab = CGPoint(x: p1.x + startOffset * ux, y: p1.y + startOffset * uy)
        let p2_tab = CGPoint(x: p2.x - endOffset * ux, y: p2.y - endOffset * uy)
        let L_tab = L - startOffset - endOffset
        
        var tabPts: [CGPoint] = [p1_tab]
        
        if tabType == "triangle" {
            let midX = (p1_tab.x + p2_tab.x) / 2.0
            let midY = (p1_tab.y + p2_tab.y) / 2.0
            let peak = CGPoint(x: midX + height * nx, y: midY + height * ny)
            tabPts.append(peak)
        } else {
            let hOffset = min(height, L_tab / 2.1)
            let t1 = CGPoint(x: p1_tab.x + hOffset * ux + height * nx, y: p1_tab.y + hOffset * uy + height * ny)
            let t2 = CGPoint(x: p2_tab.x - hOffset * ux + height * nx, y: p2_tab.y - hOffset * uy + height * ny)
            tabPts.append(t1)
            tabPts.append(t2)
        }
        tabPts.append(p2_tab)
        
        var path = SwiftUI.Path()
        let screenStart = toScreen(dx: Double(tabPts[0].x), dy: Double(tabPts[0].y), size: size, bounds: modelBounds)
        path.move(to: screenStart)
        for i in 1..<tabPts.count {
            let screenPt = toScreen(dx: Double(tabPts[i].x), dy: Double(tabPts[i].y), size: size, bounds: modelBounds)
            path.addLine(to: screenPt)
        }
        
        context.stroke(path, with: .color(Color.purple.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 3]))
    }

    /// Builds a SwiftUI `Font` for a TEXT entity from an installed family name
    /// (MAS-134) plus bold/italic traits, falling back to the system font when
    /// the family is empty/unavailable. Bold/italic are applied via the font
    /// manager so they work for any installed family, not just system fonts.
    static func resolveTextFont(family: String?, size: CGFloat, bold: Bool, italic: Bool) -> Font {
        Font(resolveNSFont(family: family, size: size, bold: bold, italic: italic))
    }

    /// Same resolution as `resolveTextFont` but returns the raw `NSFont`, used by
    /// the inline text editor (which needs an AppKit font).
    static func resolveNSFont(family: String?, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let fm = NSFontManager.shared
        var base: NSFont
        if let fam = family, !fam.isEmpty,
           let f = fm.font(withFamily: fam, traits: [], weight: 5, size: size) ?? NSFont(name: fam, size: size) {
            base = f
        } else {
            base = NSFont.systemFont(ofSize: size)
        }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            base = fm.convert(base, toHaveTrait: traits)
        }
        return base
    }

    /// The font family to render a TEXT entity with, substituting the live
    /// font-hover preview when this entity is the one currently being styled —
    /// the text being typed, or the single selected text (MAS-134).
    private func effectiveTextFontFamily(_ ent: DXFEntity) -> String? {
        if let hp = state.fontHoverPreview {
            let editingThis = state.isEditingText && state.editingTextHandle == ent.handle
            let selectedSingle = state.singleSelectedTextEntity?.handle == ent.handle
            if editingThis || selectedSingle { return hp.isEmpty ? nil : hp }
        }
        return ent.fontName
    }

    private func drawEntity(_ ent: DXFEntity, baseColor: Color, strokeColor: Color, strokeWidth: Double, size: CGSize, modelBounds: CGRect, context: inout GraphicsContext) {
        var path = SwiftUI.Path()
        if ent.type == "LINE", let s = ent.start, let e = ent.end {
            let p1 = toScreen(dx: s[0], dy: s[1], size: size, bounds: modelBounds)
            let p2 = toScreen(dx: e[0], dy: e[1], size: size, bounds: modelBounds)
            path.move(to: p1)
            path.addLine(to: p2)
            context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
        } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
            let sc = toScreen(dx: center[0], dy: center[1], size: size, bounds: modelBounds)
            let r = CGFloat(radius) * state.canvasScale
            let rect = CGRect(x: sc.x - r, y: sc.y - r, width: r * 2, height: r * 2)
            path.addEllipse(in: rect)
            context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
        } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius,
                  let sa = ent.start_angle, let ea = ent.end_angle {
            let sc = toScreen(dx: center[0], dy: center[1], size: size, bounds: modelBounds)
            let r = CGFloat(radius) * state.canvasScale
            path.addArc(
                center: sc,
                radius: r,
                startAngle: Angle(degrees: -sa),
                endAngle: Angle(degrees: -ea),
                clockwise: true
            )
            context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
        } else if let vertices = ent.vertices {
            if vertices.count >= 2 {
                let pStart = toScreen(dx: vertices[0][0], dy: vertices[0][1], size: size, bounds: modelBounds)
                path.move(to: pStart)
                for i in 1..<vertices.count {
                    let p = toScreen(dx: vertices[i][0], dy: vertices[i][1], size: size, bounds: modelBounds)
                    path.addLine(to: p)
                }
                if ent.closed == true {
                    path.closeSubpath()
                }
                // Filled region (MAS-146): paint a translucent interior in the
                // layer colour beneath the outline, even-odd so holes show through.
                if ent.filled == true {
                    var fillPath = SwiftUI.Path()
                    let loops = ent.fillLoops ?? [vertices]
                    for loop in loops where loop.count >= 3 {
                        let f0 = toScreen(dx: loop[0][0], dy: loop[0][1], size: size, bounds: modelBounds)
                        fillPath.move(to: f0)
                        for i in 1..<loop.count {
                            fillPath.addLine(to: toScreen(dx: loop[i][0], dy: loop[i][1], size: size, bounds: modelBounds))
                        }
                        fillPath.closeSubpath()
                    }
                    context.fill(fillPath, with: .color(baseColor.opacity(0.28)), style: FillStyle(eoFill: true))
                }
                context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
            }
        } else if ent.type == "TEXT", let textStr = ent.text, let start = ent.start {
            if state.isEditingText && state.editingTextHandle == ent.handle {
                // Editing text is handled inline by text editor overlay
            } else {
                let sc = toScreen(dx: start[0], dy: start[1], size: size, bounds: modelBounds)
                let baseHeight: Double = ent.height ?? 5.0
                let scale: CGFloat = state.canvasScale
                let h: CGFloat = CGFloat(baseHeight) * scale
                // Honour a live font-hover preview when this is the text being styled.
                let family = effectiveTextFontFamily(ent)
                let nsFont = DxfCanvasView.resolveNSFont(
                    family: family, size: h,
                    bold: ent.bold ?? false, italic: ent.italic ?? false)
                // Selected → accent; hovered → darker, signalling the whole text is
                // grabbable as one unit (one click selects, double click edits).
                let textColor: Color
                if state.selectedHandles.contains(ent.handle) {
                    textColor = Color.accent
                } else if state.hoveredHandle == ent.handle {
                    textColor = Color.accent_hover
                } else {
                    textColor = baseColor
                }
                var uiText: Text = Text(textStr).font(Font(nsFont)).foregroundColor(textColor)
                if ent.underline ?? false { uiText = uiText.underline() }
                if let cs = ent.charSpacing, cs != 0 { uiText = uiText.tracking(CGFloat(cs) * scale) }
                let resolvedText = context.resolve(uiText)
                // The insert point is the first line's baseline-left (DXF convention),
                // so anchor by the block's top-left at one ascender above it. This
                // matches the inline editor exactly and makes multi-line text flow
                // downward from the insert point.
                let ascender = nsFont.ascender
                let rotDeg = ent.rotation ?? 0.0
                // Horizontal warp: stretch glyphs about the insert point (MAS-157).
                let wf = CGFloat(ent.widthFactor ?? 1.0)
                if abs(rotDeg) > 0.001 || abs(wf - 1.0) > 0.001 {
                    context.drawLayer { ctx in
                        ctx.translateBy(x: sc.x, y: sc.y)
                        if abs(rotDeg) > 0.001 {
                            ctx.rotate(by: Angle(degrees: -rotDeg))  // CCW (DXF) → screen (Y-down)
                        }
                        if abs(wf - 1.0) > 0.001 {
                            ctx.scaleBy(x: wf, y: 1.0)
                        }
                        ctx.draw(resolvedText, at: CGPoint(x: 0, y: -ascender), anchor: .topLeading)
                    }
                } else {
                    context.draw(resolvedText, at: CGPoint(x: sc.x, y: sc.y - ascender), anchor: .topLeading)
                }
            }
        }
    }

    private func drawPreviewEntity(_ ent: DXFEntity, strokeColor: Color, strokeStyle: StrokeStyle, size: CGSize, modelBounds: CGRect, context: inout GraphicsContext) {
        var path = SwiftUI.Path()
        if ent.type == "LINE", let s = ent.start, let e = ent.end {
            let p1 = toScreen(dx: s[0], dy: s[1], size: size, bounds: modelBounds)
            let p2 = toScreen(dx: e[0], dy: e[1], size: size, bounds: modelBounds)
            path.move(to: p1)
            path.addLine(to: p2)
            context.stroke(path, with: .color(strokeColor), style: strokeStyle)
        } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
            let sc = toScreen(dx: center[0], dy: center[1], size: size, bounds: modelBounds)
            let r = CGFloat(radius) * state.canvasScale
            let rect = CGRect(x: sc.x - r, y: sc.y - r, width: r * 2, height: r * 2)
            path.addEllipse(in: rect)
            context.stroke(path, with: .color(strokeColor), style: strokeStyle)
        } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius,
                  let sa = ent.start_angle, let ea = ent.end_angle {
            let sc = toScreen(dx: center[0], dy: center[1], size: size, bounds: modelBounds)
            let r = CGFloat(radius) * state.canvasScale
            path.addArc(
                center: sc,
                radius: r,
                startAngle: Angle(degrees: -sa),
                endAngle: Angle(degrees: -ea),
                clockwise: true
            )
            context.stroke(path, with: .color(strokeColor), style: strokeStyle)
        } else if let vertices = ent.vertices {
            if vertices.count >= 2 {
                let pStart = toScreen(dx: vertices[0][0], dy: vertices[0][1], size: size, bounds: modelBounds)
                path.move(to: pStart)
                for i in 1..<vertices.count {
                    let p = toScreen(dx: vertices[i][0], dy: vertices[i][1], size: size, bounds: modelBounds)
                    path.addLine(to: p)
                }
                if ent.closed == true {
                    path.closeSubpath()
                }
                context.stroke(path, with: .color(strokeColor), style: strokeStyle)
            }
        }
    }

    private func drawMeasurement(_ measure: MeasurementLine, isSelected: Bool, isHovered: Bool, size: CGSize, modelBounds: CGRect, context: inout GraphicsContext) {
        let startScreen = toScreen(dx: measure.start.x, dy: measure.start.y, size: size, bounds: modelBounds)
        let endScreen = toScreen(dx: measure.end.x, dy: measure.end.y, size: size, bounds: modelBounds)

        // Parametric dimensions render proper CAD anatomy: extension lines with a
        // small gap, an offset dimension line with solid arrowheads, and the
        // parameter label (fx: for formulas, (parens) for driven) (MAS-110 §2/§3).
        if measure.isParametric {
            drawParametricDimension(measure, startScreen: startScreen, endScreen: endScreen,
                                    isSelected: isSelected, isHovered: isHovered, context: &context)
            return
        }

        var mPath = SwiftUI.Path()
        mPath.move(to: startScreen)
        mPath.addLine(to: endScreen)
        
        let color: Color
        let strokeStyle: StrokeStyle
        
        if isSelected {
            color = Color.white // Selected highlight
            strokeStyle = StrokeStyle(lineWidth: 2.5, lineCap: .round)
        } else if isHovered {
            color = Color.accent_hover // Hover highlight
            strokeStyle = StrokeStyle(lineWidth: 2.0, lineCap: .round)
        } else if measure.isAutoDimension {
            color = Color.cyan // Auto dimension (Solid)
            strokeStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round)
        } else {
            color = Color.orange // Manual measurement (Dotted)
            strokeStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4])
        }
        
        context.stroke(mPath, with: .color(color), style: strokeStyle)

        if measure.isAutoDimension {
            // CAD-style perpendicular witness ticks instead of round handles —
            // auto-dimensions belong to their shape and aren't draggable (MAS-61).
            let dx = endScreen.x - startScreen.x
            let dy = endScreen.y - startScreen.y
            let len = max(hypot(dx, dy), 0.0001)
            let perp = CGPoint(x: -dy / len, y: dx / len)
            let tickHalf: CGFloat = 5.0
            let tickStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round)
            for p in [startScreen, endScreen] {
                var tick = SwiftUI.Path()
                tick.move(to: CGPoint(x: p.x - perp.x * tickHalf, y: p.y - perp.y * tickHalf))
                tick.addLine(to: CGPoint(x: p.x + perp.x * tickHalf, y: p.y + perp.y * tickHalf))
                context.stroke(tick, with: .color(color), style: tickStyle)
            }
        } else {
            // Manual measurements keep round handles — they are the grab targets
            // for precise endpoint dragging (MAS-78).
            var dot1 = SwiftUI.Path()
            dot1.addEllipse(in: CGRect(x: startScreen.x - 4, y: startScreen.y - 4, width: 8, height: 8))
            context.fill(dot1, with: .color(color))

            var dot2 = SwiftUI.Path()
            dot2.addEllipse(in: CGRect(x: endScreen.x - 4, y: endScreen.y - 4, width: 8, height: 8))
            context.fill(dot2, with: .color(color))
        }
        
        let midScreen = CGPoint(
            x: (startScreen.x + endScreen.x) / 2,
            y: (startScreen.y + endScreen.y) / 2
        )
        let labelText = String(format: "%.2f mm", measure.distanceMm)
        context.draw(
            Text(labelText)
                .font(.system(size: 10, weight: isSelected ? .black : .bold))
                .foregroundColor(color),
            at: CGPoint(x: midScreen.x, y: midScreen.y - 10),
            anchor: .center
        )
    }

    /// Renders a parametric dimension's anatomy in screen space (MAS-110 §2/§3).
    private func drawParametricDimension(_ measure: MeasurementLine, startScreen: CGPoint, endScreen: CGPoint,
                                         isSelected: Bool, isHovered: Bool, context: inout GraphicsContext) {
        let color: Color = isSelected ? Color.white
            : (isHovered ? Color.accent_hover : (measure.driven ? Color.text_secondary : Color.text_primary))
        let lineW: CGFloat = isSelected ? 2.0 : 1.4
        let label = DimensionEngine.label(value: measure.distanceMm,
                                          expression: measure.expression ?? "",
                                          driven: measure.driven)

        // Radius dimension → leader from center to edge with an arrowhead + R label.
        if measure.dimensionType == "radius" {
            var leader = SwiftUI.Path()
            leader.move(to: startScreen)
            leader.addLine(to: endScreen)
            context.stroke(leader, with: .color(color), style: StrokeStyle(lineWidth: lineW, lineCap: .round))
            drawArrowhead(at: endScreen, towards: startScreen, color: color, context: &context)
            context.draw(Text("R \(label)").font(.system(size: 10, weight: .bold)).foregroundColor(color),
                         at: CGPoint(x: endScreen.x + 6, y: endScreen.y - 12), anchor: .leading)
            return
        }

        // Linear: extension lines + an offset dimension line with arrowheads.
        let dx = endScreen.x - startScreen.x, dy = endScreen.y - startScreen.y
        let len = max(hypot(dx, dy), 0.0001)
        let perp = CGPoint(x: -dy / len, y: dx / len)
        let off = CGFloat(measure.offsetDistance) * state.canvasScale
        let gap: CGFloat = 4.0          // gap from geometry to extension line (≈1–2mm)
        let overshoot: CGFloat = 6.0    // extension line past the dimension line

        let a0 = startScreen, b0 = endScreen
        let a1 = CGPoint(x: a0.x + perp.x * off, y: a0.y + perp.y * off)
        let b1 = CGPoint(x: b0.x + perp.x * off, y: b0.y + perp.y * off)

        if abs(off) > 0.5 {
            for (p0, p1) in [(a0, a1), (b0, b1)] {
                let s = CGPoint(x: p0.x + perp.x * gap, y: p0.y + perp.y * gap)
                let e = CGPoint(x: p1.x + perp.x * overshoot, y: p1.y + perp.y * overshoot)
                var ext = SwiftUI.Path(); ext.move(to: s); ext.addLine(to: e)
                context.stroke(ext, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1.0))
            }
        }

        var dim = SwiftUI.Path(); dim.move(to: a1); dim.addLine(to: b1)
        context.stroke(dim, with: .color(color), style: StrokeStyle(lineWidth: lineW, lineCap: .round))
        drawArrowhead(at: a1, towards: b1, color: color, context: &context)
        drawArrowhead(at: b1, towards: a1, color: color, context: &context)

        let mid = CGPoint(x: (a1.x + b1.x) / 2, y: (a1.y + b1.y) / 2)
        context.draw(Text(label).font(.system(size: 10, weight: isSelected ? .black : .bold)).foregroundColor(color),
                     at: CGPoint(x: mid.x + perp.x * 9, y: mid.y + perp.y * 9 - 2), anchor: .center)
    }

    /// Draws the patterning ghost preview + instance-count pills (MAS-113).
    private func drawPatterningGhost(size: CGSize, modelBounds: CGRect, context: inout GraphicsContext) {
        let selected = state.entities.filter { state.selectedHandles.contains($0.handle) }
        guard !selected.isEmpty, let bbox = state.selectionBBox else { return }
        let ghost = Color.accent.opacity(0.55)
        let dashed = StrokeStyle(lineWidth: 1.0, dash: [4, 3])

        func drawGhostInstance(translate: CGSize, rotate: Double, pivotScreen: CGPoint?) {
            context.drawLayer { ctx in
                ctx.translateBy(x: translate.width, y: translate.height)
                if rotate != 0, let ps = pivotScreen {
                    ctx.translateBy(x: ps.x, y: ps.y)
                    ctx.rotate(by: Angle(degrees: rotate))
                    ctx.translateBy(x: -ps.x, y: -ps.y)
                }
                for ent in selected {
                    drawEntity(ent, baseColor: ghost, strokeColor: ghost, strokeWidth: 1.0,
                               size: size, modelBounds: modelBounds, context: &ctx)
                }
            }
        }

        if state.patternMode == "rectangular" {
            let nx = max(1, state.patternCountX), ny = max(1, state.patternCountY)
            let sx = state.effectivePatternSpacingX * Double(state.canvasScale)
            // Screen Y is inverted relative to model Y, so a +Y model step moves up.
            let sy = -state.effectivePatternSpacingY * Double(state.canvasScale)
            for i in 0..<nx {
                for j in 0..<ny {
                    if i == 0 && j == 0 { continue }
                    drawGhostInstance(translate: CGSize(width: Double(i) * sx, height: Double(j) * sy),
                                      rotate: 0, pivotScreen: nil)
                }
            }
            // Count pill near the far corner.
            let corner = toScreen(dx: bbox.maxX, dy: bbox.maxY, size: size, bounds: modelBounds)
            context.draw(Text("\(nx) × \(ny)").font(.system(size: 11, weight: .bold)).foregroundColor(Color.accent),
                         at: CGPoint(x: corner.x + Double(nx) * sx + 12, y: corner.y + Double(ny) * sy - 8), anchor: .leading)
        } else if state.patternMode == "circular" {
            let count = max(2, state.patternCircCount)
            let pivot = state.patternPivotModel ?? CGPoint(x: bbox.midX, y: bbox.midY)
            let pivotScreen = toScreen(dx: Double(pivot.x), dy: Double(pivot.y), size: size, bounds: modelBounds)
            let full = abs(state.patternCircAngle.truncatingRemainder(dividingBy: 360.0)) < 1e-6 && abs(state.patternCircAngle) >= 1e-6
            let denom = full ? Double(count) : Double(max(1, count - 1))
            let step = state.patternCircAngle / denom
            for k in 1..<count {
                // Model CCW (+angle) maps to screen CW under the flipped Y, which is
                // exactly what context.rotate(by: +angle) does — so match the sign.
                drawGhostInstance(translate: .zero, rotate: step * Double(k), pivotScreen: pivotScreen)
            }
            // Pivot ring guide + count pill.
            var ring = SwiftUI.Path()
            let r = hypot(toScreen(dx: bbox.maxX, dy: bbox.maxY, size: size, bounds: modelBounds).x - pivotScreen.x,
                          toScreen(dx: bbox.maxX, dy: bbox.maxY, size: size, bounds: modelBounds).y - pivotScreen.y)
            ring.addEllipse(in: CGRect(x: pivotScreen.x - r, y: pivotScreen.y - r, width: r * 2, height: r * 2))
            context.stroke(ring, with: .color(Color.accent.opacity(0.3)), style: dashed)
            context.draw(Text("×\(count)").font(.system(size: 11, weight: .bold)).foregroundColor(Color.accent),
                         at: CGPoint(x: pivotScreen.x, y: pivotScreen.y - r - 12), anchor: .center)
        } else if state.patternMode == "path" {
            if let pathHandle = state.patternPathHandle,
               let pathEnt = state.entities.first(where: { $0.handle == pathHandle }) {
                
                let pathPts = flattenEntityToPoints(pathEnt)
                if pathPts.count >= 2 {
                    var lengths: [Double] = [0.0]
                    for i in 1..<pathPts.count {
                        let prev = pathPts[i-1]
                        let curr = pathPts[i]
                        let dist = Double(hypot(curr.x - prev.x, curr.y - prev.y))
                        lengths.append(lengths[i-1] + dist)
                    }
                    
                    if let totalLength = lengths.last, totalLength > 1e-6 {
                        let spacing = max(1.0, state.patternPathSpacing)
                        let numInstances = max(1, Int(totalLength / spacing))
                        
                        var offsets = (0...numInstances).map { Double($0) * spacing }
                        if pathEnt.closed == true, !offsets.isEmpty {
                            offsets.removeLast()
                        }
                        
                        var allPts: [CGPoint] = []
                        for ent in selected {
                            allPts.append(contentsOf: flattenEntityToPoints(ent))
                        }
                        if !allPts.isEmpty {
                            let cx = allPts.map { $0.x }.reduce(0, +) / CGFloat(allPts.count)
                            let cy = allPts.map { $0.y }.reduce(0, +) / CGFloat(allPts.count)
                            let selectionCenter = CGPoint(x: cx, y: cy)
                            
                            func drawGhostInstanceAlongPath(targetPt: CGPoint, targetAngle: Double) {
                                context.drawLayer { ctx in
                                    let tScreen = toScreen(dx: Double(targetPt.x), dy: Double(targetPt.y), size: size, bounds: modelBounds)
                                    let cScreen = toScreen(dx: Double(selectionCenter.x), dy: Double(selectionCenter.y), size: size, bounds: modelBounds)
                                    
                                    ctx.translateBy(x: tScreen.x - cScreen.x, y: tScreen.y - cScreen.y)
                                    
                                    ctx.translateBy(x: tScreen.x, y: tScreen.y)
                                    ctx.rotate(by: Angle(radians: targetAngle))
                                    ctx.translateBy(x: -tScreen.x, y: -tScreen.y)
                                    
                                    for ent in selected {
                                        drawEntity(ent, baseColor: ghost, strokeColor: ghost, strokeWidth: 1.0,
                                                   size: size, modelBounds: modelBounds, context: &ctx)
                                    }
                                }
                            }
                            
                            for offset in offsets {
                                if let interp = interpolateOnPath(pts: pathPts, lengths: lengths, offset: offset) {
                                    drawGhostInstanceAlongPath(targetPt: interp.point, targetAngle: interp.angle)
                                }
                            }
                            
                            // Count pill near guide path start
                            let startScreen = toScreen(dx: Double(pathPts[0].x), dy: Double(pathPts[0].y), size: size, bounds: modelBounds)
                            context.draw(Text("×\(offsets.count)").font(.system(size: 11, weight: .bold)).foregroundColor(Color.accent),
                                         at: CGPoint(x: startScreen.x + 12, y: startScreen.y - 12), anchor: .leading)
                        }
                    }
                }
            }
        }
    }

    private func flattenEntityToPoints(_ ent: DXFEntity) -> [CGPoint] {
        if ent.type == "LINE", let s = ent.start, let e = ent.end {
            return [CGPoint(x: s[0], y: s[1]), CGPoint(x: e[0], y: e[1])]
        } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
            let cx = center[0], cy = center[1], r = radius
            var pts: [CGPoint] = []
            let steps = 72
            for i in 0...steps {
                let a = Double(i) * 2.0 * .pi / Double(steps)
                pts.append(CGPoint(x: cx + r * cos(a), y: cy + r * sin(a)))
            }
            return pts
        } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius,
                  let sa = ent.start_angle, let ea = ent.end_angle {
            let cx = center[0], cy = center[1], r = radius
            var pts: [CGPoint] = []
            let steps = 36
            var diff = ea - sa
            if diff < 0 { diff += 360 }
            for i in 0...steps {
                let deg = sa + diff * Double(i) / Double(steps)
                let rad = deg * .pi / 180.0
                pts.append(CGPoint(x: cx + r * cos(rad), y: cy + r * sin(rad)))
            }
            return pts
        } else if let vertices = ent.vertices, vertices.count >= 2 {
            var pts = vertices.map { CGPoint(x: $0[0], y: $0[1]) }
            if ent.closed == true {
                pts.append(pts[0])
            }
            return pts
        }
        return []
    }

    private func interpolateOnPath(pts: [CGPoint], lengths: [Double], offset: Double) -> (point: CGPoint, angle: Double)? {
        guard pts.count >= 2, lengths.count == pts.count, let totalLength = lengths.last, totalLength > 1e-6 else { return nil }
        
        let target = max(0.0, min(totalLength, offset))
        
        var idx = 0
        for i in 0..<(lengths.count - 1) {
            if target >= lengths[i] && target <= lengths[i+1] {
                idx = i
                break
            }
        }
        
        let p0 = pts[idx]
        let p1 = pts[idx + 1]
        let segLen = lengths[idx + 1] - lengths[idx]
        guard segLen > 1e-6 else { return (p0, 0.0) }
        
        let t = (target - lengths[idx]) / segLen
        let x = p0.x + t * (p1.x - p0.x)
        let y = p0.y + t * (p1.y - p0.y)
        
        let angle = Double(atan2(p1.y - p0.y, p1.x - p0.x))
        
        return (CGPoint(x: x, y: y), angle)
    }

    /// Vertices of a regular polygon (MAS-118): `sides` points on a circle of
    /// `radius` about `center`, with the first vertex at angle `rotation`.
    /// When snapping is on, snap a polygon's orientation to its natural rotational
    /// increment (360° / sides) so it lands on "straight" angles instead of any
    /// arbitrary tilt the cursor produces (MAS-157).
    private func snappedPolygonRotation(_ rot: Double, sides: Int) -> Double {
        guard state.snapActive, sides >= 3 else { return rot }
        let inc = (2.0 * Double.pi) / Double(sides)
        return (rot / inc).rounded() * inc
    }

    private func polygonPoints(center: CGPoint, radius: Double, rotation: Double, sides: Int) -> [CGPoint] {
        let n = max(3, min(64, sides))
        guard radius > 1e-6 else { return [] }
        return (0..<n).map { i in
            let a = rotation + Double(i) * (2.0 * Double.pi / Double(n))
            return CGPoint(x: center.x + CGFloat(radius * cos(a)), y: center.y + CGFloat(radius * sin(a)))
        }
    }

    /// Draws a small solid arrowhead at `tip` pointing from `from` → `tip`.
    private func drawArrowhead(at tip: CGPoint, towards from: CGPoint, color: Color, context: inout GraphicsContext) {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let len = max(hypot(dx, dy), 0.0001)
        let ux = dx / len, uy = dy / len
        let size: CGFloat = 7.0, wide: CGFloat = 2.6
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let perp = CGPoint(x: -uy, y: ux)
        var head = SwiftUI.Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x + perp.x * wide, y: base.y + perp.y * wide))
        head.addLine(to: CGPoint(x: base.x - perp.x * wide, y: base.y - perp.y * wide))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

// Mouse coordinates tracker modifier
private struct MouseTrackerModifier: ViewModifier {
    @Binding var mouseLocation: CGPoint
    @Binding var hoverCoords: CGPoint?
    let size: CGSize
    let bounds: CGRect
    let scale: CGFloat
    let offset: CGSize
    
    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    self.mouseLocation = point
                    let dx = (point.x - size.width / 2 - offset.width) / scale
                    let dy = -(point.y - size.height / 2 - offset.height) / scale
                    self.hoverCoords = CGPoint(x: dx, y: dy)
                case .ended:
                    self.hoverCoords = nil
                }
            }
    }
}

// Scroll Wheel NSView representable wrapper
struct ScrollWheelModifier: NSViewRepresentable {
    var onZoom: (NSEvent, CGPoint, CGFloat) -> Void
    var onPanOffset: (CGSize) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onDeleteSelected: () -> Void
    var onRightClick: (CGPoint) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        let view = ScrollEventView()
        view.onZoom = onZoom
        view.onPanOffset = onPanOffset
        view.onMagnify = onMagnify
        view.onDeleteSelected = onDeleteSelected
        view.onRightClick = onRightClick
        // Trackpad pinch-zoom (MAS-50). A gesture recognizer is the reliable
        // path: once the pinch begins it tracks the whole gesture, so it isn't
        // dropped the way the magnify(with:) responder method can be when the
        // overlay's hitTest passes the pre-gesture hover (mouseMoved) through to
        // the canvas underneath.
        let pinch = NSMagnificationGestureRecognizer(
            target: view, action: #selector(ScrollEventView.handleMagnify(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    class ScrollEventView: NSView {
        var onZoom: ((NSEvent, CGPoint, CGFloat) -> Void)?
        var onPanOffset: ((CGSize) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onDeleteSelected: (() -> Void)?
        var onRightClick: ((CGPoint) -> Void)?

        private var dragStartPoint: NSPoint?
        // Cumulative magnification of the in-flight pinch, so we can feed the
        // per-event delta to onMagnify (which expects an incremental factor).
        private var lastMagnification: CGFloat = 0

        override var acceptsFirstResponder: Bool { true }

        /// Trackpad pinch handler (MAS-50). `recognizer.magnification` is
        /// cumulative over the gesture and resets to 0 at `.began`, so we send
        /// the frame-to-frame delta — matching the zoomFactor = 1 + delta math
        /// in the onMagnify closure.
        @objc func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastMagnification = recognizer.magnification
            case .changed:
                let delta = recognizer.magnification - lastMagnification
                lastMagnification = recognizer.magnification
                let pt = recognizer.location(in: self)
                let swiftUiPt = CGPoint(x: pt.x, y: bounds.height - pt.y)
                onMagnify?(delta, swiftUiPt)
            default:
                break
            }
        }
        
        override func scrollWheel(with event: NSEvent) {
            let localPt = convert(event.locationInWindow, from: nil)
            let swiftUiPt = CGPoint(x: localPt.x, y: bounds.height - localPt.y)
            
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                let zoomFactor: CGFloat = event.scrollingDeltaY > 0 ? 1.05 : 0.95
                onZoom?(event, swiftUiPt, zoomFactor)
            } else if event.hasPreciseScrollingDeltas {
                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                // Invert touchpad vertical scroll direction for Pan gesture
                onPanOffset?(CGSize(width: dx, height: dy))
            } else {
                let zoomFactor: CGFloat = event.deltaY > 0 ? 1.15 : 0.85
                onZoom?(event, swiftUiPt, zoomFactor)
            }
        }
        
        override func keyDown(with event: NSEvent) {
            // Delete Keycode 51, Forward Delete keycode 117
            if event.keyCode == 51 || event.keyCode == 117 {
                onDeleteSelected?()
            } else {
                super.keyDown(with: event)
            }
        }
        
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent {
                switch event.type {
                case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved, .mouseEntered, .mouseExited:
                    // Pass clicks and hovers through to the SwiftUI canvas below.
                    return nil
                case .scrollWheel, .magnify, .smartMagnify, .beginGesture, .endGesture, .gesture:
                    // Zoom/pan gestures must land on this overlay (MAS-50).
                    return self
                default:
                    break
                }
            }
            return super.hitTest(point)
        }
        
        private func startDrag(with event: NSEvent) {
            dragStartPoint = event.locationInWindow
        }
        
        private func drag(with event: NSEvent) {
            guard let start = dragStartPoint else { return }
            let current = event.locationInWindow
            let dx = current.x - start.x
            let dy = current.y - start.y
            onPanOffset?(CGSize(width: dx, height: dy))
            dragStartPoint = current
        }
        
        private func endDrag(with event: NSEvent) {
            dragStartPoint = nil
        }
        
        private var rightDownPoint: NSPoint?
        private var rightDidDrag = false

        override func rightMouseDown(with event: NSEvent) {
            rightDownPoint = event.locationInWindow
            rightDidDrag = false
            startDrag(with: event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            if let dp = rightDownPoint {
                let cur = event.locationInWindow
                if hypot(cur.x - dp.x, cur.y - dp.y) > 4 { rightDidDrag = true }
            }
            drag(with: event)
        }

        override func rightMouseUp(with event: NSEvent) {
            endDrag(with: event)
            // A right-click that didn't pan opens the context menu (MAS-62).
            if !rightDidDrag {
                let localPt = convert(event.locationInWindow, from: nil)
                onRightClick?(CGPoint(x: localPt.x, y: bounds.height - localPt.y))
            }
            rightDownPoint = nil
        }
        
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 {
                startDrag(with: event)
            }
        }
        
        override func otherMouseDragged(with event: NSEvent) {
            if event.buttonNumber == 2 {
                drag(with: event)
            }
        }
        
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 {
                endDrag(with: event)
            }
        }
    }
}

extension DxfCanvasView {
    // MARK: - Group 9 Layer-based Reference Image Helpers
    
    private func transformImagePoint(_ pt: CGPoint, w: Double, h: Double, offset: CGPoint, scaleX: Double, scaleY: Double, rotation: Double) -> CGPoint {
        let x1 = pt.x - w / 2
        let y1 = pt.y - h / 2
        let x2 = x1 * scaleX
        let y2 = y1 * scaleY
        let rad = rotation * .pi / 180.0
        let cosR = cos(rad)
        let sinR = sin(rad)
        let x3 = x2 * cosR - y2 * sinR
        let y3 = x2 * sinR + y2 * cosR
        return CGPoint(x: offset.x + x3, y: offset.y + y3)
    }

    @ViewBuilder
    private func drawReferenceImage(_ img: NSImage, for layer: DXFLayer, size: CGSize, bounds: CGRect) -> some View {
        let imgWidth = CGFloat(layer.refImageWidth) * CGFloat(layer.refImageScaleX) * state.canvasScale
        let imgHeight = CGFloat(layer.refImageHeight) * CGFloat(layer.refImageScaleY) * state.canvasScale
        
        let screenCenter = toScreen(dx: layer.refImageOffsetX, dy: layer.refImageOffsetY, size: size, bounds: bounds)
        
        Image(nsImage: img)
            .resizable()
            .frame(width: imgWidth, height: imgHeight)
            .rotationEffect(Angle(degrees: -layer.refImageRotation))
            .opacity(layer.refImageOpacity)
            .position(screenCenter)
            .allowsHitTesting(false)
    }

    private func drawTracePreview(_ context: inout GraphicsContext, size: CGSize, modelBounds: CGRect, layer: DXFLayer) {
        let w = layer.refImageWidth
        let h = layer.refImageHeight
        let scaleX = layer.refImageScaleX
        let scaleY = layer.refImageScaleY
        let rot = layer.refImageRotation
        let offset = CGPoint(x: layer.refImageOffsetX, y: layer.refImageOffsetY)
        
        let pixelW = layer.refImagePixelWidth > 0 ? layer.refImagePixelWidth : w
        let pixelH = layer.refImagePixelHeight > 0 ? layer.refImagePixelHeight : h
        
        for ent in state.tracePreviewEntities {
            guard let vertices = ent.vertices, vertices.count >= 2 else { continue }
            var path = SwiftUI.Path()
            let firstPt = CGPoint(
                x: vertices[0][0] * (w / pixelW),
                y: vertices[0][1] * (h / pixelH)
            )
            let firstTransformed = transformImagePoint(firstPt, w: w, h: h, offset: offset, scaleX: scaleX, scaleY: scaleY, rotation: rot)
            path.move(to: toScreen(dx: firstTransformed.x, dy: firstTransformed.y, size: size, bounds: modelBounds))
            
            for v in vertices.dropFirst() {
                guard v.count >= 2 else { continue }
                let pt = CGPoint(
                    x: v[0] * (w / pixelW),
                    y: v[1] * (h / pixelH)
                )
                let transformed = transformImagePoint(pt, w: w, h: h, offset: offset, scaleX: scaleX, scaleY: scaleY, rotation: rot)
                path.addLine(to: toScreen(dx: transformed.x, dy: transformed.y, size: size, bounds: modelBounds))
            }
            
            if ent.closed ?? true {
                path.closeSubpath()
            }
            context.stroke(path, with: .color(Color(red: 0.0, green: 1.0, blue: 1.0)), lineWidth: 1.5)
        }
    }

    private func getScreenPoints(for layer: DXFLayer, size: CGSize, bounds: CGRect) -> [String: CGPoint] {
        let w = layer.refImageWidth
        let h = layer.refImageHeight
        let scaleX = layer.refImageScaleX
        let scaleY = layer.refImageScaleY
        let rot = layer.refImageRotation
        let offset = CGPoint(x: layer.refImageOffsetX, y: layer.refImageOffsetY)
        
        let localCoords: [String: CGPoint] = [
            "tl": CGPoint(x: -w/2, y: h/2),
            "tr": CGPoint(x: w/2, y: h/2),
            "bl": CGPoint(x: -w/2, y: -h/2),
            "br": CGPoint(x: w/2, y: -h/2),
            "t": CGPoint(x: 0, y: h/2),
            "b": CGPoint(x: 0, y: -h/2),
            "l": CGPoint(x: -w/2, y: 0),
            "r": CGPoint(x: w/2, y: 0),
            "c": CGPoint(x: 0, y: 0)
        ]
        
        var screenCoords: [String: CGPoint] = [:]
        for (name, pt) in localCoords {
            let x2 = pt.x * scaleX
            let y2 = pt.y * scaleY
            let rad = rot * .pi / 180.0
            let cosR = cos(rad)
            let sinR = sin(rad)
            let x3 = x2 * cosR - y2 * sinR
            let y3 = x2 * sinR + y2 * cosR
            let modelPt = CGPoint(x: offset.x + x3, y: offset.y + y3)
            screenCoords[name] = toScreen(dx: Double(modelPt.x), dy: Double(modelPt.y), size: size, bounds: bounds)
        }
        
        // Calculate rotation handle position: 30 pixels straight up from top center
        let rad = rot * .pi / 180.0
        let cosR = cos(rad)
        let sinR = sin(rad)
        
        let tcX2 = 0.0
        let tcY2 = (h / 2 + 30.0 / scaleY) * scaleY
        let rotX3 = tcX2 * cosR - tcY2 * sinR
        let rotY3 = tcX2 * sinR + tcY2 * cosR
        let rotModelPt = CGPoint(x: offset.x + rotX3, y: offset.y + rotY3)
        screenCoords["rot"] = toScreen(dx: Double(rotModelPt.x), dy: Double(rotModelPt.y), size: size, bounds: bounds)
        
        return screenCoords
    }

    private func isPointInsideImage(pt: CGPoint, layer: DXFLayer, size: CGSize, bounds: CGRect) -> Bool {
        let cursorModel = toModel(point: pt, size: size, bounds: bounds)
        let V = CGPoint(x: cursorModel.x - layer.refImageOffsetX, y: cursorModel.y - layer.refImageOffsetY)
        let rad = -layer.refImageRotation * .pi / 180.0
        let V_local = CGPoint(
            x: V.x * cos(rad) - V.y * sin(rad),
            y: V.x * sin(rad) + V.y * cos(rad)
        )
        let half_w = (layer.refImageWidth / 2) * layer.refImageScaleX
        let half_h = (layer.refImageHeight / 2) * layer.refImageScaleY
        return V_local.x >= -half_w && V_local.x <= half_w && V_local.y >= -half_h && V_local.y <= half_h
    }

    private func handleRefImageDragChanged(val: DragGesture.Value, layer: DXFLayer, size: CGSize, modelBounds: CGRect) {
        if refImageDragStartLocation == nil {
            let pts = getScreenPoints(for: layer, size: size, bounds: modelBounds)
            let startPt = val.startLocation
            
            if hypot(startPt.x - pts["rot"]!.x, startPt.y - pts["rot"]!.y) <= 12.0 {
                activeRefImageHandle = "rot"
            } else if hypot(startPt.x - pts["tl"]!.x, startPt.y - pts["tl"]!.y) <= 10.0 {
                activeRefImageHandle = "tl"
            } else if hypot(startPt.x - pts["tr"]!.x, startPt.y - pts["tr"]!.y) <= 10.0 {
                activeRefImageHandle = "tr"
            } else if hypot(startPt.x - pts["bl"]!.x, startPt.y - pts["bl"]!.y) <= 10.0 {
                activeRefImageHandle = "bl"
            } else if hypot(startPt.x - pts["br"]!.x, startPt.y - pts["br"]!.y) <= 10.0 {
                activeRefImageHandle = "br"
            } else if hypot(startPt.x - pts["t"]!.x, startPt.y - pts["t"]!.y) <= 10.0 {
                activeRefImageHandle = "t"
            } else if hypot(startPt.x - pts["b"]!.x, startPt.y - pts["b"]!.y) <= 10.0 {
                activeRefImageHandle = "b"
            } else if hypot(startPt.x - pts["l"]!.x, startPt.y - pts["l"]!.y) <= 10.0 {
                activeRefImageHandle = "l"
            } else if hypot(startPt.x - pts["r"]!.x, startPt.y - pts["r"]!.y) <= 10.0 {
                activeRefImageHandle = "r"
            } else if hypot(startPt.x - pts["c"]!.x, startPt.y - pts["c"]!.y) <= 12.0 {
                activeRefImageHandle = "c"
            } else if isPointInsideImage(pt: startPt, layer: layer, size: size, bounds: modelBounds) {
                activeRefImageHandle = "c"
            } else {
                activeRefImageHandle = "outside"
            }
            
            refImageDragStartLocation = startPt
            refImageDragStartOffsetX = layer.refImageOffsetX
            refImageDragStartOffsetY = layer.refImageOffsetY
            refImageDragStartScaleX = layer.refImageScaleX
            refImageDragStartScaleY = layer.refImageScaleY
            refImageDragStartRotation = layer.refImageRotation
            refImageDragStartAngle = nil
        }
        
        guard let handle = activeRefImageHandle, handle != "outside" else { return }
        
        let startLoc = refImageDragStartLocation!
        let scale = Double(state.canvasScale)
        
        if handle == "c" {
            let deltaX = (val.location.x - startLoc.x) / CGFloat(scale)
            let deltaY = -(val.location.y - startLoc.y) / CGFloat(scale)
            state.updateActiveLayerTransform(
                offsetX: refImageDragStartOffsetX + Double(deltaX),
                offsetY: refImageDragStartOffsetY + Double(deltaY)
            )
        } else if handle == "rot" {
            let pts = getScreenPoints(for: layer, size: size, bounds: modelBounds)
            let centerScreen = pts["c"]!
            let cur = atan2(Double(val.location.x - centerScreen.x),
                            Double(-(val.location.y - centerScreen.y))) * 180.0 / .pi
            if refImageDragStartAngle == nil {
                refImageDragStartAngle = cur
            }
            let deltaAngle = cur - (refImageDragStartAngle ?? cur)
            state.updateActiveLayerTransform(
                rotation: refImageDragStartRotation - deltaAngle
            )
        } else if ["tl", "tr", "bl", "br"].contains(handle) {
            let centerModel = CGPoint(x: layer.refImageOffsetX, y: layer.refImageOffsetY)
            let cursorModel = toModel(point: val.location, size: size, bounds: modelBounds)
            let V = CGPoint(x: cursorModel.x - centerModel.x, y: cursorModel.y - centerModel.y)
            let rad = -refImageDragStartRotation * .pi / 180.0
            let V_local = CGPoint(
                x: V.x * cos(rad) - V.y * sin(rad),
                y: V.x * sin(rad) + V.y * cos(rad)
            )
            
            let original_half_w = (layer.refImageWidth / 2) * refImageDragStartScaleX
            let original_half_h = (layer.refImageHeight / 2) * refImageDragStartScaleY
            let original_dist = sqrt(original_half_w * original_half_w + original_half_h * original_half_h)
            let current_dist = sqrt(V_local.x * V_local.x + V_local.y * V_local.y)
            
            let ratio = original_dist > 0.1 ? current_dist / original_dist : 1.0
            state.updateActiveLayerTransform(
                scaleX: refImageDragStartScaleX * ratio,
                scaleY: refImageDragStartScaleY * ratio
            )
        } else {
            let cursorModel = toModel(point: val.location, size: size, bounds: modelBounds)
            let V = CGPoint(x: cursorModel.x - layer.refImageOffsetX, y: cursorModel.y - layer.refImageOffsetY)
            let rad = -refImageDragStartRotation * .pi / 180.0
            let V_local = CGPoint(
                x: V.x * cos(rad) - V.y * sin(rad),
                y: V.x * sin(rad) + V.y * cos(rad)
            )
            
            let half_w = layer.refImageWidth / 2
            let half_h = layer.refImageHeight / 2
            
            if handle == "r" && half_w > 0.1 {
                var newScaleX = V_local.x / half_w
                if newScaleX < 0.01 { newScaleX = 0.01 }
                
                if NSEvent.modifierFlags.contains(.shift) {
                    let ratio = newScaleX / refImageDragStartScaleX
                    state.updateActiveLayerTransform(
                        scaleX: newScaleX,
                        scaleY: refImageDragStartScaleY * ratio
                    )
                } else {
                    state.updateActiveLayerTransform(scaleX: newScaleX)
                }
            } else if handle == "l" && half_w > 0.1 {
                var newScaleX = -V_local.x / half_w
                if newScaleX < 0.01 { newScaleX = 0.01 }
                
                if NSEvent.modifierFlags.contains(.shift) {
                    let ratio = newScaleX / refImageDragStartScaleX
                    state.updateActiveLayerTransform(
                        scaleX: newScaleX,
                        scaleY: refImageDragStartScaleY * ratio
                    )
                } else {
                    state.updateActiveLayerTransform(scaleX: newScaleX)
                }
            } else if handle == "t" && half_h > 0.1 {
                var newScaleY = V_local.y / half_h
                if newScaleY < 0.01 { newScaleY = 0.01 }
                
                if NSEvent.modifierFlags.contains(.shift) {
                    let ratio = newScaleY / refImageDragStartScaleY
                    state.updateActiveLayerTransform(
                        scaleX: refImageDragStartScaleX * ratio,
                        scaleY: newScaleY
                    )
                } else {
                    state.updateActiveLayerTransform(scaleY: newScaleY)
                }
            } else if handle == "b" && half_h > 0.1 {
                var newScaleY = -V_local.y / half_h
                if newScaleY < 0.01 { newScaleY = 0.01 }
                
                if NSEvent.modifierFlags.contains(.shift) {
                    let ratio = newScaleY / refImageDragStartScaleY
                    state.updateActiveLayerTransform(
                        scaleX: refImageDragStartScaleX * ratio,
                        scaleY: newScaleY
                    )
                } else {
                    state.updateActiveLayerTransform(scaleY: newScaleY)
                }
            }
        }
    }

    private func handleRefImageDragEnded(val: DragGesture.Value, layer: DXFLayer, size: CGSize, modelBounds: CGRect) {
        if activeRefImageHandle == "outside" {
            state.isEditingRefImageTransform = false
        }
        activeRefImageHandle = nil
        refImageDragStartLocation = nil
        refImageDragStartAngle = nil
    }

    @ViewBuilder
    private func referenceImageGizmoOverlay(size viewSize: CGSize, modelBounds: CGRect, layer: DXFLayer) -> some View {
        let pts = getScreenPoints(for: layer, size: viewSize, bounds: modelBounds)
        
        ZStack {
            Path { p in
                p.move(to: pts["tl"]!)
                p.addLine(to: pts["tr"]!)
                p.addLine(to: pts["br"]!)
                p.addLine(to: pts["bl"]!)
                p.closeSubpath()
            }
            .stroke(Color.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 4]))
            
            Path { p in
                p.move(to: pts["t"]!)
                p.addLine(to: pts["rot"]!)
            }
            .stroke(Color.accent, lineWidth: 1.5)
            
            Circle()
                .fill(Color.accent)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(radius: 2)
                .position(pts["rot"]!)
            
            Circle()
                .fill(Color.yellow)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                .shadow(radius: 2)
                .position(pts["c"]!)
            
            ForEach(["tl", "tr", "bl", "br"], id: \.self) { handle in
                if let pt = pts[handle] {
                    Rectangle()
                        .fill(Color.accent)
                        .frame(width: 10, height: 10)
                        .overlay(Rectangle().stroke(Color.white, lineWidth: 1.5))
                        .shadow(radius: 1)
                        .position(pt)
                }
            }
            
            ForEach(["t", "b", "l", "r"], id: \.self) { handle in
                if let pt = pts[handle] {
                    Circle()
                        .fill(Color.accent)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .shadow(radius: 1)
                        .position(pt)
                }
            }
        }
    }
}

// Custom view cursors
extension View {
    func cursorStyle(_ tool: TwoDTool) -> some View {
        switch tool {
        case .pan:
            return self.onHover { isHovered in
                if isHovered { NSCursor.openHand.set() }
                else { NSCursor.arrow.set() }
            }
        case .select, .move, .offset, .addThickness, .addHoles, .cleanup, .measure, .dimension, .scale, .sketchLine, .sketchCircle, .sketchRectangle, .sketchText, .sketchPolygon, .pen, .fillet, .chamfer, .convertLines, .mirror, .trim, .paperFolding, .patterning:
            return self.onHover { isHovered in
                if isHovered { NSCursor.crosshair.set() }
                else { NSCursor.arrow.set() }
            }
        }
    }

    /// Conditionally applies a modifier — used so the dimension field only blocks
    /// letters for numeric (auto) dimensions, not formula-capable ones.
    @ViewBuilder
    func ifCondition<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// Inline multi-line text editor used while creating/editing a canvas TEXT
/// entity (MAS-135). Wraps an `NSTextView` so it can render the chosen font and
/// style live, auto-focus + select-all on appear, insert a newline on
/// `Shift+Enter`, commit on `Enter`, and cancel on `Esc`.
struct InlineTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var underline: Bool
    var kerning: CGFloat
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = CommittingTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.drawsBackground = false
        tv.allowsUndo = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        // No wrapping — text extends rightward like the committed entity; only
        // Shift+Enter adds a line. This keeps the preview matching the final and
        // stops a narrow box from pushing text "up and above" (MAS-135).
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                        height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.font = font
        tv.textColor = textColor
        tv.string = text
        tv.onCommit = onCommit
        tv.onCancel = onCancel
        applyAttributes(to: tv)
        // Auto-focus and select all so the user can immediately type over the
        // placeholder (new text) or replace the existing value.
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.selectAll(nil)
        }
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        if tv.string != text { tv.string = text }
        tv.font = font
        tv.textColor = textColor
        (tv as? CommittingTextView)?.onCommit = onCommit
        (tv as? CommittingTextView)?.onCancel = onCancel
        applyAttributes(to: tv)
    }

    private func applyAttributes(to tv: NSTextView) {
        var typing: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0
        ]
        if kerning != 0 { typing[.kern] = kerning }
        tv.typingAttributes = typing
        if let ts = tv.textStorage, ts.length > 0 {
            let range = NSRange(location: 0, length: ts.length)
            ts.addAttribute(.font, value: font, range: range)
            ts.addAttribute(.foregroundColor, value: textColor, range: range)
            if underline {
                ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                ts.removeAttribute(.underlineStyle, range: range)
            }
            if kerning != 0 {
                ts.addAttribute(.kern, value: kerning, range: range)
            } else {
                ts.removeAttribute(.kern, range: range)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextEditor
        init(_ p: InlineTextEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift {
                    // Shift+Enter → new line (MAS-135).
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                // Enter commits the text.
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

/// NSTextView subclass that exposes commit/cancel hooks so the SwiftUI wrapper
/// can react to Enter/Esc even when the delegate path doesn't fire.
final class CommittingTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
}
