import QuickLook
import QuickLookUI
import CoreGraphics

class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let fileURL = request.fileURL
        let isAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let entities = DXFParser.parse(url: fileURL)
        
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        var hasGeometry = false
        
        for ent in entities {
            switch ent {
            case .line(let start, let end):
                minX = min(minX, Double(start.x), Double(end.x))
                maxX = max(maxX, Double(start.x), Double(end.x))
                minY = min(minY, Double(start.y), Double(end.y))
                maxY = max(maxY, Double(start.y), Double(end.y))
                hasGeometry = true
            case .circle(let center, let radius):
                minX = min(minX, Double(center.x - radius))
                maxX = max(maxX, Double(center.x + radius))
                minY = min(minY, Double(center.y - radius))
                maxY = max(maxY, Double(center.y + radius))
                hasGeometry = true
            case .arc(let center, let radius, _, _):
                minX = min(minX, Double(center.x - radius))
                maxX = max(maxX, Double(center.x + radius))
                minY = min(minY, Double(center.y - radius))
                maxY = max(maxY, Double(center.y + radius))
                hasGeometry = true
            case .polyline(let points, _):
                for p in points {
                    minX = min(minX, Double(p.x))
                    maxX = max(maxX, Double(p.x))
                    minY = min(minY, Double(p.y))
                    maxY = max(maxY, Double(p.y))
                }
                if !points.isEmpty {
                    hasGeometry = true
                }
            }
        }
        
        let width: CGFloat = 800
        let height: CGFloat = 600
        let drawingBounds = hasGeometry ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : CGRect(x: -50, y: -50, width: 100, height: 100)
        let borderPadding: CGFloat = 40.0
        
        return QLPreviewReply(contextSize: CGSize(width: width, height: height), isBitmap: true) { context, reply in
            context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            
            guard hasGeometry else {
                return
            }
            
            let fitWidth = width - (borderPadding * 2)
            let fitHeight = height - (borderPadding * 2)
            
            let scaleX = fitWidth / drawingBounds.width
            let scaleY = fitHeight / drawingBounds.height
            let scale = min(scaleX > 0 ? scaleX : 1.0, scaleY > 0 ? scaleY : 1.0)
            
            let offsetX = width / 2.0 - drawingBounds.midX * scale
            let offsetY = height / 2.0 - drawingBounds.midY * scale
            
            context.setStrokeColor(CGColor(gray: 0.0, alpha: 1.0))
            context.setLineWidth(max(1.0, 2.0 / scale))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            
            context.translateBy(x: offsetX, y: offsetY)
            context.scaleBy(x: scale, y: scale)
            
            for ent in entities {
                switch ent {
                case .line(let start, let end):
                    context.beginPath()
                    context.move(to: start)
                    context.addLine(to: end)
                    context.strokePath()
                    
                case .circle(let center, let radius):
                    context.beginPath()
                    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.strokePath()
                    
                case .arc(let center, let radius, let startAngle, let endAngle):
                    let startRad = startAngle * .pi / 180.0
                    let endRad = endAngle * .pi / 180.0
                    context.beginPath()
                    context.addArc(center: center, radius: radius, startAngle: startRad, endAngle: endRad, clockwise: false)
                    context.strokePath()
                    
                case .polyline(let points, let isClosed):
                    guard !points.isEmpty else { continue }
                    context.beginPath()
                    context.move(to: points[0])
                    for p in points.dropFirst() {
                        context.addLine(to: p)
                    }
                    if isClosed {
                        context.closePath()
                    }
                    context.strokePath()
                }
            }
        }
    }
}
