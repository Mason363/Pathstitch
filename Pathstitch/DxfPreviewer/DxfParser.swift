import Foundation
import CoreGraphics

public enum PreviewEntity {
    case line(start: CGPoint, end: CGPoint)
    case circle(center: CGPoint, radius: CGFloat)
    case arc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat)
    case polyline(points: [CGPoint], closed: Bool)
}

public struct DXFParser {
    public static func parse(url: URL) -> [PreviewEntity] {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return parse(content: content)
        }
        if let content = try? String(contentsOf: url, encoding: .ascii) {
            return parse(content: content)
        }
        if let data = try? Data(contentsOf: url),
           let content = String(data: data, encoding: .ascii) {
            return parse(content: content)
        }
        return []
    }
    
    private static func flattenBulge(p1: CGPoint, p2: CGPoint, bulge: Double) -> [CGPoint] {
        if abs(bulge) < 1e-5 {
            return [p1, p2]
        }
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let D = hypot(dx, dy)
        if D < 1e-4 {
            return [p1, p2]
        }
        
        let R = D * (1.0 + bulge * bulge) / (4.0 * abs(bulge))
        let h = (D / 2.0) * (1.0 - bulge * bulge) / (2.0 * bulge)
        
        let ux = dx / D
        let uy = dy / D
        let nx = -uy
        let ny = ux
        
        let cx = (p1.x + p2.x) / 2.0 + CGFloat(h) * nx
        let cy = (p1.y + p2.y) / 2.0 + CGFloat(h) * ny
        
        let a1 = atan2(p1.y - cy, p1.x - cx)
        var a2 = atan2(p2.y - cy, p2.x - cx)
        
        var diff = a2 - a1
        if bulge > 0 {
            if diff < 0 {
                diff += 2.0 * .pi
            }
        } else {
            if diff > 0 {
                diff -= 2.0 * .pi
            }
        }
        
        let steps = 16
        var pts: [CGPoint] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let angle = a1 + diff * CGFloat(t)
            pts.append(CGPoint(x: cx + R * cos(angle), y: cy + R * sin(angle)))
        }
        return pts
    }
    
    public static func parse(content: String) -> [PreviewEntity] {
        var entities: [PreviewEntity] = []
        
        var lines: [Substring] = []
        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(Substring(trimmed))
            }
        }
        
        var pairs: [(code: Int, value: Substring)] = []
        pairs.reserveCapacity(lines.count / 2)
        
        var i = 0
        while i < lines.count - 1 {
            let line1 = lines[i]
            let line2 = lines[i+1]
            if let code = Int(line1) {
                pairs.append((code: code, value: line2))
            }
            i += 2
        }
        
        var index = 0
        let count = pairs.count
        
        while index < count {
            let pair = pairs[index]
            if pair.code == 0 {
                let entType = pair.value.uppercased()
                index += 1
                
                var props: [Int: Substring] = [:]
                while index < count && pairs[index].code != 0 {
                    let p = pairs[index]
                    props[p.code] = p.value
                    index += 1
                }
                
                switch entType {
                case "LINE":
                    if let x1Str = props[10], let y1Str = props[20],
                       let x2Str = props[11], let y2Str = props[21],
                       let x1 = Double(x1Str), let y1 = Double(y1Str),
                       let x2 = Double(x2Str), let y2 = Double(y2Str) {
                        // Ignore points/degenerate lines
                        if hypot(x2 - x1, y2 - y1) >= 0.01 {
                            entities.append(.line(start: CGPoint(x: x1, y: y1), end: CGPoint(x: x2, y: y2)))
                        }
                    }
                case "CIRCLE":
                    if let cxStr = props[10], let cyStr = props[20], let rStr = props[40],
                       let cx = Double(cxStr), let cy = Double(cyStr), let r = Double(rStr) {
                        // Ignore point-like circles
                        if r >= 0.01 {
                            entities.append(.circle(center: CGPoint(x: cx, y: cy), radius: CGFloat(r)))
                        }
                    }
                case "ARC":
                    if let cxStr = props[10], let cyStr = props[20], let rStr = props[40],
                       let startStr = props[50], let endStr = props[51],
                       let cx = Double(cxStr), let cy = Double(cyStr), let r = Double(rStr),
                       let startAngle = Double(startStr), let endAngle = Double(endStr) {
                        if r >= 0.01 {
                            entities.append(.arc(center: CGPoint(x: cx, y: cy), radius: CGFloat(r),
                                                 startAngle: CGFloat(startAngle), endAngle: CGFloat(endAngle)))
                        }
                    }
                case "LWPOLYLINE":
                    var vertexCoords: [CGPoint] = []
                    var bulges: [Double] = []
                    var closedFlag = 0
                    if let cfStr = props[70], let cf = Int(cfStr) {
                        closedFlag = cf
                    }
                    let isClosed = (closedFlag & 1) != 0
                    
                    var entIndex = index - props.count - 1
                    while entIndex < index {
                        let p = pairs[entIndex]
                        if p.code == 10 {
                            var yVal: Double? = nil
                            var bulgeVal: Double = 0.0
                            var scanIndex = entIndex + 1
                            while scanIndex < index {
                                let sp = pairs[scanIndex]
                                if sp.code == 20 {
                                    yVal = Double(sp.value)
                                } else if sp.code == 42 {
                                    bulgeVal = Double(sp.value) ?? 0.0
                                } else if sp.code == 10 || sp.code == 0 {
                                    break
                                }
                                scanIndex += 1
                            }
                            if let xVal = Double(p.value), let yVal = yVal {
                                vertexCoords.append(CGPoint(x: xVal, y: yVal))
                                bulges.append(bulgeVal)
                            }
                        }
                        entIndex += 1
                    }
                    
                    var flattenedPts: [CGPoint] = []
                    if !vertexCoords.isEmpty {
                        for idx in 0..<vertexCoords.count {
                            let p1 = vertexCoords[idx]
                            let bulge = idx < bulges.count ? bulges[idx] : 0.0
                            
                            if idx < vertexCoords.count - 1 {
                                let p2 = vertexCoords[idx + 1]
                                if abs(bulge) > 1e-5 {
                                    let arcPts = flattenBulge(p1: p1, p2: p2, bulge: bulge)
                                    flattenedPts.append(contentsOf: arcPts.dropLast())
                                } else {
                                    flattenedPts.append(p1)
                                }
                            } else {
                                if isClosed {
                                    let p2 = vertexCoords[0]
                                    if abs(bulge) > 1e-5 {
                                        let arcPts = flattenBulge(p1: p1, p2: p2, bulge: bulge)
                                        flattenedPts.append(contentsOf: arcPts.dropLast())
                                    } else {
                                        flattenedPts.append(p1)
                                    }
                                } else {
                                    flattenedPts.append(p1)
                                }
                            }
                        }
                    }
                    if flattenedPts.count >= 2 {
                        entities.append(.polyline(points: flattenedPts, closed: isClosed))
                    }
                case "POLYLINE":
                    var vertexCoords: [CGPoint] = []
                    var bulges: [Double] = []
                    var closedFlag = 0
                    if let cfStr = props[70], let cf = Int(cfStr) {
                        closedFlag = cf
                    }
                    let isClosed = (closedFlag & 1) != 0
                    
                    while index < count {
                        let subPair = pairs[index]
                        if subPair.code == 0 {
                            let subType = subPair.value.uppercased()
                            if subType == "SEQEND" {
                                index += 1
                                break
                            } else if subType == "VERTEX" {
                                index += 1
                                var vProps: [Int: Substring] = [:]
                                while index < count && pairs[index].code != 0 {
                                    let vp = pairs[index]
                                    vProps[vp.code] = vp.value
                                    index += 1
                                }
                                if let vxStr = vProps[10], let vyStr = vProps[20],
                                   let vx = Double(vxStr), let vy = Double(vyStr) {
                                    vertexCoords.append(CGPoint(x: vx, y: vy))
                                    let bVal = Double(vProps[42] ?? "") ?? 0.0
                                    bulges.append(bVal)
                                }
                            } else {
                                break
                            }
                        } else {
                            index += 1
                        }
                    }
                    
                    var flattenedPts: [CGPoint] = []
                    if !vertexCoords.isEmpty {
                        for idx in 0..<vertexCoords.count {
                            let p1 = vertexCoords[idx]
                            let bulge = idx < bulges.count ? bulges[idx] : 0.0
                            
                            if idx < vertexCoords.count - 1 {
                                let p2 = vertexCoords[idx + 1]
                                if abs(bulge) > 1e-5 {
                                    let arcPts = flattenBulge(p1: p1, p2: p2, bulge: bulge)
                                    flattenedPts.append(contentsOf: arcPts.dropLast())
                                } else {
                                    flattenedPts.append(p1)
                                }
                            } else {
                                if isClosed {
                                    let p2 = vertexCoords[0]
                                    if abs(bulge) > 1e-5 {
                                        let arcPts = flattenBulge(p1: p1, p2: p2, bulge: bulge)
                                        flattenedPts.append(contentsOf: arcPts.dropLast())
                                    } else {
                                        flattenedPts.append(p1)
                                    }
                                } else {
                                    flattenedPts.append(p1)
                                }
                            }
                        }
                    }
                    if flattenedPts.count >= 2 {
                        entities.append(.polyline(points: flattenedPts, closed: isClosed))
                    }
                case "SPLINE":
                    var pts: [CGPoint] = []
                    var closedFlag = 0
                    if let cfStr = props[70], let cf = Int(cfStr) {
                        closedFlag = cf
                    }
                    let isClosed = (closedFlag & 1) != 0
                    
                    var entIndex = index - props.count - 1
                    while entIndex < index {
                        let p = pairs[entIndex]
                        if p.code == 10 {
                            var yVal: Double? = nil
                            var scanIndex = entIndex + 1
                            while scanIndex < index {
                                let sp = pairs[scanIndex]
                                if sp.code == 20 {
                                    yVal = Double(sp.value)
                                    break
                                } else if sp.code == 10 || sp.code == 0 {
                                    break
                                }
                                scanIndex += 1
                            }
                            if let xVal = Double(p.value), let yVal = yVal {
                                pts.append(CGPoint(x: xVal, y: yVal))
                            }
                        }
                        entIndex += 1
                    }
                    if pts.count >= 2 {
                        entities.append(.polyline(points: pts, closed: isClosed))
                    }
                default:
                    break
                }
            } else {
                index += 1
            }
        }
        
        return entities
    }
}
