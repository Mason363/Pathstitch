import Cocoa
import Quartz
import QuickLookUI
import SceneKit
import CoreGraphics
import simd

/// View-based QuickLook preview (MAS-124).
///
/// DXF / `.stch` files render to a static vector bitmap shown in an image view
/// (same renderer as before). STEP files get a native, interactive SceneKit
/// scene the user can drag to rotate — replacing the old static isometric
/// bitmap — so it's lightning-fast and genuinely 3D without three.js. A full
/// B-rep mesh needs OpenCASCADE, which can't run inside a QuickLook extension,
/// so STEP is shown as a dense, depth-shaded, rotatable point cloud parsed from
/// the file's CARTESIAN_POINTs.
class PreviewViewController: NSViewController, QLPreviewingController {

    override func loadView() {
        // Programmatic root view; the actual content is added per-file.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        root.wantsLayer = true
        root.layer?.backgroundColor = CGColor(gray: 1.0, alpha: 1.0)
        self.view = root
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let ext = url.pathExtension.lowercased()

        // Finder previews can be turned off per-format in Settings (MAS-155).
        // When off, decline so QuickLook falls back to its generic preview.
        guard QuickLookPreviewSettings.isEnabled(forExtension: ext) else {
            handler(NSError(domain: "com.chen.Pathstitch.QuickLook", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Preview disabled for .\(ext) in Pathstitch settings."]))
            return
        }

        let isAccessing = url.startAccessingSecurityScopedResource()
        if ext == "step" || ext == "stp" {
            // Prefer a real tessellated B-rep mesh (foxtrot). It's a genuine solid
            // — no stray reference points — and stays light (tens of ms). Fall
            // back to the legacy point cloud, then a static bitmap, so the preview
            // is never blank (MAS-157).
            if let mesh = loadStepMesh(url: url) {
                if isAccessing { url.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async {
                    self.installMeshSceneView(mesh: mesh)
                    handler(nil)
                }
                return
            }
            let points = parseStepPointCloud(url: url)
            if points.count < 2 {
                let size = CGSize(width: 1200, height: 800)
                let image = renderStepToImage(url: url, size: size)
                if isAccessing { url.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async {
                    self.installImageView(cgImage: image, size: size)
                    handler(nil)
                }
                return
            }
            if isAccessing { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                self.installSceneView(points: points)
                handler(nil)
            }
        } else {
            let size = CGSize(width: 1200, height: 800)
            let image = renderFileToImage(url: url, size: size)
            if isAccessing { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                self.installImageView(cgImage: image, size: size)
                handler(nil)
            }
        }
    }

    // MARK: - DXF / .stch (static vector bitmap)

    private func installImageView(cgImage: CGImage?, size: CGSize) {
        let imageView = NSImageView(frame: view.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        if let cgImage {
            imageView.image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        replaceContent(with: imageView)
    }

    // MARK: - STEP (interactive 3D point cloud)

    private func installSceneView(points: [SIMD3<Float>]) {
        let scnView = SCNView(frame: view.bounds)
        scnView.autoresizingMask = [.width, .height]
        scnView.allowsCameraControl = true          // drag to rotate / scroll to zoom
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = .white
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scnView.scene = scene

        if points.count >= 2, let cloudNode = makePointCloudNode(points: points) {
            scene.rootNode.addChildNode(cloudNode)

            // Frame the cloud with an orbit-friendly camera.
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(0, 0, 3.2)
            scene.rootNode.addChildNode(cameraNode)
            scnView.pointOfView = cameraNode
        }

        replaceContent(with: scnView)
    }

    // MARK: - STEP (interactive 3D triangle mesh, foxtrot) — MAS-157

    private func installMeshSceneView(mesh: StepMeshData) {
        let scnView = SCNView(frame: view.bounds)
        scnView.autoresizingMask = [.width, .height]
        scnView.allowsCameraControl = true          // drag to rotate / scroll to zoom
        // Explicit lighting instead of `autoenablesDefaultLighting` (a single
        // camera-mounted omni with NO ambient term). The foxtrot tessellation of
        // curved B-rep faces leaves thin, near-edge-on triangle strips along the
        // surface seams; under a single light those strips get ~0 diffuse and
        // rendered as the jagged BLACK lines users saw across the part. An ambient
        // floor guarantees no triangle goes black — matching the thumbnail
        // renderer, which already clamps shading to a 0.30 grey floor (MAS-157).
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = .white
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scnView.scene = scene
        addStudioLighting(to: scene)

        if let node = makeMeshNode(mesh: mesh) {
            scene.rootNode.addChildNode(node)
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(0, 0, 4.0)
            scene.rootNode.addChildNode(cameraNode)
            scnView.pointOfView = cameraNode
        }
        replaceContent(with: scnView)
    }

    /// Builds an SCNGeometry from the tessellated mesh (positions + normals +
    /// triangle indices), recentered and unit-scaled so the camera frames it.
    private func makeMeshNode(mesh: StepMeshData) -> SCNNode? {
        let vc = mesh.vertexCount
        guard vc > 0, mesh.indices.count >= 3 else { return nil }

        var minB = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0..<vc {
            let b = i * 6
            let p = SIMD3<Float>(mesh.interleaved[b], mesh.interleaved[b + 1], mesh.interleaved[b + 2])
            minB = simd_min(minB, p); maxB = simd_max(maxB, p)
        }
        let center = (minB + maxB) * 0.5
        let extent = maxB - minB
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        let scale = maxExtent > 1e-6 ? 2.0 / maxExtent : 1.0

        var raw = [SIMD3<Float>](); raw.reserveCapacity(vc)
        var positions = [SCNVector3](); positions.reserveCapacity(vc)
        for i in 0..<vc {
            let b = i * 6
            let p = SIMD3<Float>(mesh.interleaved[b], mesh.interleaved[b + 1], mesh.interleaved[b + 2])
            raw.append(p)
            let q = (p - center) * scale
            positions.append(SCNVector3(CGFloat(q.x), CGFloat(q.y), CGFloat(q.z)))
        }

        // Recompute smooth normals instead of using foxtrot's per-vertex normals.
        // Foxtrot tessellates each B-rep face as its own patch and DUPLICATES the
        // vertices along shared seams, giving the two sides different normals
        // (measured: 1000+ coincident vertices disagreeing by up to 90°). SceneKit
        // interpolates those per fragment, so every seam — even one running across
        // a smooth curved face — shows up as a hard crease/stripe. Welding
        // coincident vertices and averaging incident face normals erases the seam;
        // a crease threshold keeps genuinely sharp edges (e.g. 90° box faces) crisp
        // by only blending faces whose orientation actually agrees.
        let smooth = Self.smoothNormals(positions: raw, indices: mesh.indices, creaseDegrees: 50)
        let normals = smooth.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = NSColor(white: 0.78, alpha: 1.0)
        material.lightingModel = .blinn
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        // Slight iso-ish tilt so it doesn't open edge-on.
        node.eulerAngles = SCNVector3(-CGFloat.pi / 7, CGFloat.pi / 5, 0)
        return node
    }

    /// Builds a recentered, unit-scaled point-cloud geometry with subtle
    /// per-point depth shading so the form reads in 3D.
    private func makePointCloudNode(points: [SIMD3<Float>]) -> SCNNode? {
        guard !points.isEmpty else { return nil }

        // Robust per-axis bounds (2nd–98th percentile) so stray origin/reference
        // points in the STEP file don't shrink the real part to a dot (MAS-157).
        func robust(_ vals: [Float]) -> (Float, Float) {
            guard vals.count >= 12 else { return (vals.min() ?? 0, vals.max() ?? 1) }
            let s = vals.sorted()
            let lo = s[Int(0.02 * Float(s.count - 1))]
            let hi = s[Int(0.98 * Float(s.count - 1))]
            return hi > lo ? (lo, hi) : (s.first!, s.last!)
        }
        let (minX, maxX) = robust(points.map { $0.x })
        let (minY, maxY) = robust(points.map { $0.y })
        let (minZ, maxZ) = robust(points.map { $0.z })
        let minB = SIMD3<Float>(minX, minY, minZ)
        let maxB = SIMD3<Float>(maxX, maxY, maxZ)
        let center = (minB + maxB) * 0.5
        let extent = maxB - minB
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        let scale = maxExtent > 1e-6 ? 2.0 / maxExtent : 1.0

        // Normalize into a unit-ish box centered at the origin.
        let normalized = points.map { ($0 - center) * scale }

        let vertices = normalized.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) }
        let vertexSource = SCNGeometrySource(vertices: vertices)

        // Depth-shade points along Z so the cloud has visible relief.
        var zMin = Float.greatestFiniteMagnitude, zMax = -Float.greatestFiniteMagnitude
        for v in normalized { zMin = min(zMin, v.z); zMax = max(zMax, v.z) }
        let zSpan = max(zMax - zMin, 1e-6)
        // Pack colors as 32-bit floats. SceneKit's color source expects
        // single-precision components; feeding it 8-byte CGFloat (the size of
        // SCNVector3's fields on macOS) made it misread the buffer and render
        // nothing — i.e. a blank white preview (MAS-157).
        var colorFloats: [Float] = []
        colorFloats.reserveCapacity(normalized.count * 3)
        for v in normalized {
            let t = (v.z - zMin) / zSpan                 // 0 (far) … 1 (near)
            colorFloats.append(0.12 + 0.30 * t)          // r — dark slate → blue-grey
            colorFloats.append(0.14 + 0.32 * t)          // g
            colorFloats.append(0.22 + 0.40 * t)          // b
        }
        let colorData = colorFloats.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: normalized.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )

        let indices = (0..<UInt32(vertices.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        // Scale point size with cloud density so sparse parts stay visible and
        // dense parts don't blob together.
        element.pointSize = 4.0
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 5.0

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant            // colors come straight from the cloud
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        // Slight tilt so the part isn't seen perfectly edge-on initially.
        node.eulerAngles = SCNVector3(-CGFloat.pi / 8, CGFloat.pi / 8, 0)
        return node
    }

    /// Crease-aware smooth normals via per-position *smoothing groups*. Welds the
    /// vertices foxtrot splits along every B-rep seam, then partitions the faces
    /// meeting at each welded position into groups of mutually-smooth faces and
    /// gives every vertex in a group one shared, area-weighted normal.
    ///
    /// The previous implementation seeded each duplicate vertex's normal from its
    /// OWN faces and flooded outward by `creaseDegrees`. That comparison is
    /// asymmetric: on a curved surface the two sides of a seam pick different face
    /// sets, so coincident vertices ended up with slightly different normals —
    /// SceneKit interpolated the mismatch into the thin bright/dark STRIPES users
    /// saw running along the seams. Grouping the faces with symmetric, transitive
    /// union-find removes that asymmetry entirely: any two faces within the crease
    /// angle (directly or via intermediate faces) land in the same group and share
    /// a normal, so a smooth surface is seamless regardless of which duplicate you
    /// look at, while a genuine hard edge (faces beyond the crease angle, not
    /// transitively connected) still splits into separate groups and stays crisp.
    static func smoothNormals(positions pos: [SIMD3<Float>], indices: [UInt32],
                              creaseDegrees: Float) -> [SIMD3<Float>] {
        let triCount = indices.count / 3
        // Unit normal (for crease comparison) and area-scaled normal (so larger
        // faces dominate the average) for every triangle.
        var faceUnit = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: triCount)
        var faceArea = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: triCount)
        for t in 0..<triCount {
            let a = pos[Int(indices[t*3])], b = pos[Int(indices[t*3+1])], c = pos[Int(indices[t*3+2])]
            let cr = simd_cross(b - a, c - a)          // length == 2 × area
            faceArea[t] = cr
            let len = simd_length(cr)
            if len > 1e-12 { faceUnit[t] = cr / len }
        }
        // Triangles touching each vertex index, and a position hash → indices map
        // so we can find the coincident vertices foxtrot split apart.
        var triOfIndex = [[Int]](repeating: [], count: pos.count)
        for t in 0..<triCount {
            for k in 0..<3 { triOfIndex[Int(indices[t*3+k])].append(t) }
        }
        func key(_ p: SIMD3<Float>) -> Int64 {
            let qx = Int64((p.x * 1000).rounded()), qy = Int64((p.y * 1000).rounded()), qz = Int64((p.z * 1000).rounded())
            return (qx &* 73856093) ^ (qy &* 19349663) ^ (qz &* 83492791)
        }
        var byPos = [Int64: [Int]]()
        for vi in 0..<pos.count where !triOfIndex[vi].isEmpty {
            byPos[key(pos[vi]), default: []].append(vi)
        }
        let cosThresh = cos(creaseDegrees * .pi / 180)
        var out = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: pos.count)

        for (_, group) in byPos {
            // Unique triangles meeting at this welded position.
            var seen = Set<Int>()
            var tris: [Int] = []
            for vi in group { for t in triOfIndex[vi] where seen.insert(t).inserted { tris.append(t) } }
            let n = tris.count
            if n == 0 { continue }

            // Union-find over the faces: connect any two within the crease angle.
            // Transitivity lets a curved fan (each facet smooth to its neighbour)
            // collapse into a single group even when its extremes exceed the angle.
            var parent = Array(0..<n)
            func find(_ x: Int) -> Int {
                var r = x
                while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
                return r
            }
            for i in 0..<n {
                for j in (i+1)..<n where simd_dot(faceUnit[tris[i]], faceUnit[tris[j]]) >= cosThresh {
                    let ri = find(i), rj = find(j)
                    if ri != rj { parent[ri] = rj }
                }
            }
            // Area-weighted normal per smoothing group.
            var groupNormal = [Int: SIMD3<Float>]()
            for i in 0..<n { groupNormal[find(i), default: SIMD3<Float>(0, 0, 0)] += faceArea[tris[i]] }
            var groupUnit = [Int: SIMD3<Float>]()
            for (r, acc) in groupNormal {
                let l = simd_length(acc)
                groupUnit[r] = l > 1e-12 ? acc / l : faceUnit[tris[r]]
            }
            // Assign each welded vertex the normal of the group its faces belong to.
            // foxtrot duplicates per B-rep face, so a duplicate's faces share one
            // group; the shared normal is what makes the seam vanish.
            for i in 0..<n {
                let normal = groupUnit[find(i)]!
                let t = tris[i]
                let corners = [Int(indices[t*3]), Int(indices[t*3+1]), Int(indices[t*3+2])]
                for vi in group where corners.contains(vi) { out[vi] = normal }
            }
        }
        return out
    }

    // MARK: - Lighting

    /// Ambient floor + key/fill directional lights for the STEP mesh scene. The
    /// ambient term is what kills the black seam lines (no fragment can fall below
    /// it); the two directionals give the part readable 3D shape from any orbit
    /// angle. Tuned so an edge-on triangle lands around mid-grey, never black.
    private func addStudioLighting(to scene: SCNScene) {
        func light(_ type: SCNLight.LightType, _ white: CGFloat) -> SCNLight {
            let l = SCNLight(); l.type = type; l.color = NSColor(white: white, alpha: 1.0); return l
        }
        // Modest ambient (just a safety floor against any residual edge-on
        // triangle) plus a strong key and a softer fill, so the part keeps clear
        // light-to-shadow falloff and reads as solid 3D rather than flat grey.
        let ambient = SCNNode()
        ambient.light = light(.ambient, 0.28)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = light(.directional, 0.85)
        key.eulerAngles = SCNVector3(-CGFloat.pi / 4, CGFloat.pi / 6, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = light(.directional, 0.40)
        fill.eulerAngles = SCNVector3(CGFloat.pi / 3, -CGFloat.pi / 3, 0)
        scene.rootNode.addChildNode(fill)
    }

    // MARK: - Helpers

    private func replaceContent(with content: NSView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        content.frame = view.bounds
        view.addSubview(content)
    }
}
