import SwiftUI

struct DxfCanvasView: View {
    var state: AppState
    
    @State private var dragStartOffset = CGSize.zero
    @State private var isDragging = false
    @State private var mouseLocation = CGPoint.zero
    @State private var hoverCoords: CGPoint? = nil
    
    var body: some View {
        GeometryReader { geo in
            let modelBounds = state.entities.isEmpty ? CGRect(x: 0, y: 0, width: 200, height: 200) : getBounds(state.entities)
            
            ZStack(alignment: .bottomLeading) {
                Canvas { context, size in
                    // Draw Grid
                    if state.gridVisible {
                        drawGrid(context: context, size: size, bounds: modelBounds)
                    }
                    
                    // Draw Entities
                    for ent in state.entities {
                        let layerVisible = state.layers.first(where: { $0.name == ent.layer })?.visible ?? true
                        if !layerVisible { continue }
                        
                        let isSelected = state.selectedHandles.contains(ent.handle)
                        let strokeColor = isSelected ? Color.accent : (state.layers.first(where: { $0.name == ent.layer })?.color ?? Color.text_primary)
                        let strokeWidth = isSelected ? 1.8 : 0.8
                        
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
                                clockwise: sa > ea
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
                                context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
                            }
                        }
                    }
                    
                    // Draw Measurement Line
                    if state.currentTool == .measure, let start = state.measureStartPoint {
                        var mPath = SwiftUI.Path()
                        mPath.move(to: start)
                        if let end = state.measureEndPoint {
                            mPath.addLine(to: end)
                            context.stroke(mPath, with: .color(Color.status_warn), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
                        } else {
                            mPath.addLine(to: mouseLocation)
                            context.stroke(mPath, with: .color(Color.status_warn), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
                        }
                    }
                }
                .background(Color.bg_base)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            if state.currentTool == .pan || NSEvent.modifierFlags.contains(.option) {
                                if !isDragging {
                                    dragStartOffset = state.canvasOffset
                                    isDragging = true
                                }
                                state.canvasOffset = CGSize(
                                    width: dragStartOffset.width + val.translation.width,
                                    height: dragStartOffset.height + val.translation.height
                                )
                            } else if state.currentTool == .measure {
                                if state.measureStartPoint == nil {
                                    state.measureStartPoint = val.startLocation
                                }
                                state.measureEndPoint = val.location
                                updateMeasurement(size: geo.size, bounds: modelBounds)
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
                .onTapGesture { point in
                    if state.currentTool == .select || state.currentTool == .chainSelect {
                        let clickedModelPt = toModel(point: point, size: geo.size, bounds: modelBounds)
                        if let nearest = findNearestEntity(modelPt: clickedModelPt, maxDistanceScreen: 12.0, size: geo.size, bounds: modelBounds) {
                            if state.currentTool == .chainSelect {
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
                    } else if state.currentTool == .measure {
                        if state.measureStartPoint == nil {
                            state.measureStartPoint = point
                        } else {
                            state.measureEndPoint = point
                            updateMeasurement(size: geo.size, bounds: modelBounds)
                        }
                    }
                }
                .modifier(MouseTrackerModifier(mouseLocation: $mouseLocation, hoverCoords: $hoverCoords, size: geo.size, bounds: modelBounds, scale: state.canvasScale, offset: state.canvasOffset))
                .background(
                    ScrollWheelModifier(
                        onZoom: { event in
                            let oldScale = state.canvasScale
                            let zoomFactor: CGFloat = event.deltaY > 0 ? 1.15 : 0.85
                            let newScale = max(0.01, min(500.0, oldScale * zoomFactor))
                            
                            if newScale != oldScale {
                                let mPt = toModel(point: mouseLocation, size: geo.size, bounds: modelBounds)
                                state.canvasScale = newScale
                                
                                let dx = mPt.x - modelBounds.midX
                                let dy = mPt.y - modelBounds.midY
                                let scaleDiff = newScale - oldScale
                                
                                state.canvasOffset = CGSize(
                                    width: state.canvasOffset.width - dx * scaleDiff,
                                    height: state.canvasOffset.height + dy * scaleDiff
                                )
                            }
                        },
                        onPan: { event in
                            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 10
                            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
                            state.canvasOffset = CGSize(
                                width: state.canvasOffset.width + dx,
                                height: state.canvasOffset.height + dy
                            )
                        }
                    )
                )
                
                // Overlay Coordinate Display (Plasticity Style)
                if let coords = hoverCoords {
                    HStack(spacing: 8) {
                        Text("X: \(String(format: "%.2f", coords.x)) mm")
                        Text("Y: \(String(format: "%.2f", coords.y)) mm")
                        if state.currentTool == .measure, let dist = state.measuredDistanceMm {
                            Text("| Dist: \(String(format: "%.2f", dist)) mm")
                                .foregroundColor(.status_warn)
                        }
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
        let screenX = (dx - bounds.midX) * state.canvasScale + size.width / 2 + state.canvasOffset.width
        let screenY = -(dy - bounds.midY) * state.canvasScale + size.height / 2 + state.canvasOffset.height
        return CGPoint(x: screenX, y: screenY)
    }
    
    private func toModel(point: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
        let dx = (point.x - size.width / 2 - state.canvasOffset.width) / state.canvasScale + bounds.midX
        let dy = -(point.y - size.height / 2 - state.canvasOffset.height) / state.canvasScale + bounds.midY
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
    
    private func updateMeasurement(size: CGSize, bounds: CGRect) {
        guard let start = state.measureStartPoint, let end = state.measureEndPoint else { return }
        let p1 = toModel(point: start, size: size, bounds: bounds)
        let p2 = toModel(point: end, size: size, bounds: bounds)
        state.measuredDistanceMm = Double(hypot(p1.x - p2.x, p1.y - p2.y))
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
            } else if let vertices = ent.vertices {
                for i in 0..<(vertices.count - 1) {
                    let d = distanceToSegment(pt: modelPt, start: CGPoint(x: vertices[i][0], y: vertices[i][1]), end: CGPoint(x: vertices[i+1][0], y: vertices[i+1][1]))
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
                    let dx = (point.x - size.width / 2 - offset.width) / scale + bounds.midX
                    let dy = -(point.y - size.height / 2 - offset.height) / scale + bounds.midY
                    self.hoverCoords = CGPoint(x: dx, y: dy)
                case .ended:
                    self.hoverCoords = nil
                }
            }
    }
}

// Scroll Wheel NSView representable wrapper
struct ScrollWheelModifier: NSViewRepresentable {
    var onZoom: (NSEvent) -> Void
    var onPan: (NSEvent) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = ScrollEventView()
        view.onZoom = onZoom
        view.onPan = onPan
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    class ScrollEventView: NSView {
        var onZoom: ((NSEvent) -> Void)?
        var onPan: ((NSEvent) -> Void)?
        
        override var acceptsFirstResponder: Bool { true }
        
        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.option) {
                onZoom?(event)
            } else {
                onPan?(event)
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
        case .select, .chainSelect, .offset, .addHoles, .cleanup, .measure:
            return self.onHover { isHovered in
                if isHovered { NSCursor.crosshair.set() }
                else { NSCursor.arrow.set() }
            }
        }
    }
}
