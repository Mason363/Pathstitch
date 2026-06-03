import SwiftUI
import Foundation

enum AppMode {
    case twoD
    case threeD
}

enum TwoDTool: String, CaseIterable {
    case select = "Select (V)"
    case chainSelect = "Chain Select (A)"
    case pan = "Pan (H)"
    case offset = "Offset (O)"
    case addHoles = "Add Holes (S)"
    case cleanup = "Join/Cleanup (J)"
    case measure = "Measure (M)"
    
    var icon: String {
        switch self {
        case .select: return "arrow.up.left.pointer"
        case .chainSelect: return "link"
        case .pan: return "hand.raised"
        case .offset: return "arrow.up.and.down"
        case .addHoles: return "circle.dashed"
        case .cleanup: return "sparkles"
        case .measure: return "ruler"
        }
    }
}

struct DXFEntity: Identifiable, Codable {
    var id: String { handle }
    let handle: String
    let type: String
    let layer: String
    let color: Int
    
    // Geometry bounds or representation helper
    let start: [Double]?
    let end: [Double]?
    let center: [Double]?
    let radius: Double?
    let start_angle: Double?
    let end_angle: Double?
    let vertices: [[Double]]?
    let closed: Bool?
}

struct DXFLayer: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var color: Color
    var visible: Bool = true
}

@Observable
class AppState {
    var activeMode: AppMode = .twoD
    var currentFilePath: URL?
    var svgContent: String?
    
    // 2D Canvas State
    var currentTool: TwoDTool = .select
    var selectedHandles: Set<String> = []
    var entities: [DXFEntity] = []
    var layers: [DXFLayer] = []
    var canvasScale: CGFloat = 1.0
    var canvasOffset: CGSize = .zero
    var gridVisible: Bool = true
    
    // Operations Configs
    var offsetDistance: Double = 1.0
    var offsetSide: String = "left"
    
    var holeOffsetDistance: Double = 2.0
    var holeDiameter: Double = 1.0
    var holeSpacing: Double = 4.0
    var holePattern: String = "single" // "single" or "saddle"
    var holeCornerBehavior: String = "skip" // "skip" or "wrap"
    var holeSide: String = "left"
    var holeRowSpacing: Double = 3.0
    
    var cleanupTolerance: Double = 0.1
    
    // Measure Tool State
    var measureStartPoint: CGPoint?
    var measureEndPoint: CGPoint?
    var measuredDistanceMm: Double?
    
    // Status/Progress
    var isProcessing: Bool = false
    var progress: Double = 0.0
    var errorMessage: String?
    
    init() {}
    
    func loadFile(url: URL) {
        currentFilePath = url
        errorMessage = nil
        selectedHandles.removeAll()
        
        if url.pathExtension.lowercased() == "dxf" {
            activeMode = .twoD
            reloadDXF()
        } else if url.pathExtension.lowercased() == "step" || url.pathExtension.lowercased() == "stp" {
            activeMode = .threeD
            // STEP loading logic can be added later
        } else {
            errorMessage = "Unsupported file extension: .\(url.pathExtension)"
        }
    }
    
    func reloadDXF() {
        guard let url = currentFilePath else { return }
        
        isProcessing = true
        progress = 0.0
        
        Task {
            do {
                // Ensure temporary output directory exists
                let tempDir = URL(fileURLWithPath: "/tmp/pathstitch", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let svgOutputURL = tempDir.appendingPathComponent("preview.svg")
                
                // 1. Export SVG for rendering
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "export_svg",
                    args: ["input": url.path, "output": svgOutputURL.path]
                )
                
                let svgStr = try String(contentsOf: svgOutputURL, encoding: .utf8)
                
                // 2. List entities
                let listResult = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "list_entities",
                    args: ["input": url.path]
                )
                
                guard let data = listResult["data"] as? [String: Any],
                      let jsonEntities = data["entities"] as? [[String: Any]] else {
                    throw PythonBridgeError.invalidResponse("Missing entities array in output data.")
                }
                
                // Decode entities
                let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                let decodedEntities = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                
                // Extract unique layers
                let uniqueLayers = Array(Set(decodedEntities.map { $0.layer })).sorted()
                
                await MainActor.run {
                    self.svgContent = svgStr
                    self.entities = decodedEntities
                    self.layers = uniqueLayers.map { layerName in
                        // Basic default coloring or preserve visibility
                        let existing = self.layers.first(where: { $0.name == layerName })
                        return DXFLayer(
                            name: layerName,
                            color: existing?.color ?? self.colorForLayerName(layerName),
                            visible: existing?.visible ?? true
                        )
                    }
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func triggerChainSelect(seedHandle: String) {
        guard let url = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                let res = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "chain_select",
                    args: ["input": url.path, "seed_handle": seedHandle, "tolerance": 0.01]
                )
                
                guard let data = res["data"] as? [String: Any],
                      let handlesList = data["handles"] as? [String] else {
                    return
                }
                
                await MainActor.run {
                    self.selectedHandles.formUnion(handlesList)
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applyOffset() {
        guard let url = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                // To avoid modifying original file, output to a temp file first, then replace it or let user save.
                // In Pathstitch, we modify the loaded file so the editor reflects the offset in place.
                // According to rules: "never overwrite input". Wait! "Output files always go to user-specified path or /tmp/pathstitch/, never overwrite input".
                // If we don't overwrite input, how do we show the updated design? We write it to a temp DXF file at `/tmp/pathstitch/active.dxf`, and point currentFilePath to `/tmp/pathstitch/active.dxf`!
                // This is brilliant and fully respects the "never overwrite input" rule.
                
                let activeDxfURL = URL(fileURLWithPath: "/tmp/pathstitch/active.dxf")
                let inputPath = (url.path.contains("/tmp/pathstitch/active.dxf") ? url.path : url.path)
                
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "offset_lines",
                    args: [
                        "input": inputPath,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "distance": offsetDistance,
                        "side": offsetSide,
                        "layer": "OFFSET"
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applySewingHoles() {
        guard let url = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = URL(fileURLWithPath: "/tmp/pathstitch/active.dxf")
                
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "add_holes",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "offset_distance": holeOffsetDistance,
                        "hole_diameter": holeDiameter,
                        "hole_spacing": holeSpacing,
                        "pattern": holePattern,
                        "corner_behavior": holeCornerBehavior,
                        "side": holeSide,
                        "row_spacing": holeRowSpacing
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applyCleanup() {
        guard let url = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = URL(fileURLWithPath: "/tmp/pathstitch/active.dxf")
                
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "cleanup",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "tolerance": cleanupTolerance
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func exportFinalDXF(to url: URL) {
        guard let currentUrl = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                try FileManager.default.copyItem(at: currentUrl, to: url)
                await MainActor.run {
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    private func colorForLayerName(_ name: String) -> Color {
        switch name.uppercased() {
        case "ORIGINAL": return Color(red: 228/255, green: 228/255, blue: 234/255) // primary primary text
        case "OFFSET": return Color.status_warn
        case "SEWING_HOLES": return Color.status_ok
        case "CUTLINE": return Color.accent
        default:
            // Hash the name to produce a deterministic color
            let hash = abs(name.hashValue)
            let r = Double((hash & 0xFF0000) >> 16) / 255.0
            let g = Double((hash & 0x00FF00) >> 8) / 255.0
            let b = Double(hash & 0x0000FF) / 255.0
            return Color(red: r, green: g, blue: b)
        }
    }
}
