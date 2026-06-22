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
            let points = parseStepPointCloud(url: url)
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

    /// Builds a recentered, unit-scaled point-cloud geometry with subtle
    /// per-point depth shading so the form reads in 3D.
    private func makePointCloudNode(points: [SIMD3<Float>]) -> SCNNode? {
        guard !points.isEmpty else { return nil }

        var minB = points[0], maxB = points[0]
        for p in points {
            minB = simd_min(minB, p)
            maxB = simd_max(maxB, p)
        }
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
        var colors: [SCNVector3] = []
        colors.reserveCapacity(normalized.count)
        for v in normalized {
            let t = CGFloat((v.z - zMin) / zSpan)        // 0 (far) … 1 (near)
            // Dark slate → lighter blue-grey with depth.
            let r = 0.12 + 0.30 * t
            let g = 0.14 + 0.32 * t
            let b = 0.22 + 0.40 * t
            colors.append(SCNVector3(r, g, b))
        }
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector3>.size)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<CGFloat>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector3>.size
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

    // MARK: - Helpers

    private func replaceContent(with content: NSView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        content.frame = view.bounds
        view.addSubview(content)
    }
}
