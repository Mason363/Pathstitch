import SwiftUI

struct DxfCanvasView: View {
    var state: AppState
    
    @State private var dragStartOffset = CGSize.zero
    @State private var isDragging = false
    @State private var mouseLocation = CGPoint.zero
    @State private var hoverCoords: CGPoint? = nil
    
    @State private var dragSelectionStart: CGPoint? = nil
    @State private var dragSelectionEnd: CGPoint? = nil
    
    @State private var sketchStartPoint: CGPoint? = nil // in model coordinates
    @State private var editingMeasureId: UUID? = nil
    @State private var editingIsStart: Bool = false
    
    @State private var gizmoDragOffset = CGSize.zero
    @State private var isDraggingSelection = false
    @State private var dragStartModelPt = CGPoint.zero
    @State private var isDraggingFillet = false
    @State private var isDraggingOffset = false
    
    @State private var editingDimension: MeasurementLine? = nil
    @State private var editingDimensionText: String = ""
    @State private var editingDimensionScreenPos: CGPoint = .zero
    @FocusState private var isTextEditorFocused: Bool
    @FocusState private var isDimensionEditorFocused: Bool
    
    var selectionCenterModel: CGPoint? {
        if state.selectedHandles.isEmpty { return nil }
        var pts: [CGPoint] = []
        for h in state.selectedHandles {
            if let ent = state.entities.first(where: { $0.handle == h }) {
                if let s = ent.start { pts.append(CGPoint(x: s[0], y: s[1])) }
                if let e = ent.end { pts.append(CGPoint(x: e[0], y: e[1])) }
                if let c = ent.center { pts.append(CGPoint(x: c[0], y: c[1])) }
                if let vertices = ent.vertices {
                    for v in vertices {
                        if v.count >= 2 { pts.append(CGPoint(x: v[0], y: v[1])) }
                    }
                }
            }
        }
        if pts.isEmpty { return nil }
        let sumX = pts.map { $0.x }.reduce(0, +)
        let sumY = pts.map { $0.y }.reduce(0, +)
        return CGPoint(x: sumX / CGFloat(pts.count), y: sumY / CGFloat(pts.count))
    }
    
