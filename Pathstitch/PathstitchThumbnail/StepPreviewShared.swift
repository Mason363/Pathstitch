import CoreGraphics
import Foundation
import simd

/// Reads every CARTESIAN_POINT from a STEP file as a 3D point cloud, for the
/// interactive SceneKit preview (MAS-124). Returns model-space coordinates;
/// the view controller handles centering/scaling.
public func parseStepPointCloud(url: URL) -> [SIMD3<Float>] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) else {
        return []
    }
    return parseStepCartesianPoints(text).map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
}

/// Lightweight STEP (.step/.stp) preview for QuickLook (MAS-63). A full B-rep
/// tessellation needs OpenCASCADE, which can't run inside a QuickLook app
/// extension. Instead we parse the ISO-10303-21 text for every CARTESIAN_POINT
/// and render an isometric point cloud — fast, allocation-light, and enough to
/// recognize the part at a glance. Dark points on white, aspect-fit to `size`.
func renderStepToImage(url: URL, size: CGSize) -> CGImage? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) else {
        return nil
    }

    let points = parseStepCartesianPoints(text)
    guard points.count >= 2 else { return nil }

    // Isometric projection of each 3D point to 2D.
    let c30 = cos(Double.pi / 6), s30 = sin(Double.pi / 6)
    var projected: [(x: Double, y: Double)] = []
    projected.reserveCapacity(points.count)
    var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
    for p in points {
        let sx = (p.x - p.y) * c30
        let sy = (p.x + p.y) * s30 - p.z
        projected.append((sx, sy))
        minX = min(minX, sx); minY = min(minY, sy)
        maxX = max(maxX, sx); maxY = max(maxY, sy)
    }

    let w = Int(size.width), h = Int(size.height)
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    let spanX = max(maxX - minX, 1e-6), spanY = max(maxY - minY, 1e-6)
    let margin = 0.1 * min(size.width, size.height)
    let scale = min((size.width - 2 * margin) / spanX, (size.height - 2 * margin) / spanY)
    let offX = (size.width - spanX * scale) / 2.0
    let offY = (size.height - spanY * scale) / 2.0

    ctx.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.2, alpha: 0.85))
    let r: CGFloat = max(1.0, CGFloat(min(w, h)) / 600.0)
    for pt in projected {
        let px = offX + (pt.x - minX) * scale
        let py = offY + (pt.y - minY) * scale
        ctx.fillEllipse(in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
    }

    return ctx.makeImage()
}

/// Extracts the (x, y, z) of every CARTESIAN_POINT in a STEP file. Tolerant of
/// scientific notation, whitespace, and the leading label string.
private func parseStepCartesianPoints(_ text: String) -> [(x: Double, y: Double, z: Double)] {
    var result: [(Double, Double, Double)] = []
    // Match: CARTESIAN_POINT ( 'label' , ( 1.0, 2.0, 3.0 ) )
    let pattern = "CARTESIAN_POINT\\s*\\(\\s*'[^']*'\\s*,\\s*\\(([^)]*)\\)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return result
    }
    let ns = text as NSString
    regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
        guard let match = match, match.numberOfRanges >= 2 else { return }
        let nums = ns.substring(with: match.range(at: 1))
        let parts = nums.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0
        }
        // Only keep true 3D model points. 2-coordinate CARTESIAN_POINTs are
        // surface parameter-space (pcurve) points living in an unrelated
        // coordinate range; including them as (x, y, 0) dumped a sheet of noise at
        // z = 0 over the part and made the STEP preview unreadable (MAS-155).
        if parts.count >= 3 {
            result.append((parts[0], parts[1], parts[2]))
        }
    }
    return result
}
