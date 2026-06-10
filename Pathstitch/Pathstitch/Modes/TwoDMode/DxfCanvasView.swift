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
                        let strokeColor: Color
                        if isSelected {
                            if ent.layer.uppercased() == "ORIGINAL" {
                                strokeColor = Color.accent
                            } else {
                                strokeColor = baseColor
                            }
                        } else if isHovered {
                            if ent.layer.uppercased() == "ORIGINAL" {
                                strokeColor = Color.accent.opacity(0.5)
                            } else {
                                strokeColor = baseColor.opacity(0.6)
                            }
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
                        let startScreen = toScreen(dx: measure.start.x, dy: measure.start.y, size: size, bounds: modelBounds)
                        let endScreen = toScreen(dx: measure.end.x, dy: measure.end.y, size: size, bounds: modelBounds)
                        
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
                        let startScreen = toScreen(dx: startModel.x, dy: startModel.y, size: size, bounds: modelBounds)
                        var path = SwiftUI.Path()
                        path.move(to: startScreen)
                        path.addLine(to: mouseLocation)
                        context.stroke(path, with: .color(Color.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        
                        let endModel = toModel(point: mouseLocation, size: size, bounds: modelBounds)
                        let dist = Double(hypot(startModel.x - endModel.x, startModel.y - endModel.y))
                        let labelText = String(format: "L: %.2f mm", dist)
                        let midScreen = CGPoint(x: (startScreen.x + mouseLocation.x) / 2, y: (startScreen.y + mouseLocation.y) / 2)
                        context.draw(Text(labelText).font(.system(size: 10, weight: .bold)).foregroundColor(.accent), at: CGPoint(x: midScreen.x, y: midScreen.y - 10), anchor: .center)
                    } else if state.currentTool == .sketchCircle, let startModel = sketchStartPoint {
                        let startScreen = toScreen(dx: startModel.x, dy: startModel.y, size: size, bounds: modelBounds)
                        let endModel = toModel(point: mouseLocation, size: size, bounds: modelBounds)
                        let rModel = Double(hypot(startModel.x - endModel.x, startModel.y - endModel.y))
                        let rScreen = CGFloat(rModel) * state.canvasScale
                        
                        var path = SwiftUI.Path()
                        path.addEllipse(in: CGRect(x: startScreen.x - rScreen, y: startScreen.y - rScreen, width: rScreen * 2, height: rScreen * 2))
                        context.stroke(path, with: .color(Color.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        
                        var radLine = SwiftUI.Path()
                        radLine.move(to: startScreen)
                        radLine.addLine(to: mouseLocation)
                        context.stroke(radLine, with: .color(Color.accent.opacity(0.5)), lineWidth: 1.0)
                        
                        let labelText = String(format: "R: %.2f mm", rModel)
                        context.draw(Text(labelText).font(.system(size: 10, weight: .bold)).foregroundColor(.accent), at: CGPoint(x: mouseLocation.x, y: mouseLocation.y - 10), anchor: .center)
                    } else if state.currentTool == .sketchRectangle, let startModel = sketchStartPoint {
                        let startScreen = toScreen(dx: startModel.x, dy: startModel.y, size: size, bounds: modelBounds)
                        let endModel = toModel(point: mouseLocation, size: size, bounds: modelBounds)
                        
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
                        context.draw(Text(labelText).font(.system(size: 10, weight: .bold)).foregroundColor(.accent), at: CGPoint(x: mouseLocation.x, y: mouseLocation.y - 10), anchor: .center)
                    } else if state.currentTool == .sketchText, let startModel = sketchStartPoint {
                        let startScreen = toScreen(dx: startModel.x, dy: startModel.y, size: size, bounds: modelBounds)
                        let endModel = toModel(point: mouseLocation, size: size, bounds: modelBounds)
                        
                        let rect = CGRect(
                            x: min(startScreen.x, mouseLocation.x),
                            y: min(startScreen.y, mouseLocation.y),
                            width: abs(startScreen.x - mouseLocation.x),
                            height: abs(startScreen.y - mouseLocation.y)
                        )
                        var boxPath = SwiftUI.Path()
                        boxPath.addRect(rect)
                        context.stroke(boxPath, with: .color(Color.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        
                        let w = abs(endModel.x - startModel.x)
                        let h = abs(endModel.y - startModel.y)
                        let labelText = String(format: "W: %.2f | H: %.2f mm", w, h)
                        context.draw(Text(labelText).font(.system(size: 10, weight: .bold)).foregroundColor(.accent), at: CGPoint(x: mouseLocation.x, y: mouseLocation.y - 10), anchor: .center)
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
                            if let nearestMeasure = findNearestMeasurement(screenPt: point, size: geo.size, bounds: modelBounds) {
                                editingDimension = nearestMeasure
                                editingDimensionText = String(format: "%.2f", nearestMeasure.distanceMm)
                                
                                let startScreen = toScreen(dx: nearestMeasure.start.x, dy: nearestMeasure.start.y, size: geo.size, bounds: modelBounds)
                                let endScreen = toScreen(dx: nearestMeasure.end.x, dy: nearestMeasure.end.y, size: geo.size, bounds: modelBounds)
                                editingDimensionScreenPos = CGPoint(
                                    x: (startScreen.x + endScreen.x) / 2,
                                    y: (startScreen.y + endScreen.y) / 2
                                )
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
                                    DragGesture()
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
                                    DragGesture()
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
                                    DragGesture()
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
                            if let val = Double(editingDimensionText) {
                                state.selectedMeasurement = editing
                                state.updateSelectedDimensionValue(newValue: val)
                            }
                            editingDimension = nil
                        })
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
                    sketchStartPoint = toModel(point: val.startLocation, size: size, bounds: modelBounds)
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
                let end = toModel(point: val.location, size: size, bounds: modelBounds)
                let dragDist = hypot(val.translation.width, val.translation.height)
                
                if dragDist > 5.0 {
                    if state.currentTool == .sketchText {
                        let textHeight = Double(abs(end.y - start.y))
                        let textInsert = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
                        Task {
                            await MainActor.run {
                                state.pendingTextInsert = textInsert
                                state.pendingTextHeight = textHeight
                                state.showTextInputDialog = true
                            }
                        }
                    } else if state.currentTool == .sketchLine {
                        let dist = Double(hypot(start.x - end.x, start.y - end.y))
                        Task {
                            if let handle = await state.addSketchedEntity(type: "line", params: [
                                "start": [Double(start.x), Double(start.y)],
                                "end": [Double(end.x), Double(end.y)]
                            ]) {
                                await MainActor.run {
                                    state.measurements.append(MeasurementLine(
                                        start: start,
                                        end: end,
                                        distanceMm: dist,
                                        isAutoDimension: true,
                                        entityHandle: handle,
                                        dimensionType: "length"
                                    ))
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
                                    state.measurements.append(MeasurementLine(
                                        start: start,
                                        end: endRad,
                                        distanceMm: radius,
                                        isAutoDimension: true,
                                        entityHandle: handle,
                                        dimensionType: "radius"
                                    ))
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
                                    state.measurements.append(MeasurementLine(
                                        start: pBottomLeft,
                                        end: pBottomRight,
                                        distanceMm: Double(w),
                                        isAutoDimension: true,
                                        entityHandle: handle,
                                        dimensionType: "width",
                                        rectP1: pBottomLeft,
                                        rectP2: end,
                                        filletRadius: state.sketchFilletRadius
                                    ))
                                    state.measurements.append(MeasurementLine(
                                        start: pBottomLeft,
                                        end: pTopLeft,
                                        distanceMm: Double(h),
                                        isAutoDimension: true,
                                        entityHandle: handle,
                                        dimensionType: "height",
                                        rectP1: pBottomLeft,
                                        rectP2: end,
                                        filletRadius: state.sketchFilletRadius
                                    ))
                                }
                            }
                        }
                    }
                }
            }
            sketchStartPoint = nil
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