    var body: some View {
        @Bindable var state = state
        GeometryReader { geo in
            let modelBounds = state.entities.isEmpty ? CGRect(x: 0, y: 0, width: 200, height: 200) : getBounds(state.entities)
            
            ZStack(alignment: .bottomLeading) {
                Canvas { context, size in
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
                    
                    // Draw Entities
                    for ent in state.entities {
                        let layerVisible = state.layers.first(where: { $0.name == ent.layer })?.visible ?? true
                        if !layerVisible { continue }
                        
                        let isSelected = state.selectedHandles.contains(ent.handle)
                        let isHovered = (state.hoveredHandle == ent.handle)
                        
                        let baseColor = state.layers.first(where: { $0.name == ent.layer })?.color ?? Color.text_primary
                        let isOriginal = ent.layer.uppercased() == "ORIGINAL"
                        let strokeColor: Color
                        if isSelected {
                            strokeColor = isOriginal ? Color.accent : baseColor
                        } else if isHovered {
                            strokeColor = isOriginal ? Color.accent.opacity(0.5) : baseColor.opacity(0.6)
                        } else {
                            strokeColor = baseColor
                        }
                        let strokeWidth = isSelected ? 1.8 : (isHovered ? 1.4 : 0.8)
                        
                        let dxOffset = isSelected ? gizmoDragOffset.width : 0.0
                        let dyOffset = isSelected ? gizmoDragOffset.height : 0.0
                        
                        var path = SwiftUI.Path()
                        if ent.type == "LINE", let s = ent.start, let e = ent.end {
                            let p1 = toScreen(dx: s[0], dy: s[1], size: size, bounds: modelBounds)
                            let p2 = toScreen(dx: e[0], dy: e[1], size: size, bounds: modelBounds)
                            path.move(to: CGPoint(x: p1.x + dxOffset, y: p1.y + dyOffset))
                            path.addLine(to: CGPoint(x: p2.x + dxOffset, y: p2.y + dyOffset))
                            context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
                        } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
                            let sc = toScreen(dx: center[0], dy: center[1], size: size, bounds: modelBounds)
                            let r = CGFloat(radius) * state.canvasScale
                            let rect = CGRect(x: sc.x + dxOffset - r, y: sc.y + dyOffset - r, width: r * 2, height: r * 2)
                            path.addEllipse(in: rect)
                            context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
                        } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius,
                                  let sa = ent.start_angle, let ea = ent.end_angle {
                            let sc = toScreen(dx: center[0], dy: center[1], size: size, bounds: modelBounds)
                            let r = CGFloat(radius) * state.canvasScale
                            path.addArc(
                                center: CGPoint(x: sc.x + dxOffset, y: sc.y + dyOffset),
                                radius: r,
                                startAngle: Angle(degrees: -sa),
                                endAngle: Angle(degrees: -ea),
                                clockwise: true
                            )
                            context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
                        } else if let vertices = ent.vertices {
                            if vertices.count >= 2 {
                                let pStart = toScreen(dx: vertices[0][0], dy: vertices[0][1], size: size, bounds: modelBounds)
                                path.move(to: CGPoint(x: pStart.x + dxOffset, y: pStart.y + dyOffset))
                                for i in 1..<vertices.count {
                                    let p = toScreen(dx: vertices[i][0], dy: vertices[i][1], size: size, bounds: modelBounds)
                                    path.addLine(to: CGPoint(x: p.x + dxOffset, y: p.y + dyOffset))
                                }
                                if ent.closed == true {
                                    path.closeSubpath()
                                }
                                context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
                            }
                        } else if ent.type == "TEXT", let textStr = ent.text, let start = ent.start {
                            if state.isEditingText && state.editingTextHandle == ent.handle {
                                continue
                            }
                            let sc = toScreen(dx: start[0], dy: start[1], size: size, bounds: modelBounds)
                            let h = CGFloat(ent.height ?? 5.0) * state.canvasScale
                            let resolvedText = context.resolve(Text(textStr).font(.system(size: h)).foregroundColor(strokeColor))
                            context.draw(resolvedText, at: CGPoint(x: sc.x + dxOffset, y: sc.y + dyOffset), anchor: .bottomLeading)
                        }
                    }
                    
                    // Draw Live Preview Entities (Dashed Orange Lines)
                    for ent in state.previewEntities {
                        let strokeColor = Color.status_warn
                        let strokeStyle = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [4, 4])
                        
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
                    
                    // Draw Locked Measurement Lines
                    for measure in state.measurements {
                        if measure.isAutoDimension {
                            if let handle = measure.entityHandle, !state.selectedHandles.contains(handle) {
                                continue
                            }
                        }
                        
                        let isSelected = state.selectedMeasurement?.id == measure.id
                        let isMeasuringSelectedEntity = (measure.entityHandle != nil && state.selectedHandles.contains(measure.entityHandle!))
                        let mDxOffset = isMeasuringSelectedEntity ? gizmoDragOffset.width : 0.0
                        let mDyOffset = isMeasuringSelectedEntity ? gizmoDragOffset.height : 0.0
                        
                        let baseStartScreen = toScreen(dx: measure.start.x, dy: measure.start.y, size: size, bounds: modelBounds)
                        let baseEndScreen = toScreen(dx: measure.end.x, dy: measure.end.y, size: size, bounds: modelBounds)
                        let startScreen = CGPoint(x: baseStartScreen.x + mDxOffset, y: baseStartScreen.y + mDyOffset)
                        let endScreen = CGPoint(x: baseEndScreen.x + mDxOffset, y: baseEndScreen.y + mDyOffset)
                        
                        var mPath = SwiftUI.Path()
                        mPath.move(to: startScreen)
                        mPath.addLine(to: endScreen)
                        
                        let color: Color
                        let strokeStyle: StrokeStyle
                        
                        if isSelected {
                            color = Color.white // Selected highlight
                            strokeStyle = StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        } else if measure.isAutoDimension {
                            color = Color.cyan // Auto dimension (Solid)
                            strokeStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        } else {
                            color = Color.orange // Manual measurement (Dotted)
                            strokeStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4])
                        }
                        
                        context.stroke(mPath, with: .color(color), style: strokeStyle)
                        
                        var dot1 = SwiftUI.Path()
                        dot1.addEllipse(in: CGRect(x: startScreen.x - 4, y: startScreen.y - 4, width: 8, height: 8))
                        context.fill(dot1, with: .color(color))
                        
                        var dot2 = SwiftUI.Path()
                        dot2.addEllipse(in: CGRect(x: endScreen.x - 4, y: endScreen.y - 4, width: 8, height: 8))
                        context.fill(dot2, with: .color(color))
                        
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
                    
                    // Draw Snapping Hover Indicator
                    if let hover = hoverCoords {
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
                }
                .background(Color.bg_base)
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
                            if let nearestMeasure = findNearestMeasurement(screenPt: point, size: geo.size, bounds: modelBounds) {
                                editingDimension = nearestMeasure
                                editingDimensionText = String(format: "%.2f", nearestMeasure.distanceMm)
                                
                                let startScreen = toScreen(dx: nearestMeasure.start.x, dy: nearestMeasure.start.y, size: geo.size, bounds: modelBounds)
                                let endScreen = toScreen(dx: nearestMeasure.end.x, dy: nearestMeasure.end.y, size: geo.size, bounds: modelBounds)
                                editingDimensionScreenPos = CGPoint(
                                    x: (startScreen.x + endScreen.x) / 2,
                                    y: (startScreen.y + endScreen.y) / 2
                                )
                            } else if let nearestEntity = findNearestEntity(modelPt: modelPt, maxDistanceScreen: 16.0, size: geo.size, bounds: modelBounds),
                                      nearestEntity.type == "TEXT" {
                                state.startEditingText(entity: nearestEntity)
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
                    } else {
                        state.hoveredHandle = nil
                    }
                }
                .onChange(of: state.fitRequestToken) { _, _ in
                    fitToContent(viewSize: geo.size)
                }
                .onChange(of: state.isEditingText) { _, editing in
                    isTextEditorFocused = editing
                }
                .onChange(of: state.escapePressedToken) { _, _ in
                    if state.isEditingText {
                        state.cancelTextEditing()
                    } else if sketchStartPoint != nil {
                        sketchStartPoint = nil
                    } else {
                        state.selectedHandles.removeAll()
                        state.selectedFaces3D.removeAll()
                    }
                }
                .onChange(of: state.currentTool) { _, _ in
                    sketchStartPoint = nil
                    state.activeMeasureStart = nil
                }
                .onChange(of: editingDimension) { _, newDim in
                    if newDim != nil {
                        isDimensionEditorFocused = true
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
                        }
                    )
                    .allowsHitTesting(true)
                )
                .cursorStyle(state.currentTool)
                
                // Underlay Reference Canvas Image
                if let img = state.refImage {
                    let imgWidth = img.size.width * state.refImageScale * state.canvasScale
                    let imgHeight = img.size.height * state.refImageScale * state.canvasScale
                    
                    let screenCenter = toScreen(dx: Double(state.refImageOffset.width), dy: Double(state.refImageOffset.height), size: geo.size, bounds: modelBounds)
                    
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: imgWidth, height: imgHeight)
                        .opacity(state.refImageOpacity)
                        .position(screenCenter)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                ZStack {
                    // Translation Gizmo Layer
                    if let centerModel = selectionCenterModel {
                        let centerScreen = toScreen(dx: Double(centerModel.x), dy: Double(centerModel.y), size: geo.size, bounds: modelBounds)
                        
                        ZStack {
                            // X-axis constraint handle (Red Line & Arrow)
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: 0))
                                p.addLine(to: CGPoint(x: 50, y: 0))
                            }
                            .stroke(Color.red, lineWidth: 2)
                            
                            Image(systemName: "play.fill")
                                .resizable()
                                .foregroundColor(.red)
                                .frame(width: 8, height: 10)
                                .offset(x: 48)
                                .gesture(
                                    DragGesture(coordinateSpace: .global)
                                        .onChanged { val in
                                            gizmoDragOffset = CGSize(width: val.translation.width, height: 0)
                                        }
                                        .onEnded { val in
                                            let dx = val.translation.width / state.canvasScale
                                            state.translateSelected(dx: dx, dy: 0)
                                            gizmoDragOffset = .zero
                                        }
                                )
                            
                            // Y-axis constraint handle (Green Line & Arrow)
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: 0))
                                p.addLine(to: CGPoint(x: 0, y: -50))
                            }
                            .stroke(Color.green, lineWidth: 2)
                            
                            Image(systemName: "play.fill")
                                .resizable()
                                .foregroundColor(.green)
                                .frame(width: 8, height: 10)
                                .rotationEffect(.degrees(-90))
                                .offset(y: -48)
                                .gesture(
                                    DragGesture(coordinateSpace: .global)
                                        .onChanged { val in
                                            gizmoDragOffset = CGSize(width: 0, height: val.translation.height)
                                        }
                                        .onEnded { val in
                                            let dy = -val.translation.height / state.canvasScale
                                            state.translateSelected(dx: 0, dy: dy)
                                            gizmoDragOffset = .zero
                                        }
                                )
                            
                            // Center free movement box (Yellow square)
                            Rectangle()
                                .fill(Color.yellow)
                                .frame(width: 10, height: 10)
                                .border(Color.black, width: 1)
                                .gesture(
                                    DragGesture(coordinateSpace: .global)
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
                        .offset(gizmoDragOffset)
                        .position(centerScreen)
                    }
                    
                    // Calibration Points visual markers
                    if state.isCalibrationActive {
                        ForEach(Array(state.calibrationPoints.enumerated()), id: \.offset) { idx, pt in
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .position(pt)
                                .overlay(
                                    Text("Point \(idx + 1)")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .offset(y: -12)
                                        .position(pt)
                                )
                        }
                    }
                }
            )
            .overlay(
                Group {
                    // Overlay Coordinate Display (Plasticity Style)
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
                },
                alignment: .bottomLeading
            )
            .overlay(
                Group {
                    if let editing = editingDimension {
                        TextField("", text: $editingDimensionText, onCommit: {
                            commitDimensionEdit()
                        })
                        .onSubmit {
                            commitDimensionEdit()
                        }
                        .focused($isDimensionEditorFocused)
                        .onKeyPress(.tab) {
                            cycleDimension(size: geo.size, modelBounds: modelBounds)
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
                        .position(editingDimensionScreenPos)
                        .shadow(radius: 4)
                    }
                    
                    if state.isEditingText {
                        let sc = toScreen(dx: state.editingTextInsert.x, dy: state.editingTextInsert.y, size: geo.size, bounds: modelBounds)
                        let fontSize = CGFloat(state.editingTextHeight) * state.canvasScale
                        
                        TextField("Enter text...", text: $state.editingTextString, onCommit: {
                            state.commitTextEditing()
                        })
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: max(8.0, fontSize)))
                        .foregroundColor(Color.text_primary)
                        .padding(4)
                        .background(Color.bg_panel.opacity(0.85))
                        .cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accent, lineWidth: 1.0))
                        .frame(minWidth: 150)
                        .position(sc)
                        .focused($isTextEditorFocused)
                        .onSubmit {
                            state.commitTextEditing()
                        }
                    }
                }
            )
        }
    }

    private func handleDragChanged(val: DragGesture.Value, size: CGSize, modelBounds: CGRect) {
        if !isDragging {
            isDragging = true
            
            let point = val.startLocation
            let startScreenTolerance: CGFloat = 16.0
            var foundEndpoint = false
            
            // 1. Check if clicking near a measurement endpoint to drag-edit it
            for measure in state.measurements {
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
            
            // 2. Check if clicking near a rectangle fillet handle
            var foundFilletHandle = false
            if !foundEndpoint,
               let selected = state.selectedMeasurement,
               let p1 = selected.rectP1,
               let p2 = selected.rectP2 {
                let filletRad = selected.filletRadius
                let maxX = max(p1.x, p2.x)
                let maxY = max(p1.y, p2.y)
                let handleScreen = toScreen(dx: Double(maxX - filletRad), dy: Double(maxY - filletRad), size: size, bounds: modelBounds)
                if hypot(point.x - handleScreen.x, point.y - handleScreen.y) < 16.0 {
                    foundFilletHandle = true
                    isDraggingFillet = true
                }
            }
            
            // 3. Check if clicking near an offset arrow handle
            var foundOffsetHandle = false
            if !foundEndpoint && !foundFilletHandle,
               state.currentTool == .offset,
               let handleInfo = getOffsetHandleInfo() {
                let scaleDir: CGFloat = state.offsetSide == "left" ? 1.0 : -1.0
                let handlePt = CGPoint(
                    x: handleInfo.basePoint.x + handleInfo.normal.x * CGFloat(state.offsetDistance) * scaleDir,
                    y: handleInfo.basePoint.y + handleInfo.normal.y * CGFloat(state.offsetDistance) * scaleDir
                )
                let handleScreen = toScreen(dx: Double(handlePt.x), dy: Double(handlePt.y), size: size, bounds: modelBounds)
                if hypot(point.x - handleScreen.x, point.y - handleScreen.y) < 16.0 {
                    foundOffsetHandle = true
                    isDraggingOffset = true
                }
            }
            
            // 4. Check if clicking on/near a selected entity to drag-translate it
            var clickedOnSelected = false
            let hasNoActiveHandles: Bool = (!foundEndpoint) && (!foundFilletHandle) && (!foundOffsetHandle)
            let isSelectTool: Bool = state.currentTool == .select
            let hasSelectedHandles: Bool = !state.selectedHandles.isEmpty
            if hasNoActiveHandles && isSelectTool && hasSelectedHandles {
                let clickedModelPt = toModel(point: point, size: size, bounds: modelBounds)
                if let nearest = findNearestEntity(modelPt: clickedModelPt, maxDistanceScreen: 16.0, size: size, bounds: modelBounds),
                   state.selectedHandles.contains(nearest.handle) {
                    clickedOnSelected = true
                    isDraggingSelection = true
                    dragStartModelPt = clickedModelPt
                }
            }
            
            // 5. Default drag mode initialization
            let shouldStartDefaultDrag: Bool = hasNoActiveHandles && (!clickedOnSelected)
            if shouldStartDefaultDrag {
                editingMeasureId = nil
                isDraggingFillet = false
                isDraggingOffset = false
                isDraggingSelection = false
                
                if state.currentTool == .pan || NSEvent.modifierFlags.contains(.option) {
                    dragStartOffset = state.canvasOffset
                } else if state.currentTool == .sketchLine || state.currentTool == .sketchCircle || state.currentTool == .sketchRectangle || state.currentTool == .sketchText {
                    if state.currentTool == .sketchLine && sketchStartPoint != nil {
                        // Keep previous chained point
                    } else {
                        let startPt = val.startLocation
                        if let snap = getSnappedPoint(for: startPt, size: size, bounds: modelBounds) {
                            sketchStartPoint = snap.snappedModelPt
                        } else {
                            sketchStartPoint = toModel(point: startPt, size: size, bounds: modelBounds)
                        }
                    }
                } else if state.currentTool != .measure {
                    dragSelectionStart = val.startLocation
                }
            }
        }
        
        // Update mouse location and hover coordinates during drag
        self.mouseLocation = val.location
        self.hoverCoords = toModel(point: val.location, size: size, bounds: modelBounds)
        
        // Handle active dragging updates
        if isDraggingFillet {
            if let selected = state.selectedMeasurement,
               let p1 = selected.rectP1,
               let p2 = selected.rectP2 {
                let maxX = max(p1.x, p2.x)
                let maxY = max(p1.y, p2.y)
                let modelPt = toModel(point: val.location, size: size, bounds: modelBounds)
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
        } else if isDraggingOffset {
            if let handleInfo = getOffsetHandleInfo() {
                let modelPt = toModel(point: val.location, size: size, bounds: modelBounds)
                let vecX = modelPt.x - handleInfo.basePoint.x
                let vecY = modelPt.y - handleInfo.basePoint.y
                let proj = vecX * handleInfo.normal.x + vecY * handleInfo.normal.y
                state.offsetDistance = max(0.1, abs(proj))
                state.offsetSide = proj >= 0 ? "left" : "right"
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
        } else if state.currentTool == .sketchLine || state.currentTool == .sketchCircle || state.currentTool == .sketchRectangle || state.currentTool == .sketchText {
            // mouseLocation is already updated above
        } else if state.currentTool != .measure {
            dragSelectionEnd = val.location
        }
    }

    private func handleDragEnded(val: DragGesture.Value, size: CGSize, modelBounds: CGRect) {
        isDragging = false
        if editingMeasureId != nil {
            editingMeasureId = nil
            return
        }
        if isDraggingFillet {
            isDraggingFillet = false
            state.updateSelectedRectangleFillet(newFillet: state.sketchFilletRadius)
            return
        }
        if isDraggingOffset {
            isDraggingOffset = false
            state.applyOffset()
            return
        }
        if isDraggingSelection {
            isDraggingSelection = false
            let startModel = toModel(point: val.startLocation, size: size, bounds: modelBounds)
            let currentModel = toModel(point: val.location, size: size, bounds: modelBounds)
            let dx = currentModel.x - startModel.x
            let dy = currentModel.y - startModel.y
            state.translateSelected(dx: dx, dy: dy)
            gizmoDragOffset = .zero
            return
        }
        
        if state.currentTool == .sketchLine || state.currentTool == .sketchCircle || state.currentTool == .sketchRectangle || state.currentTool == .sketchText {
            if let start = sketchStartPoint {
                let snapped = snappedMouseLocation(size: size, bounds: modelBounds)
                let end = snapped.point
                let dragDist = hypot(val.translation.width, val.translation.height)
                
                if dragDist > 5.0 {
                    if state.currentTool == .sketchText {
                        let textHeight = Double(abs(end.y - start.y))
                        let textInsert = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
                        state.startEditingNewText(insert: textInsert, height: textHeight)
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
                    } else if state.currentTool == .sketchRectangle {
                        Task {
                            if let handle = await state.addSketchedEntity(type: "rectangle", params: [
                                "p1": [Double(start.x), Double(start.y)],
                                "p2": [Double(end.x), Double(end.y)],
                                "fillet_radius": state.sketchFilletRadius
                            ]) {
                                let w = abs(end.x - start.x)
                                let h = abs(end.y - start.y)
                                let pBottomLeft = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
                                let pBottomRight = CGPoint(x: max(start.x, end.x), y: min(start.y, end.y))
                                let pTopLeft = CGPoint(x: min(start.x, end.x), y: max(start.y, end.y))
                                
                                await MainActor.run {
                                    let wMeasure = MeasurementLine(
                                        start: pBottomLeft,
                                        end: pBottomRight,
                                        distanceMm: Double(w),
                                        isAutoDimension: true,
                                        entityHandle: handle,
                                        dimensionType: "width",
                                        rectP1: pBottomLeft,
                                        rectP2: end,
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
                                        rectP2: end,
                                        filletRadius: state.sketchFilletRadius
                                    )
                                    state.measurements.append(wMeasure)
                                    state.measurements.append(hMeasure)
                                    
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
                
                if state.currentTool == .sketchLine {
                    sketchStartPoint = end
                } else {
                    sketchStartPoint = nil
                }
            }
            return
        }
        
        let dragDist = hypot(val.translation.width, val.translation.height)
        if dragDist < 4.0 {
            // CLICK
            let point = val.startLocation
            if state.currentTool == .select || state.currentTool == .offset || state.currentTool == .addHoles || state.currentTool == .cleanup {
                let clickedModelPt = toModel(point: point, size: size, bounds: modelBounds)
                
                // Check for dimension line click selection first
                if let nearestMeasure = findNearestMeasurement(screenPt: point, size: size, bounds: modelBounds) {
                    state.selectedMeasurement = nearestMeasure
                } else {
                    state.selectedMeasurement = nil
                    
                    if let nearest = findNearestEntity(modelPt: clickedModelPt, maxDistanceScreen: 12.0, size: size, bounds: modelBounds) {
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
                        if !NSEvent.modifierFlags.contains(.shift) {
                            state.selectedHandles.removeAll()
                        }
                    }
                }
            } else if state.isCalibrationActive {
                state.calibrationPoints.append(point)
                if state.calibrationPoints.count == 2 {
                    state.calibrateReferenceImage()
                }
            } else if state.currentTool == .measure {
                let clickedModelPt = toModel(point: point, size: size, bounds: modelBounds)
                if let startModel = state.activeMeasureStart {
                    let dist = Double(hypot(startModel.x - clickedModelPt.x, startModel.y - clickedModelPt.y))
                    let newMeasure = MeasurementLine(start: startModel, end: clickedModelPt, distanceMm: dist)
                    state.measurements.append(newMeasure)
                    state.activeMeasureStart = nil
                } else {
                    state.activeMeasureStart = clickedModelPt
                }
            }
        } else {
            // DRAG RELEASE
            if state.currentTool != .pan && state.currentTool != .measure && !NSEvent.modifierFlags.contains(.option) {
                let p1 = toModel(point: val.startLocation, size: size, bounds: modelBounds)
                let p2 = toModel(point: val.location, size: size, bounds: modelBounds)
                let modelSelRect = CGRect(
                    x: min(p1.x, p2.x),
                    y: min(p1.y, p2.y),
                    width: abs(p1.x - p2.x),
                    height: abs(p1.y - p2.y)
                )
                
                var boxSelected: Set<String> = []
                for ent in state.entities {
                    let visible = state.layers.first(where: { $0.name == ent.layer })?.visible ?? true
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
              let p2 = selected.rectP2 else { return }
              
        let filletRad = selected.filletRadius
        let maxX = max(p1.x, p2.x)
        let maxY = max(p1.y, p2.y)
        
        let cornerScreen = toScreen(dx: Double(maxX), dy: Double(maxY), size: size, bounds: modelBounds)
        let handleScreen = toScreen(dx: Double(maxX - filletRad), dy: Double(maxY - filletRad), size: size, bounds: modelBounds)
        
        var linePath = SwiftUI.Path()
        linePath.move(to: cornerScreen)
        linePath.addLine(to: handleScreen)
        context.stroke(linePath, with: .color(Color.accent), lineWidth: 1.5)
        
        var handlePath = SwiftUI.Path()
        handlePath.addEllipse(in: CGRect(x: handleScreen.x - 6, y: handleScreen.y - 6, width: 12, height: 12))
        context.fill(handlePath, with: .color(Color.accent))
        
        var borderPath = SwiftUI.Path()
        borderPath.addEllipse(in: CGRect(x: handleScreen.x - 6, y: handleScreen.y - 6, width: 12, height: 12))
        context.stroke(borderPath, with: .color(Color.white), lineWidth: 1.5)
        
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
        
        var handlePath = SwiftUI.Path()
        handlePath.addEllipse(in: CGRect(x: handleScreen.x - 4, y: handleScreen.y - 4, width: 8, height: 8))
        context.fill(handlePath, with: .color(Color.white))
        
        if isDraggingOffset {
            let strokeColor = Color.status_warn
            let strokeStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 4])
            let offsetVector = CGPoint(
                x: handleInfo.normal.x * CGFloat(state.offsetDistance) * scaleDir,
                y: handleInfo.normal.y * CGFloat(state.offsetDistance) * scaleDir
            )
            
            for handle in state.selectedHandles {
                guard let ent = state.entities.first(where: { $0.handle == handle }) else { continue }
                var previewPath = SwiftUI.Path()
                
                if ent.type == "LINE", let s = ent.start, let e = ent.end {
                    let offX: Double = Double(offsetVector.x)
                    let offY: Double = Double(offsetVector.y)
                    let p1 = toScreen(dx: s[0] + offX, dy: s[1] + offY, size: size, bounds: modelBounds)
                    let p2 = toScreen(dx: e[0] + offX, dy: e[1] + offY, size: size, bounds: modelBounds)
                    previewPath.move(to: p1)
                    previewPath.addLine(to: p2)
                    context.stroke(previewPath, with: .color(strokeColor), style: strokeStyle)
                } else if ent.type == "CIRCLE", let center: [Double] = ent.center, let radius: Double = ent.radius {
                    let offsetVal: Double = Double(state.offsetDistance)
                    let dirVal: Double = Double(scaleDir)
                    let newRadius: Double = radius + offsetVal * dirVal
                    if newRadius > Double(0.1) {
                        let sc: CGPoint = toScreen(dx: center[0], dy: center[1], size: size, bounds: modelBounds)
                        let r: CGFloat = CGFloat(newRadius) * state.canvasScale
                        let diameter: CGFloat = r * CGFloat(2.0)
                        let rect: CGRect = CGRect(x: sc.x - r, y: sc.y - r, width: diameter, height: diameter)
                        previewPath.addEllipse(in: rect)
                        context.stroke(previewPath, with: .color(strokeColor), style: strokeStyle)
                    }
                } else if let vertices: [[Double]] = ent.vertices, vertices.count >= 2 {
                    let offX: Double = Double(offsetVector.x)
                    let offY: Double = Double(offsetVector.y)
                    let screenPts: [CGPoint] = vertices.map { (v: [Double]) -> CGPoint in
                        toScreen(dx: v[0] + offX, dy: v[1] + offY, size: size, bounds: modelBounds)
                    }
                    previewPath.move(to: screenPts[0])
                    for idx in 1..<screenPts.count {
                        previewPath.addLine(to: screenPts[idx])
                    }
                    if ent.closed == true {
                        previewPath.closeSubpath()
                    }
                    context.stroke(previewPath, with: .color(strokeColor), style: strokeStyle)
                }
            }
        }
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

    /// Zooms/pans the canvas so all current geometry fits within `viewSize` with
    /// a margin (used after a multi-file distribute import so every file is
    /// visible at once — "all viewable"). Inverts `toScreen`'s transform.
    private func fitToContent(viewSize: CGSize) {
        guard !state.entities.isEmpty, viewSize.width > 1, viewSize.height > 1 else { return }
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
    
    private func drawGrid(context: GraphicsContext, size: CGSize, bounds: CGRect) {
        // Determine spacing based on zoom scale
        let minorSpacing: CGFloat = 10.0 // 10mm
        let majorSpacing: CGFloat = 100.0 // 100mm
        
        // Find visible model coordinates range
        let tl = toModel(point: CGPoint.zero, size: size, bounds: bounds)
        let br = toModel(point: CGPoint(x: size.width, y: size.height), size: size, bounds: bounds)
        
        let startX = floor(min(tl.x, br.x) / minorSpacing) * minorSpacing
        let endX = ceil(max(tl.x, br.x) / minorSpacing) * minorSpacing
        let startY = floor(min(tl.y, br.y) / minorSpacing) * minorSpacing
        let endY = ceil(max(tl.y, br.y) / minorSpacing) * minorSpacing
        
        // Minor grid lines
        var x = startX
        while x <= endX {
            var gridPath = SwiftUI.Path()
            let p1 = toScreen(dx: x, dy: startY, size: size, bounds: bounds)
            let p2 = toScreen(dx: x, dy: endY, size: size, bounds: bounds)
            gridPath.move(to: p1)
            gridPath.addLine(to: p2)
            
            let isMajor = abs(x.truncatingRemainder(dividingBy: majorSpacing)) < 1e-3
            let color = isMajor ? Color.border_strong : Color.border_subtle
            context.stroke(gridPath, with: .color(color), lineWidth: isMajor ? 0.8 : 0.4)
            x += minorSpacing
        }
        
        var y = startY
        while y <= endY {
            var gridPath = SwiftUI.Path()
            let p1 = toScreen(dx: startX, dy: y, size: size, bounds: bounds)
            let p2 = toScreen(dx: endX, dy: y, size: size, bounds: bounds)
            gridPath.move(to: p1)
            gridPath.addLine(to: p2)
            
            let isMajor = abs(y.truncatingRemainder(dividingBy: majorSpacing)) < 1e-3
            let color = isMajor ? Color.border_strong : Color.border_subtle
            context.stroke(gridPath, with: .color(color), lineWidth: isMajor ? 0.8 : 0.4)
            y += minorSpacing
        }
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

    private func findNearestMeasurement(screenPt: CGPoint, size: CGSize, bounds: CGRect, maxDistanceScreen: CGFloat = 12.0) -> MeasurementLine? {
        var nearest: MeasurementLine? = nil
        var minDist = maxDistanceScreen
        
        for measure in state.measurements {
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
        
        for ent in state.entities {
            let visible = state.layers.first(where: { $0.name == ent.layer })?.visible ?? true
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
                let textWidth = textLen * textHeight * 0.6
                distModel = distanceToSegment(pt: modelPt, start: CGPoint(x: start[0], y: start[1]), end: CGPoint(x: start[0] + textWidth, y: start[1]))
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
        return nearest
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
        for ent in state.entities {
            let layerVisible = state.layers.first(where: { $0.name == ent.layer })?.visible ?? true
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
        if let snap = getSnappedPoint(for: mouseLocation, size: size, bounds: bounds) {
            return (snap.snappedModelPt, snap)
        }
        let modelPt = toModel(point: mouseLocation, size: size, bounds: bounds)
        return (modelPt, nil)
    }
    
    private func cycleDimension(size: CGSize, modelBounds: CGRect) {
        guard let editing = editingDimension else { return }
        let related = state.measurements.filter { $0.entityHandle == editing.entityHandle && $0.isAutoDimension }
        guard !related.isEmpty else { return }
        
        if let idx = related.firstIndex(where: { $0.id == editing.id }) {
            let nextIdx = (idx + 1) % related.count
            let nextDim = related[nextIdx]
            
            if let val = Double(editingDimensionText) {
                state.selectedMeasurement = editing
                state.updateSelectedDimensionValue(newValue: val)
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
    }
    
    private func commitDimensionEdit() {
        if let editing = editingDimension {
            if let val = Double(editingDimensionText) {
                state.selectedMeasurement = editing
                state.updateSelectedDimensionValue(newValue: val)
            }
            editingDimension = nil
        }
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
    
    func makeNSView(context: Context) -> NSView {
        let view = ScrollEventView()
        view.onZoom = onZoom
        view.onPanOffset = onPanOffset
        view.onMagnify = onMagnify
        view.onDeleteSelected = onDeleteSelected
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    class ScrollEventView: NSView {
        var onZoom: ((NSEvent, CGPoint, CGFloat) -> Void)?
        var onPanOffset: ((CGSize) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onDeleteSelected: (() -> Void)?
        
        private var dragStartPoint: NSPoint?
        
        override var acceptsFirstResponder: Bool { true }
        
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
        
        override func magnify(with event: NSEvent) {
            let localPt = convert(event.locationInWindow, from: nil)
            let swiftUiPt = CGPoint(x: localPt.x, y: bounds.height - localPt.y)
            onMagnify?(event.magnification, swiftUiPt)
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
                if event.type == .leftMouseDown || event.type == .leftMouseUp || event.type == .leftMouseDragged {
                    return nil
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
        
        override func rightMouseDown(with event: NSEvent) {
            startDrag(with: event)
        }
        
        override func rightMouseDragged(with event: NSEvent) {
            drag(with: event)
        }
        
        override func rightMouseUp(with event: NSEvent) {
            endDrag(with: event)
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

// Custom view cursors
extension View {
    func cursorStyle(_ tool: TwoDTool) -> some View {
        switch tool {
        case .pan:
            return self.onHover { isHovered in
                if isHovered { NSCursor.openHand.set() }
                else { NSCursor.arrow.set() }
            }
        case .select, .offset, .addHoles, .cleanup, .measure, .sketchLine, .sketchCircle, .sketchRectangle, .sketchText:
            return self.onHover { isHovered in
                if isHovered { NSCursor.crosshair.set() }
                else { NSCursor.arrow.set() }
            }
        }
    }
}
