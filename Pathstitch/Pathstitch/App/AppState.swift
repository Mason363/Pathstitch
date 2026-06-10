import SwiftUI
import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

enum NamingOption {
    case original
    case customIndex
}

enum AppMode {
    case twoD
    case threeD
    case batch
}

struct BatchItem: Identifiable, Hashable, Equatable {
    let id: UUID
    let fileURL: URL
    let originalName: String
    var isSelected: Bool
    var entities: [DXFEntity]
    var svgContent: String
    
    init(id: UUID = UUID(), fileURL: URL, originalName: String, isSelected: Bool = true, entities: [DXFEntity] = [], svgContent: String = "") {
        self.id = id
        self.fileURL = fileURL
        self.originalName = originalName
        self.isSelected = isSelected
        self.entities = entities
        self.svgContent = svgContent
    }
}

enum TwoDTool: String, CaseIterable {
    case select = "Select (V)"
    case pan = "Pan (H)"
    case offset = "Offset (O)"
    case addHoles = "Add Holes (S)"
    case cleanup = "Join/Cleanup (J)"
    case measure = "Measure (M)"
    case sketchLine = "Line (L)"
    case sketchCircle = "Circle (C)"
    case sketchRectangle = "Rectangle (R)"
    case sketchText = "Text (T)"
    
    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .pan: return "hand.raised"
        case .offset: return "arrow.up.and.down"
        case .addHoles: return "circle.dashed"
        case .cleanup: return "sparkles"
        case .measure: return "ruler"
        case .sketchLine: return "line.diagonal"
        case .sketchCircle: return "circle"
        case .sketchRectangle: return "rectangle"
        case .sketchText: return "character.cursor.ibeam"
        }
    }
}

struct MeasurementLine: Identifiable, Codable, Hashable {
    var id: UUID
    var start: CGPoint // Model space
    var end: CGPoint   // Model space
    var distanceMm: Double
    var isAutoDimension: Bool
    var entityHandle: String?
    var dimensionType: String? // "length", "radius", "width", "height"
    var rectP1: CGPoint?
    var rectP2: CGPoint?
    var filletRadius: Double = 0.0
    
    init(
        id: UUID = UUID(),
        start: CGPoint,
        end: CGPoint,
        distanceMm: Double,
        isAutoDimension: Bool = false,
        entityHandle: String? = nil,
        dimensionType: String? = nil,
        rectP1: CGPoint? = nil,
        rectP2: CGPoint? = nil,
        filletRadius: Double = 0.0
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.distanceMm = distanceMm
        self.isAutoDimension = isAutoDimension
        self.entityHandle = entityHandle
        self.dimensionType = dimensionType
        self.rectP1 = rectP1
        self.rectP2 = rectP2
        self.filletRadius = filletRadius
    }
}

struct HistoryState {
    let dxfData: Data?
    let measurements: [MeasurementLine]
    let selectedHandles: Set<String>
}

struct DXFEntity: Identifiable, Codable, Equatable, Hashable {
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
    let text: String?
    let height: Double?

    func translated(dx: Double, dy: Double) -> DXFEntity {
        DXFEntity(
            handle: handle,
            type: type,
            layer: layer,
            color: color,
            start: start.map { [$0[0] + dx, $0[1] + dy] },
            end: end.map { [$0[0] + dx, $0[1] + dy] },
            center: center.map { [$0[0] + dx, $0[1] + dy] },
            radius: radius,
            start_angle: start_angle,
            end_angle: end_angle,
            vertices: vertices.map { pts in pts.map { [$0[0] + dx, $0[1] + dy] } },
            closed: closed,
            text: text,
            height: height
        )
    }
}

struct DXFLayer: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var color: Color
    var visible: Bool = true
}

struct LogEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var action: String
    var details: String
    var layerAffected: String?
}

/// Snapshot of a single batch item, so .stch projects can round-trip a batch
/// session (MAS-24: ".stch files handle everything AND every new feature").
struct BatchItemSave: Codable {
    let originalName: String
    let dxfDataBase64: String
    let isSelected: Bool
    let svgContent: String
    let entities: [DXFEntity]
}

struct ProjectSaveContainer: Codable {
    let dxfDataBase64: String?
    let measurements: [MeasurementLine]
    let logEntries: [LogEntry]
    let canvasScale: Double
    let canvasOffsetX: Double
    let canvasOffsetY: Double
    
    let refImageBase64: String?
    let refImageOffsetX: Double
    let refImageOffsetY: Double
    let refImageScale: Double
    let refImageOpacity: Double
    let refImageCalibrationDistance: Double
    let refImageCalibrationStartX: Double?
    let refImageCalibrationStartY: Double?
    let refImageCalibrationEndX: Double?
    let refImageCalibrationEndY: Double?
    
    // Optional settings
    var isLearnModeEnabled: Bool? = nil
    var offsetDistance: Double? = nil
    var offsetSide: String? = nil
    var holeOffsetDistance: Double? = nil
    var holeDiameter: Double? = nil
    var holeSpacing: Double? = nil
    var holePattern: String? = nil
    var holeCornerBehavior: String? = nil
    var holeSide: String? = nil
    var holeRowSpacing: Double? = nil

    // Persisted batch session (optional / backward-compatible).
    var batchItems: [BatchItemSave]? = nil
}

@Observable
class AppState {
    var activeMode: AppMode = .twoD
    var currentFilePath: URL?
    var currentStepFilePath: URL?
    var currentProjectPath: URL? = nil
    var svgContent: String?
    
    var batchItems: [BatchItem] = []
    var activeEditingBatchItem: BatchItem? = nil
    
    var sessionTempDirectory: URL
    
    // Text shape tool properties
    var pendingTextInsert: CGPoint? = nil
    var pendingTextHeight: Double = 5.0
    var showTextInputDialog: Bool = false
    var textInputString: String = "Label"
    
    // Canvas Text editing properties
    var isEditingText: Bool = false
    var editingTextHandle: String? = nil
    var editingTextString: String = ""
    var editingTextInsert: CGPoint = .zero
    var editingTextHeight: Double = 5.0
    var escapePressedToken: Int = 0
    
    // Log entries
    var logEntries: [LogEntry] = []
    
    // Custom status states
    var hasUnsavedChanges: Bool = false
    var isLearnModeEnabled: Bool = true
    var isLogTrayExpanded: Bool = false
    var hoveredHandle: String? = nil
    
    // Reference Image properties
    var refImage: NSImage? = nil
    var refImageBase64: String? = nil
    var refImageOffset: CGSize = .zero
    var refImageScale: CGFloat = 1.0
    var refImageOpacity: Double = 0.5
    var isCalibrationActive: Bool = false
    var calibrationPoints: [CGPoint] = []
    var calibrationDistance: Double = 50.0

    
    // 2D Canvas State
    var currentTool: TwoDTool = .select
    var chainSelectionEnabled: Bool = false
    var selectedHandles: Set<String> = []
    var entities: [DXFEntity] = []
    var previewEntities: [DXFEntity] = []
    var layers: [DXFLayer] = []
    var canvasScale: CGFloat = 1.0
    var canvasOffset: CGSize = .zero
    var gridVisible: Bool = true
    /// Incremented to ask the 2D canvas to zoom/pan so all geometry is visible
    /// (e.g. after a multi-file distribute import). The canvas owns the view
    /// size, so it computes the actual fit — see `DxfCanvasView.fitToContent`.
    var fitRequestToken: Int = 0
    
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
    var holeEnableVariableSpacing: Bool = true
    var holeEnableProximityFilter: Bool = true
    var holeEnableCornerInterpolation: Bool = true
    var holeEnableLineProximityFilter: Bool = true
    var holeLineProximityThreshold: Double = 1.0
    var holeProximityDistance: Double = 3.0
    var holeVariableSpacingMin: Double = 4.0
    var holeVariableSpacingMax: Double = 5.0
    
    var consolidateSvgStrokes: Bool = true
    var cleanupTolerance: Double = 0.1
    
    // Sketch Tool configs
    var sketchFilletRadius: Double = 0.0
    var bboxOffsetDistance: Double = 5.0
    var bboxOffsetFillet: Double = 0.0
    
    // Measure Tool State
    var activeMeasureStart: CGPoint? // in model coordinates
    var measurements: [MeasurementLine] = []
    
    // 3D Canvas State
    var stepJsonContent: String?
    var selectedFaces3D: Set<SelectedFace> = []
    var bodies3D: [Body3D] = []
    
    // Status/Progress
    var isProcessing: Bool = false
    var progress: Double = 0.0
    var errorMessage: String?
    
    // History & Parametric Selection
    var undoStack: [HistoryState] = []
    var redoStack: [HistoryState] = []
    var selectedMeasurement: MeasurementLine? = nil
    
    func saveToHistory() {
        var dxfData: Data? = nil
        if let url = currentFilePath {
            dxfData = try? Data(contentsOf: url)
        }
        let state = HistoryState(
            dxfData: dxfData,
            measurements: measurements,
            selectedHandles: selectedHandles
        )
        undoStack.append(state)
        redoStack.removeAll()
    }
    
    func undo() {
        guard !undoStack.isEmpty else { return }

        // A history restore replaces the whole working buffer, so drop any
        // deferred optimistic deletions; a late reconcile must not clobber the
        // restored snapshot (MAS-21).
        pendingDeletedHandles.removeAll()
        reconcileTask?.cancel()

        var currentDxfData: Data? = nil
        if let url = currentFilePath {
            currentDxfData = try? Data(contentsOf: url)
        }
        let currentState = HistoryState(
            dxfData: currentDxfData,
            measurements: measurements,
            selectedHandles: selectedHandles
        )
        redoStack.append(currentState)
        
        let previousState = undoStack.removeLast()
        
        self.measurements = previousState.measurements
        self.selectedHandles = previousState.selectedHandles
        self.selectedMeasurement = nil
        
        if let dxfData = previousState.dxfData {
            let activeDxfURL = ensureActiveDXFFileExists()
            do {
                try dxfData.write(to: activeDxfURL)
                reloadDXF()
            } catch {
                errorMessage = "Undo failed to restore DXF file: \(error.localizedDescription)"
            }
        } else {
            currentFilePath = nil
            svgContent = nil
            entities = []
            previewEntities = []
            layers = []
        }
    }
    
    func redo() {
        guard !redoStack.isEmpty else { return }

        // See undo(): drop deferred optimistic deletions before a full restore.
        pendingDeletedHandles.removeAll()
        reconcileTask?.cancel()

        var currentDxfData: Data? = nil
        if let url = currentFilePath {
            currentDxfData = try? Data(contentsOf: url)
        }
        let currentState = HistoryState(
            dxfData: currentDxfData,
            measurements: measurements,
            selectedHandles: selectedHandles
        )
        undoStack.append(currentState)
        
        let nextState = redoStack.removeLast()
        
        self.measurements = nextState.measurements
        self.selectedHandles = nextState.selectedHandles
        self.selectedMeasurement = nil
        
        if let dxfData = nextState.dxfData {
            let activeDxfURL = ensureActiveDXFFileExists()
            do {
                try dxfData.write(to: activeDxfURL)
                reloadDXF()
            } catch {
                errorMessage = "Redo failed to restore DXF file: \(error.localizedDescription)"
            }
        } else {
            currentFilePath = nil
            svgContent = nil
            entities = []
            previewEntities = []
            layers = []
        }
    }
    
    func updateSelectedDimensionValue(newValue: Double) {
        guard let selected = selectedMeasurement,
              let handle = selected.entityHandle,
              let dimType = selected.dimensionType,
              let url = currentFilePath else { return }
        
        saveToHistory()
        isProcessing = true
        
        Task {
            do {
                var params: [String: Any] = [:]
                
                if dimType == "length" {
                    let currentLength = Double(hypot(selected.start.x - selected.end.x, selected.start.y - selected.end.y))
                    if currentLength > 1e-5 {
                        let scale = newValue / currentLength
                        let newEndX = selected.start.x + (selected.end.x - selected.start.x) * CGFloat(scale)
                        let newEndY = selected.start.y + (selected.end.y - selected.start.y) * CGFloat(scale)
                        params["start"] = [Double(selected.start.x), Double(selected.start.y)]
                        params["end"] = [Double(newEndX), Double(newEndY)]
                    }
                } else if dimType == "radius" {
                    params["radius"] = newValue
                    params["center"] = [Double(selected.start.x), Double(selected.start.y)]
                } else if dimType == "width" || dimType == "height" {
                    guard let p1 = selected.rectP1, let p2 = selected.rectP2 else { return }
                    
                    var newP2 = p2
                    if dimType == "width" {
                        let currentW = abs(p2.x - p1.x)
                        if currentW > 1e-5 {
                            let sign: CGFloat = p2.x >= p1.x ? 1.0 : -1.0
                            newP2.x = p1.x + sign * CGFloat(newValue)
                        }
                    } else if dimType == "height" {
                        let currentH = abs(p2.y - p1.y)
                        if currentH > 1e-5 {
                            let sign: CGFloat = p2.y >= p1.y ? 1.0 : -1.0
                            newP2.y = p1.y + sign * CGFloat(newValue)
                        }
                    }
                    
                    params["p1"] = [Double(p1.x), Double(p1.y)]
                    params["p2"] = [Double(newP2.x), Double(newP2.y)]
                    params["fillet_radius"] = sketchFilletRadius
                }
                
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "update_entity",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handle": handle,
                        "type": (dimType == "length") ? "line" : ((dimType == "radius") ? "circle" : "rectangle"),
                        "params": params
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    
                    if let idx = self.measurements.firstIndex(where: { $0.id == selected.id }) {
                        self.measurements[idx].distanceMm = newValue
                        if dimType == "length" {
                            let currentLength = Double(hypot(selected.start.x - selected.end.x, selected.start.y - selected.end.y))
                            if currentLength > 1e-5 {
                                let scale = newValue / currentLength
                                let newEndX = selected.start.x + (selected.end.x - selected.start.x) * CGFloat(scale)
                                let newEndY = selected.start.y + (selected.end.y - selected.start.y) * CGFloat(scale)
                                self.measurements[idx].end = CGPoint(x: newEndX, y: newEndY)
                                self.selectedMeasurement?.end = CGPoint(x: newEndX, y: newEndY)
                            }
                        } else if dimType == "radius" {
                            let endRad = CGPoint(x: selected.start.x + CGFloat(newValue), y: selected.start.y)
                            self.measurements[idx].end = endRad
                            self.selectedMeasurement?.end = endRad
                        } else if dimType == "width" || dimType == "height" {
                            guard let p1 = selected.rectP1, let p2 = selected.rectP2 else { return }
                            var newP2 = p2
                            if dimType == "width" {
                                let currentW = abs(p2.x - p1.x)
                                if currentW > 1e-5 {
                                    let sign: CGFloat = p2.x >= p1.x ? 1.0 : -1.0
                                    newP2.x = p1.x + sign * CGFloat(newValue)
                                }
                            } else if dimType == "height" {
                                let currentH = abs(p2.y - p1.y)
                                if currentH > 1e-5 {
                                    let sign: CGFloat = p2.y >= p1.y ? 1.0 : -1.0
                                    newP2.y = p1.y + sign * CGFloat(newValue)
                                }
                            }
                            
                            for mIdx in 0..<self.measurements.count {
                                if self.measurements[mIdx].entityHandle == handle {
                                    self.measurements[mIdx].rectP1 = p1
                                    self.measurements[mIdx].rectP2 = newP2
                                    if self.measurements[mIdx].dimensionType == "width" {
                                        let w = abs(newP2.x - p1.x)
                                        self.measurements[mIdx].start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                        self.measurements[mIdx].end = CGPoint(x: max(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                        self.measurements[mIdx].distanceMm = Double(w)
                                    } else if self.measurements[mIdx].dimensionType == "height" {
                                        let h = abs(newP2.y - p1.y)
                                        self.measurements[mIdx].start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                        self.measurements[mIdx].end = CGPoint(x: min(p1.x, newP2.x), y: max(p1.y, newP2.y))
                                        self.measurements[mIdx].distanceMm = Double(h)
                                    }
                                }
                            }
                            
                            self.selectedMeasurement?.rectP1 = p1
                            self.selectedMeasurement?.rectP2 = newP2
                            if dimType == "width" {
                                self.selectedMeasurement?.start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                self.selectedMeasurement?.end = CGPoint(x: max(p1.x, newP2.x), y: min(p1.y, newP2.y))
                            } else if dimType == "height" {
                                self.selectedMeasurement?.start = CGPoint(x: min(p1.x, newP2.x), y: min(p1.y, newP2.y))
                                self.selectedMeasurement?.end = CGPoint(x: min(p1.x, newP2.x), y: max(p1.y, newP2.y))
                            }
                        }
                    }
                    self.selectedMeasurement?.distanceMm = newValue
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
    
    init() {
        let uuid = UUID().uuidString
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("pathstitch_\(uuid)")
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.sessionTempDirectory = dir
    }
    
    func logAction(_ action: String, details: String, layerAffected: String? = nil) {
        logEntries.append(LogEntry(action: action, details: details, layerAffected: layerAffected))
    }

    func checkUnsavedChangesBeforeProceeding() -> Bool {
        guard hasUnsavedChanges else { return true }
        
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to your project?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")        // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")      // .alertSecondButtonReturn
        alert.addButton(withTitle: "Discard")     // .alertThirdButtonReturn

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Save → reuse existing path, otherwise prompt. Cancelling the save
            // panel cancels the whole action (returns false → nothing happens).
            if let current = currentProjectPath {
                saveProject(to: current)
                return !hasUnsavedChanges
            } else {
                let savePanel = NSSavePanel()
                savePanel.title = "Save Project"
                savePanel.nameFieldStringValue = "project.stch"
                savePanel.allowedContentTypes = [UTType(filenameExtension: "stch")].compactMap { $0 }
                if savePanel.runModal() == .OK, let url = savePanel.url {
                    saveProject(to: url)
                    return !hasUnsavedChanges
                }
                return false
            }
        } else if response == .alertThirdButtonReturn {
            // Discard → proceed, abandoning changes.
            return true
        } else {
            // Cancel → as if nothing happened.
            return false
        }
    }

    func resetToNewProject() {
        errorMessage = nil
        currentFilePath = nil
        currentStepFilePath = nil
        currentProjectPath = nil
        svgContent = nil
        entities = []
        previewEntities = []
        layers = []
        selectedHandles.removeAll()
        selectedFaces3D.removeAll()
        bodies3D = []
        batchItems = []
        activeEditingBatchItem = nil
        measurements.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        pendingDeletedHandles.removeAll()
        reconcileTask?.cancel()
        hasUnsavedChanges = false
        activeMode = .twoD
    }

    func traceRasterImage(url: URL) {
        if !checkUnsavedChangesBeforeProceeding() { return }
        errorMessage = nil
        selectedHandles.removeAll()
        selectedFaces3D.removeAll()
        
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let tempImgURL = tempDir.appendingPathComponent("temp_raster_\(UUID().uuidString).\(url.pathExtension)")
        try? FileManager.default.removeItem(at: tempImgURL)
        
        do {
            try FileManager.default.copyItem(at: url, to: tempImgURL)
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
            
            let targetURL = tempDir.appendingPathComponent("active.dxf")
            isProcessing = true
            
            Task {
                do {
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "trace_raster",
                        args: [
                            "input": tempImgURL.path,
                            "output": targetURL.path,
                            "threshold": 127,
                            "turdsize": 2
                        ]
                    )
                    await MainActor.run {
                        self.currentFilePath = targetURL
                        self.activeMode = .twoD
                        self.selectedHandles.removeAll()
                        self.reloadDXF()
                        self.hasUnsavedChanges = true
                        self.isProcessing = false
                        self.logAction("Trace Raster Image", details: "Traced raster image: \(url.lastPathComponent)")
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = "Failed to vectorize image: \(error.localizedDescription)"
                        self.isProcessing = false
                        self.logAction("Trace Raster Error", details: "Failed to vectorize: \(error.localizedDescription)")
                    }
                }
                try? FileManager.default.removeItem(at: tempImgURL)
            }
        } catch {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
            errorMessage = "Failed to copy input image: \(error.localizedDescription)"
            logAction("Trace Raster Error", details: "Failed to copy image: \(error.localizedDescription)")
        }
    }

    func loadFile(url: URL) {
        // Route project & PDF files to their dedicated handlers so callers can
        // pass any supported type here without hitting "unsupported" (MAS-12).
        let routedExt = url.pathExtension.lowercased()
        if routedExt == "stch" { loadProject(from: url); return }
        if routedExt == "pdf"  { importPDF(from: url);  return }

        if !checkUnsavedChangesBeforeProceeding() { return }
        errorMessage = nil
        selectedHandles.removeAll()
        selectedFaces3D.removeAll()
        currentProjectPath = nil
        
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let ext = url.pathExtension.lowercased()
        let imageExtensions = ["png", "jpg", "jpeg", "bmp", "tiff", "gif"]
        
        if ext == "dxf" {
            let targetURL = tempDir.appendingPathComponent("active.dxf")
            try? FileManager.default.removeItem(at: targetURL)
            do {
                try FileManager.default.copyItem(at: url, to: targetURL)
                currentFilePath = targetURL
                activeMode = .twoD
                
                isProcessing = true
                Task {
                    do {
                        _ = try await PythonBridge.shared.run(
                            module: "dxf_ops",
                            op: "normalize_dxf",
                            args: ["input": targetURL.path, "output": targetURL.path]
                        )
                        await MainActor.run {
                            self.reloadDXF()
                            self.hasUnsavedChanges = false
                            self.isProcessing = false
                            self.logAction("Load File", details: "Successfully loaded and normalized \(url.lastPathComponent)")
                        }
                    } catch {
                        await MainActor.run {
                            self.errorMessage = "Failed to normalize DXF: \(error.localizedDescription)"
                            self.isProcessing = false
                            self.logAction("Load File Error", details: "Failed to normalize \(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                errorMessage = "Failed to copy input DXF file: \(error.localizedDescription)"
                logAction("Load File Error", details: "Failed to copy input DXF file: \(error.localizedDescription)")
            }
        } else if ext == "step" || ext == "stp" {
            let targetURL = tempDir.appendingPathComponent("active.step")
            try? FileManager.default.removeItem(at: targetURL)
            do {
                try FileManager.default.copyItem(at: url, to: targetURL)
                currentStepFilePath = targetURL
                activeMode = .threeD
                reloadSTEP()
                hasUnsavedChanges = false
                logAction("Load STEP", details: "Loaded STEP file: \(url.lastPathComponent)")
            } catch {
                errorMessage = "Failed to copy input STEP file: \(error.localizedDescription)"
                logAction("Load STEP Error", details: "Failed to copy: \(error.localizedDescription)")
            }
        } else if ext == "svg" {
            let tempSVGURL = tempDir.appendingPathComponent("temp_import.svg")
            try? FileManager.default.removeItem(at: tempSVGURL)
            do {
                try FileManager.default.copyItem(at: url, to: tempSVGURL)
                let targetURL = tempDir.appendingPathComponent("active.dxf")
                isProcessing = true
                Task {
                    do {
                        _ = try await PythonBridge.shared.run(
                            module: "dxf_ops",
                            op: "import_svg",
                            args: [
                                "input": tempSVGURL.path,
                                "output": targetURL.path,
                                "consolidate": consolidateSvgStrokes
                            ]
                        )
                        await MainActor.run {
                            self.currentFilePath = targetURL
                            self.activeMode = .twoD
                            self.selectedHandles.removeAll()
                            self.reloadDXF()
                            self.hasUnsavedChanges = true
                            self.isProcessing = false
                            self.logAction("Import SVG", details: "Imported SVG: \(url.lastPathComponent)")
                        }
                    } catch {
                        await MainActor.run {
                            self.errorMessage = "Failed to convert SVG to DXF: \(error.localizedDescription)"
                            self.isProcessing = false
                            self.logAction("Import SVG Error", details: "Failed to convert: \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                errorMessage = "Failed to copy input SVG file: \(error.localizedDescription)"
                logAction("Import SVG Error", details: "Failed to copy input SVG: \(error.localizedDescription)")
            }
        } else if imageExtensions.contains(ext) {
            // Decouple from standard flow to trace raster image via Potrace
            traceRasterImage(url: url)
        } else {
            errorMessage = "Unsupported file extension: .\(url.pathExtension)"
            logAction("Load File Error", details: "Unsupported extension: .\(ext)")
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if activeMode == .batch {
            importFilesToBatch(urls)
            return
        }

        // Projects (.stch) and 3D models (.step/.stp) are their own workspace —
        // a window = a workspace — so they open in a NEW window rather than being
        // merged into the current 2D drawing (MAS-13/MAS-24).
        let newWindowExts: Set<String> = ["stch", "step", "stp"]
        let openInNewWindow = urls.filter { newWindowExts.contains($0.pathExtension.lowercased()) }
        let toMerge = urls.filter { !newWindowExts.contains($0.pathExtension.lowercased()) }

        for fileURL in openInNewWindow {
            WindowManager.shared.openAnyFile(url: fileURL)
        }

        guard !toMerge.isEmpty else { return }

        // MAS-13 — the number of importable files dropped decides the workflow:
        //   • 5 or more   → route them all into Batch mode (one card per file).
        //   • fewer than 5 → auto-distribute them side by side on the canvas so
        //     they never overlap. (The old merge ran every file through the
        //     positive-quadrant normaliser, stacking them all at the same origin,
        //     which looked like only one file had imported.)
        errorMessage = nil
        if toMerge.count >= 5 {
            activeMode = .batch
            importFilesToBatch(toMerge)
        } else {
            distributeImportFiles(toMerge)
        }
    }

    /// Imports 1–4 files and lays them out side by side on the current canvas
    /// (MAS-13). Each file is converted to a standalone DXF, then a single
    /// `import_distribute` call merges them all with no overlap. Additive — it
    /// never prompts a save dialog and never errors on a supported format.
    private func distributeImportFiles(_ urls: [URL]) {
        let activeURL = ensureActiveDXFFileExists()
        isProcessing = true

        Task {
            do {
                // Flush optimistic edits so we distribute onto current geometry.
                await reconcileBufferIfNeeded()

                var tempPaths: [String] = []
                for url in urls {
                    if let temp = try await convertToTempDXF(url) {
                        tempPaths.append(temp.path)
                    }
                }

                guard !tempPaths.isEmpty else {
                    await MainActor.run {
                        self.isProcessing = false
                        self.errorMessage = "No importable geometry found in the dropped file(s)."
                    }
                    return
                }

                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "import_distribute",
                    args: [
                        "primary": activeURL.path,
                        "secondaries": tempPaths,
                        "output": activeURL.path
                        // No explicit "gap" → Python sizes it to the content.
                    ]
                )

                for p in tempPaths { try? FileManager.default.removeItem(at: URL(fileURLWithPath: p)) }

                await MainActor.run {
                    self.currentFilePath = activeURL
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    // Fit the view so every imported file is visible at once.
                    self.reloadDXF(fitToContentAfter: true)
                    self.hasUnsavedChanges = true
                    self.logAction("Import & Distribute", details: "Imported and distributed \(tempPaths.count) file(s) side by side.")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Import failed: \(error.localizedDescription)"
                    self.isProcessing = false
                    self.logAction("Import Files Error", details: error.localizedDescription)
                }
            }
        }
    }

    /// Converts any supported importable file (.dxf/.svg/.pdf/image) into a
    /// single standalone temporary DXF and returns its URL (nil if unsupported
    /// or empty). Heavy geometry conversion runs in Python; the caller owns the
    /// returned temp file. Shared by distribute-import and batch-import.
    private func convertToTempDXF(_ url: URL) async throws -> URL? {
        let ext = url.pathExtension.lowercased()
        let imageExtensions = ["png", "jpg", "jpeg", "bmp", "tiff", "gif"]
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let outURL = tempDir.appendingPathComponent("import_\(UUID().uuidString).dxf")

        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
        }

        if ext == "dxf" {
            try? FileManager.default.removeItem(at: outURL)
            try FileManager.default.copyItem(at: url, to: outURL)
            return outURL
        } else if ext == "svg" {
            let tmpSvg = tempDir.appendingPathComponent("src_\(UUID().uuidString).svg")
            try? FileManager.default.removeItem(at: tmpSvg)
            try FileManager.default.copyItem(at: url, to: tmpSvg)
            _ = try await PythonBridge.shared.run(
                module: "dxf_ops",
                op: "import_svg",
                args: ["input": tmpSvg.path, "output": outURL.path, "consolidate": consolidateSvgStrokes]
            )
            try? FileManager.default.removeItem(at: tmpSvg)
            return outURL
        } else if ext == "pdf" {
            _ = try await PythonBridge.shared.run(
                module: "dxf_ops",
                op: "import_pdf",
                args: ["input": url.path, "output": outURL.path]
            )
            return outURL
        } else if imageExtensions.contains(ext) {
            let tmpImg = tempDir.appendingPathComponent("src_\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: tmpImg)
            try FileManager.default.copyItem(at: url, to: tmpImg)
            _ = try await PythonBridge.shared.run(
                module: "dxf_ops",
                op: "trace_raster",
                args: ["input": tmpImg.path, "output": outURL.path, "threshold": 127, "turdsize": 2]
            )
            try? FileManager.default.removeItem(at: tmpImg)
            return outURL
        }
        return nil
    }
    
    func importFilesToBatch(_ urls: [URL]) {
        isProcessing = true
        Task {
            do {
                let tempDir = sessionTempDirectory.appendingPathComponent("batch")
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                var newItems: [BatchItem] = []
                for url in urls {
                    // Convert any supported type (.dxf/.svg/.pdf/image) to a DXF
                    // so Batch mode accepts every importable format (MAS-13).
                    guard let convertedURL = try await convertToTempDXF(url) else { continue }
                    let tempFileURL = tempDir.appendingPathComponent("\(UUID().uuidString).dxf")
                    try? FileManager.default.removeItem(at: tempFileURL)
                    try FileManager.default.moveItem(at: convertedURL, to: tempFileURL)

                    // Normalize the file
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "normalize_dxf",
                        args: ["input": tempFileURL.path, "output": tempFileURL.path]
                    )
                    
                    // Generate SVG preview
                    let svgURL = tempDir.appendingPathComponent("\(UUID().uuidString).svg")
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_svg",
                        args: ["input": tempFileURL.path, "output": svgURL.path]
                    )
                    let svgStr = (try? String(contentsOf: svgURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: svgURL)
                    
                    // List entities
                    let listResult = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "list_entities",
                        args: ["input": tempFileURL.path]
                    )
                    var itemsEnts: [DXFEntity] = []
                    if let data = listResult["data"] as? [String: Any],
                       let jsonEntities = data["entities"] as? [[String: Any]] {
                        let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                        itemsEnts = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                    }
                    
                    let item = BatchItem(
                        fileURL: tempFileURL,
                        originalName: url.deletingPathExtension().lastPathComponent,
                        isSelected: true,
                        entities: itemsEnts,
                        svgContent: svgStr
                    )
                    newItems.append(item)
                }
                
                await MainActor.run {
                    self.batchItems.append(contentsOf: newItems)
                    self.isProcessing = false
                    self.logAction("Batch Import", details: "Imported \(newItems.count) files to batch.")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Batch import failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    func massApplySewingHoles() {
        let selectedItems = batchItems.filter { $0.isSelected }
        guard !selectedItems.isEmpty else {
            errorMessage = "No files selected in the batch."
            return
        }
        isProcessing = true
        
        Task {
            do {
                let tempDir = sessionTempDirectory.appendingPathComponent("batch")
                var updatedItems = batchItems
                
                for i in 0..<updatedItems.count {
                    let item = updatedItems[i]
                    guard item.isSelected else { continue }
                    
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "add_holes",
                        args: [
                            "input": item.fileURL.path,
                            "output": item.fileURL.path,
                            "handles": [] as [String],
                            "offset_distance": holeOffsetDistance,
                            "hole_diameter": holeDiameter,
                            "hole_spacing": holeSpacing,
                            "pattern": holePattern,
                            "corner_behavior": holeCornerBehavior,
                            "side": holeSide,
                            "row_spacing": holeRowSpacing,
                            "enable_variable_spacing": holeEnableVariableSpacing,
                            "enable_proximity_filter": holeEnableProximityFilter,
                            "enable_corner_interpolation": holeEnableCornerInterpolation,
                            "enable_line_proximity_filter": holeEnableLineProximityFilter,
                            "line_proximity_threshold": holeLineProximityThreshold,
                            "proximity_filter_distance": holeProximityDistance,
                            "variable_spacing_min": holeVariableSpacingMin,
                            "variable_spacing_max": holeVariableSpacingMax
                        ]
                    )
                    
                    let svgURL = tempDir.appendingPathComponent("\(UUID().uuidString).svg")
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_svg",
                        args: ["input": item.fileURL.path, "output": svgURL.path]
                    )
                    let svgStr = (try? String(contentsOf: svgURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: svgURL)
                    
                    let listResult = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "list_entities",
                        args: ["input": item.fileURL.path]
                    )
                    var itemsEnts: [DXFEntity] = []
                    if let data = listResult["data"] as? [String: Any],
                       let jsonEntities = data["entities"] as? [[String: Any]] {
                        let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                        itemsEnts = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                    }
                    
                    updatedItems[i].svgContent = svgStr
                    updatedItems[i].entities = itemsEnts
                }
                
                await MainActor.run {
                    self.batchItems = updatedItems
                    self.isProcessing = false
                    self.logAction("Batch Apply Holes", details: "Mass-applied sewing holes to \(selectedItems.count) files.")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Mass apply holes failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    func massApplyOffset() {
        let selectedItems = batchItems.filter { $0.isSelected }
        guard !selectedItems.isEmpty else {
            errorMessage = "No files selected in the batch."
            return
        }
        isProcessing = true
        
        Task {
            do {
                let tempDir = sessionTempDirectory.appendingPathComponent("batch")
                var updatedItems = batchItems
                
                for i in 0..<updatedItems.count {
                    let item = updatedItems[i]
                    guard item.isSelected else { continue }
                    
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "offset_lines",
                        args: [
                            "input": item.fileURL.path,
                            "output": item.fileURL.path,
                            "handles": [] as [String],
                            "distance": offsetDistance,
                            "side": offsetSide,
                            "layer": "OFFSET"
                        ]
                    )
                    
                    let svgURL = tempDir.appendingPathComponent("\(UUID().uuidString).svg")
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_svg",
                        args: ["input": item.fileURL.path, "output": svgURL.path]
                    )
                    let svgStr = (try? String(contentsOf: svgURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: svgURL)
                    
                    let listResult = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "list_entities",
                        args: ["input": item.fileURL.path]
                    )
                    var itemsEnts: [DXFEntity] = []
                    if let data = listResult["data"] as? [String: Any],
                       let jsonEntities = data["entities"] as? [[String: Any]] {
                        let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                        itemsEnts = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                    }
                    
                    updatedItems[i].svgContent = svgStr
                    updatedItems[i].entities = itemsEnts
                }
                
                await MainActor.run {
                    self.batchItems = updatedItems
                    self.isProcessing = false
                    self.logAction("Batch Apply Offset", details: "Mass-applied offset lines to \(selectedItems.count) files.")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Mass apply offset failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    func exportBatch(
        toFolder folderURL: URL,
        namingOption: NamingOption,
        customName: String,
        exportSelectedOnly: Bool,
        format: String
    ) {
        let itemsToExport = batchItems.filter { !exportSelectedOnly || $0.isSelected }
        guard !itemsToExport.isEmpty else {
            errorMessage = "No files to export."
            return
        }
        
        isProcessing = true
        
        Task {
            do {
                let accessing = folderURL.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        folderURL.stopAccessingSecurityScopedResource()
                    }
                }
                
                let folderName = customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Pathstitch_Batch_Export" : customName
                let exportSubfolderURL = folderURL.appendingPathComponent(folderName, isDirectory: true)
                try FileManager.default.createDirectory(at: exportSubfolderURL, withIntermediateDirectories: true)
                
                for (index, item) in itemsToExport.enumerated() {
                    let filename: String
                    if namingOption == .original {
                        filename = "\(item.originalName).\(format)"
                    } else {
                        let baseName = customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Export" : customName
                        filename = "\(baseName)_\(index + 1).\(format)"
                    }
                    
                    let destURL = exportSubfolderURL.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: destURL)
                    
                    if format == "dxf" {
                        try FileManager.default.copyItem(at: item.fileURL, to: destURL)
                    } else {
                        let tempDir = sessionTempDirectory
                        let tempExportURL = tempDir.appendingPathComponent("temp_batch_exp_\(UUID().uuidString).\(format)")
                        try? FileManager.default.removeItem(at: tempExportURL)
                        
                        if format == "svg" {
                            _ = try await PythonBridge.shared.run(
                                module: "dxf_ops",
                                op: "export_svg",
                                args: ["input": item.fileURL.path, "output": tempExportURL.path]
                            )
                        } else if format == "pdf" {
                            _ = try await PythonBridge.shared.run(
                                module: "dxf_ops",
                                op: "export_pdf",
                                args: ["input": item.fileURL.path, "output": tempExportURL.path]
                            )
                        } else if format == "png" {
                            let tempSVG = tempDir.appendingPathComponent("temp_batch_png_\(UUID().uuidString).svg")
                            try? FileManager.default.removeItem(at: tempSVG)
                            _ = try await PythonBridge.shared.run(
                                module: "dxf_ops",
                                op: "export_svg",
                                args: ["input": item.fileURL.path, "output": tempSVG.path]
                            )
                            if let image = NSImage(contentsOf: tempSVG) {
                                guard let tiffData = image.tiffRepresentation,
                                      let bitmapRep = NSBitmapImageRep(data: tiffData),
                                      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                                    throw NSError(domain: "Pathstitch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate PNG bytes"])
                                }
                                try pngData.write(to: tempExportURL)
                            } else {
                                throw NSError(domain: "Pathstitch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load SVG"])
                            }
                            try? FileManager.default.removeItem(at: tempSVG)
                        }
                        
                        try FileManager.default.copyItem(at: tempExportURL, to: destURL)
                        try? FileManager.default.removeItem(at: tempExportURL)
                    }
                }
                
                await MainActor.run {
                    self.isProcessing = false
                    self.logAction("Batch Export", details: "Exported \(itemsToExport.count) files to folder: \(folderName)")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Batch export failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    func reloadSTEP() {
        guard let url = currentStepFilePath else { return }
        
        isProcessing = true
        progress = 0.0
        selectedFaces3D.removeAll()
        
        Task {
            do {
                let listResult = try await PythonBridge.shared.run(
                    module: "step_ops",
                    op: "list_bodies",
                    args: ["input": url.path]
                )
                
                guard let data = listResult["data"] as? [String: Any],
                      let jsonBodies = data["bodies"] as? [[String: Any]] else {
                    throw PythonBridgeError.invalidResponse("Missing bodies array in output data.")
                }
                
                // Serialize the data portion to JSON string for Three.js
                let modelData = try JSONSerialization.data(withJSONObject: data)
                let modelJsonStr = String(data: modelData, encoding: .utf8) ?? ""
                
                // Decode the bodies for the SwiftUI Solid Bodies list sidebar
                let jsonData = try JSONSerialization.data(withJSONObject: jsonBodies)
                let decodedBodies = try JSONDecoder().decode([Body3D].self, from: jsonData)
                
                await MainActor.run {
                    self.stepJsonContent = modelJsonStr
                    self.bodies3D = decodedBodies
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
    
    func unfoldFace(bodyIndex: Int, faceIndex: Int) {
        saveToHistory()
        guard let stepUrl = currentStepFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let uuidStr = UUID().uuidString
                let outputDxf = tempDir.appendingPathComponent("unfolded_\(uuidStr).dxf")
                
                var args: [String: Any] = [
                    "input": stepUrl.path,
                    "output": outputDxf.path,
                    "body_index": bodyIndex,
                    "face_index": faceIndex
                ]
                if let existing = currentFilePath {
                    args["existing_dxf"] = existing.path
                }
                
                _ = try await PythonBridge.shared.run(
                    module: "step_ops",
                    op: "unfold_face",
                    args: args
                )
                
                await MainActor.run {
                    self.currentFilePath = outputDxf
                    self.activeMode = .twoD
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
    
    func unfoldAllSelected() {
        saveToHistory()
        guard let stepUrl = currentStepFilePath else { return }
        if selectedFaces3D.isEmpty { return }
        isProcessing = true
        
        Task {
            do {
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let uuidStr = UUID().uuidString
                let outputDxf = tempDir.appendingPathComponent("unfolded_\(uuidStr).dxf")
                
                let facesArray = Array(selectedFaces3D).map { [
                    "body_index": $0.bodyIndex,
                    "face_index": $0.faceIndex
                ] }
                
                var args: [String: Any] = [
                    "input": stepUrl.path,
                    "output": outputDxf.path,
                    "faces": facesArray
                ]
                if let existing = currentFilePath {
                    args["existing_dxf"] = existing.path
                }
                
                _ = try await PythonBridge.shared.run(
                    module: "step_ops",
                    op: "unfold_faces",
                    args: args
                )
                
                await MainActor.run {
                    self.currentFilePath = outputDxf
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    self.selectedFaces3D.removeAll()
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
    
    func reloadDXF(fitToContentAfter: Bool = false) {
        guard let url = currentFilePath, FileManager.default.fileExists(atPath: url.path) else {
            // No working buffer yet → present an empty canvas, never an error.
            self.svgContent = nil
            self.entities = []
            self.previewEntities = []
            self.layers = []
            self.isProcessing = false
            return
        }

        isProcessing = true
        progress = 0.0
        
        Task {
            do {
                // Ensure temporary output directory exists
                let tempDir = sessionTempDirectory
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
                    if fitToContentAfter { self.fitRequestToken += 1 }
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
                    if NSEvent.modifierFlags.contains(.shift) {
                        self.selectedHandles.formUnion(handlesList)
                    } else {
                        self.selectedHandles = Set(handlesList)
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
    
    func updateSelectedRectangleFillet(newFillet: Double) {
        guard let selected = selectedMeasurement,
              let handle = selected.entityHandle,
              (selected.dimensionType == "width" || selected.dimensionType == "height"),
              let url = currentFilePath else { return }
        
        saveToHistory()
        sketchFilletRadius = max(0.0, newFillet)
        
        for idx in 0..<measurements.count {
            if measurements[idx].entityHandle == handle {
                measurements[idx].filletRadius = sketchFilletRadius
            }
        }
        if selectedMeasurement?.entityHandle == handle {
            selectedMeasurement?.filletRadius = sketchFilletRadius
        }
        
        updateSelectedDimensionValue(newValue: selected.distanceMm)
    }
    
    func applyOffset() {
        saveToHistory()
        guard let url = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                await reconcileBufferIfNeeded()
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                let inputPath = url.path

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
        saveToHistory()
        guard let url = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                await reconcileBufferIfNeeded()
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")

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
                        "row_spacing": holeRowSpacing,
                        "enable_variable_spacing": holeEnableVariableSpacing,
                        "enable_proximity_filter": holeEnableProximityFilter,
                        "enable_corner_interpolation": holeEnableCornerInterpolation,
                        "enable_line_proximity_filter": holeEnableLineProximityFilter,
                        "line_proximity_threshold": holeLineProximityThreshold,
                        "proximity_filter_distance": holeProximityDistance,
                        "variable_spacing_min": holeVariableSpacingMin,
                        "variable_spacing_max": holeVariableSpacingMax
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
        saveToHistory()
        guard let url = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                await reconcileBufferIfNeeded()
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")

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
    
    func assignSelectedToLayer(_ layerName: String) {
        saveToHistory()
        guard let url = currentFilePath else { return }
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "set_layer",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "layer": layerName
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
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
    
    func exportFile(to url: URL, format: String, selectedOnly: Bool = false) {
        guard let currentUrl = currentFilePath else { return }
        isProcessing = true

        Task {
            do {
                // Flush any optimistic in-memory edits so the export reflects
                // the current model, not a stale buffer (MAS-21).
                await reconcileBufferIfNeeded()
                let tempDir = sessionTempDirectory
                let tempExportURL = tempDir.appendingPathComponent("temp_export_\(UUID().uuidString).\(format)")
                try? FileManager.default.removeItem(at: tempExportURL)
                
                let handlesArg: [String]? = selectedOnly ? Array(selectedHandles) : nil
                
                if format == "dxf" {
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_dxf",
                        args: [
                            "input": currentUrl.path,
                            "output": tempExportURL.path,
                            "handles": handlesArg as Any
                        ]
                    )
                } else if format == "svg" {
                    var args: [String: Any] = ["input": currentUrl.path, "output": tempExportURL.path]
                    if let handles = handlesArg {
                        args["handles"] = handles
                    }
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_svg",
                        args: args
                    )
                } else if format == "pdf" {
                    var args: [String: Any] = ["input": currentUrl.path, "output": tempExportURL.path]
                    if let handles = handlesArg {
                        args["handles"] = handles
                    }
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_pdf",
                        args: args
                    )
                } else if format == "png" {
                    let tempSVG = tempDir.appendingPathComponent("temp_export_png_\(UUID().uuidString).svg")
                    try? FileManager.default.removeItem(at: tempSVG)
                    
                    var args: [String: Any] = ["input": currentUrl.path, "output": tempSVG.path]
                    if let handles = handlesArg {
                        args["handles"] = handles
                    }
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "export_svg",
                        args: args
                    )
                    
                    if let image = NSImage(contentsOf: tempSVG) {
                        guard let tiffData = image.tiffRepresentation,
                              let bitmapRep = NSBitmapImageRep(data: tiffData),
                              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                            throw NSError(domain: "Pathstitch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate PNG bytes"])
                        }
                        try pngData.write(to: tempExportURL)
                    } else {
                        throw NSError(domain: "Pathstitch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load SVG into NSImage"])
                    }
                    try? FileManager.default.removeItem(at: tempSVG)
                }
                
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: tempExportURL, to: url)
                try? FileManager.default.removeItem(at: tempExportURL)
                
                await MainActor.run {
                    self.isProcessing = false
                    self.logAction("Export File", details: "Exported successfully to \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                    self.isProcessing = false
                    self.logAction("Export File Error", details: "Failed to export: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// A minimal, valid R2010 DXF that `ezdxf` reads and can append entities to.
    /// Lets us materialise an empty working buffer instantly, with zero Python
    /// round-trips, so a new or cleared canvas never shows a loading screen.
    static let emptyDXFTemplate = """
    0
    SECTION
    2
    HEADER
    9
    $ACADVER
    1
    AC1024
    0
    ENDSEC
    0
    SECTION
    2
    ENTITIES
    0
    ENDSEC
    0
    EOF

    """

    /// Writes a fresh, empty DXF to the session working buffer and returns it.
    /// Synchronous and instant — the canonical way to get a blank document.
    @discardableResult
    func writeEmptyActiveDXF() -> URL {
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("active.dxf")
        do {
            try AppState.emptyDXFTemplate.data(using: .utf8)?.write(to: url)
        } catch {
            // Even if the write somehow fails, downstream edit ops (op_add_entity)
            // recreate a blank doc when the input is missing, so this is non-fatal.
        }
        return url
    }

    /// Resets to a clean, blank workspace backed by a valid empty buffer.
    /// Used for new windows, "New Project", and "Clear Canvas". A blank canvas
    /// is a fully valid first-class state — every tool works on it.
    func startBlankDocument() {
        resetToNewProject()
        let url = writeEmptyActiveDXF()
        currentFilePath = url
        entities = []
        previewEntities = []
        svgContent = nil
        layers = []
        selectedHandles.removeAll()
        isProcessing = false
        hasUnsavedChanges = false
    }

    /// Returns the working-buffer URL, guaranteeing a valid empty DXF exists on
    /// disk. Never returns a path to a missing file.
    func ensureActiveDXFFileExists() -> URL {
        if let path = currentFilePath, FileManager.default.fileExists(atPath: path.path) {
            return path
        }
        let url = writeEmptyActiveDXF()
        currentFilePath = url
        return url
    }
    
    func addSketchedEntity(type: String, params: [String: Any]) async -> String? {
        saveToHistory()
        let activeDxfURL = ensureActiveDXFFileExists()
        await MainActor.run {
            self.isProcessing = true
        }

        do {
            // Flush deferred deletes so the new entity appends to current
            // geometry, never resurrecting a just-deleted entity (MAS-21).
            await reconcileBufferIfNeeded()
            let res = try await PythonBridge.shared.run(
                module: "dxf_ops",
                op: "add_entity",
                args: [
                    "input": activeDxfURL.path,
                    "output": activeDxfURL.path,
                    "type": type,
                    "params": params,
                    "layer": "DRAWN_SHAPES"
                ]
            )
            
            let handle = (res["data"] as? [String: Any])?["handle"] as? String
            
            await MainActor.run {
                self.reloadDXF()
            }
            return handle
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isProcessing = false
            }
            return nil
        }
    }
    
    func applyBBoxOffset() {
        saveToHistory()
        let activeDxfURL = ensureActiveDXFFileExists()
        isProcessing = true
        
        Task {
            do {
                let tempDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "offset_bbox",
                    args: [
                        "input": activeDxfURL.path,
                        "output": tempDxfURL.path,
                        "handles": Array(selectedHandles),
                        "distance": bboxOffsetDistance,
                        "fillet_radius": bboxOffsetFillet,
                        "layer": "OFFSET"
                    ]
                )
                
                await MainActor.run {
                    self.currentFilePath = tempDxfURL
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
    
    @ObservationIgnored
    private var previewTask: Task<Void, Never>? = nil

    func updateLivePreview() {
        previewTask?.cancel()
        
        guard let url = currentFilePath, !selectedHandles.isEmpty else {
            self.previewEntities = []
            return
        }
        
        if currentTool != .offset && currentTool != .addHoles {
            self.previewEntities = []
            return
        }
        
        previewTask = Task {
            do {
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let previewDxf = tempDir.appendingPathComponent("preview_temp.dxf")
                
                let res: [String: Any]
                if currentTool == .offset {
                    res = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "offset_lines",
                        args: [
                            "input": url.path,
                            "output": previewDxf.path,
                            "handles": Array(selectedHandles),
                            "distance": offsetDistance,
                            "side": offsetSide,
                            "layer": "PREVIEW"
                        ]
                    )
                } else {
                    res = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "add_holes",
                        args: [
                            "input": url.path,
                            "output": previewDxf.path,
                            "handles": Array(selectedHandles),
                            "offset_distance": holeOffsetDistance,
                            "hole_diameter": holeDiameter,
                            "hole_spacing": holeSpacing,
                            "pattern": holePattern,
                            "corner_behavior": holeCornerBehavior,
                            "side": holeSide,
                            "row_spacing": holeRowSpacing,
                            "enable_variable_spacing": holeEnableVariableSpacing,
                            "enable_proximity_filter": holeEnableProximityFilter,
                            "enable_corner_interpolation": holeEnableCornerInterpolation,
                            "enable_line_proximity_filter": holeEnableLineProximityFilter,
                            "line_proximity_threshold": holeLineProximityThreshold,
                            "proximity_filter_distance": holeProximityDistance,
                            "variable_spacing_min": holeVariableSpacingMin,
                            "variable_spacing_max": holeVariableSpacingMax
                        ]
                    )
                }
                
                try Task.checkCancellation()
                
                let listResult = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "list_entities",
                    args: ["input": previewDxf.path]
                )
                
                try Task.checkCancellation()
                
                guard let data = listResult["data"] as? [String: Any],
                      let jsonEntities = data["entities"] as? [[String: Any]] else {
                    return
                }
                
                let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                let decodedEntities = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                let previewOnly = decodedEntities.filter { $0.layer == "PREVIEW" || $0.layer == "SEWING_HOLES" }
                
                await MainActor.run {
                    self.previewEntities = previewOnly
                }
            } catch {
                // Cancelled
            }
        }
    }
    
    func projectToSketch(planeType: String) {
        saveToHistory()
        guard let stepUrl = currentStepFilePath else { return }
        isProcessing = true
        
        let singleFace = selectedFaces3D.first
        let bodyIdx = singleFace?.bodyIndex ?? 0
        let faceIdx = singleFace?.faceIndex
        
        Task {
            do {
                let tempDir = sessionTempDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let uuidStr = UUID().uuidString
                let outputDxf = tempDir.appendingPathComponent("projected_\(uuidStr).dxf")
                
                var args: [String: Any] = [
                    "input": stepUrl.path,
                    "output": outputDxf.path,
                    "body_index": bodyIdx,
                    "plane_type": planeType
                ]
                if planeType == "face", let faceIdx = faceIdx {
                    args["face_index"] = faceIdx
                }
                if let existing = currentFilePath {
                    args["existing_dxf"] = existing.path
                }
                
                _ = try await PythonBridge.shared.run(
                    module: "step_ops",
                    op: "project_edges",
                    args: args
                )
                
                await MainActor.run {
                    self.currentFilePath = outputDxf
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    self.selectedFaces3D.removeAll()
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

    func loadReferenceImage(from url: URL) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if let image = NSImage(contentsOf: url) {
            self.refImage = image
            if let data = try? Data(contentsOf: url) {
                self.refImageBase64 = data.base64EncodedString()
            }
            logEntries.append(LogEntry(action: "Load Reference Image", details: "Loaded reference image: \(url.lastPathComponent)"))
        } else {
            errorMessage = "Failed to load reference image."
        }
    }
    
    func calibrateReferenceImage() {
        guard calibrationPoints.count == 2, calibrationDistance > 0 else { return }
        let p1 = calibrationPoints[0]
        let p2 = calibrationPoints[1]
        let modelDistance = Double(hypot(p2.x - p1.x, p2.y - p1.y))
        if modelDistance > 1e-5 {
            refImageScale = refImageScale * CGFloat(calibrationDistance / modelDistance)
            logEntries.append(LogEntry(action: "Calibrate Reference Image", details: "Calibrated 2 points. Target: \(calibrationDistance)mm, Measured: \(modelDistance)mm, scale factor: \(calibrationDistance / modelDistance), new scale: \(refImageScale)"))
        }
        calibrationPoints.removeAll()
        isCalibrationActive = false
        hasUnsavedChanges = true
    }
    
    func generatePreviewPNG(size: CGSize = CGSize(width: 480, height: 320)) -> Data? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        
        // Fill background with #0d0d10
        context.setFillColor(CGColor(red: 13.0/255.0, green: 13.0/255.0, blue: 16.0/255.0, alpha: 1.0))
        context.fill(CGRect(origin: .zero, size: size))
        
        if entities.isEmpty {
            // Draw a generic placeholder wordmark centered
            let font = NSFont.systemFont(ofSize: 28, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(red: 0.89, green: 0.89, blue: 0.92, alpha: 1.0)
            ]
            let string = NSAttributedString(string: "Pathstitch", attributes: attrs)
            let sizeStr = string.size()
            let rect = CGRect(
                x: (size.width - sizeStr.width) / 2,
                y: (size.height - sizeStr.height) / 2,
                width: sizeStr.width,
                height: sizeStr.height
            )
            
            let nsGraphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsGraphicsContext
            string.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Compute bounds
            var minX = Double.infinity
            var maxX = -Double.infinity
            var minY = Double.infinity
            var maxY = -Double.infinity
            
            for ent in entities {
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
            
            let bounds: CGRect
            if minX == .infinity {
                bounds = CGRect(x: -50, y: -50, width: 100, height: 100)
            } else {
                bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            
            let centerX = bounds.midX
            let centerY = bounds.midY
            let usableW = size.width * 0.8
            let usableH = size.height * 0.8
            let scaleX = bounds.width > 0 ? (usableW / bounds.width) : 1.0
            let scaleY = bounds.height > 0 ? (usableH / bounds.height) : 1.0
            let scale = min(scaleX, scaleY)
            
            func toScreen(dx: Double, dy: Double) -> CGPoint {
                return CGPoint(
                    x: size.width / 2 + CGFloat(dx - centerX) * scale,
                    y: size.height / 2 - CGFloat(dy - centerY) * scale
                )
            }
            
            // Draw each visible entity
            for ent in entities {
                let layerVisible = layers.first(where: { $0.name == ent.layer })?.visible ?? true
                if !layerVisible { continue }
                
                let layerColor = layers.first(where: { $0.name == ent.layer })?.color ?? Color.white
                let cgColor = NSColor(layerColor).cgColor
                context.setStrokeColor(cgColor)
                context.setLineWidth(1.0)
                
                if ent.type == "LINE", let s = ent.start, let e = ent.end {
                    let p1 = toScreen(dx: s[0], dy: s[1])
                    let p2 = toScreen(dx: e[0], dy: e[1])
                    context.move(to: p1)
                    context.addLine(to: p2)
                    context.strokePath()
                } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
                    let sc = toScreen(dx: center[0], dy: center[1])
                    let r = CGFloat(radius) * scale
                    context.addEllipse(in: CGRect(x: sc.x - r, y: sc.y - r, width: r * 2, height: r * 2))
                    context.strokePath()
                } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius,
                          let sa = ent.start_angle, let ea = ent.end_angle {
                    let sc = toScreen(dx: center[0], dy: center[1])
                    let r = CGFloat(radius) * scale
                    let startRad = CGFloat(-sa * .pi / 180.0)
                    let endRad = CGFloat(-ea * .pi / 180.0)
                    context.addArc(center: sc, radius: r, startAngle: startRad, endAngle: endRad, clockwise: true)
                    context.strokePath()
                } else if let vertices = ent.vertices, vertices.count >= 2 {
                    let pStart = toScreen(dx: vertices[0][0], dy: vertices[0][1])
                    context.move(to: pStart)
                    for i in 1..<vertices.count {
                        let p = toScreen(dx: vertices[i][0], dy: vertices[i][1])
                        context.addLine(to: p)
                    }
                    if ent.closed == true {
                        context.closePath()
                    }
                    context.strokePath()
                }
            }
        }
        
        guard let cgImage = context.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: size)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
    }
    
    func saveProject(to url: URL) {
        // A blank project is valid and must be saveable — materialise an empty
        // working buffer if one doesn't exist yet rather than erroring out.
        let dxfURL: URL
        if let p = currentFilePath, FileManager.default.fileExists(atPath: p.path) {
            dxfURL = p
        } else {
            dxfURL = writeEmptyActiveDXF()
            currentFilePath = dxfURL
        }

        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            let dxfData = try Data(contentsOf: dxfURL)
            let base64Dxf = dxfData.base64EncodedString()

            // Snapshot any batch session so .stch round-trips it (MAS-24).
            let savedBatch: [BatchItemSave]? = batchItems.isEmpty ? nil : batchItems.compactMap { item in
                guard let data = try? Data(contentsOf: item.fileURL) else { return nil }
                return BatchItemSave(
                    originalName: item.originalName,
                    dxfDataBase64: data.base64EncodedString(),
                    isSelected: item.isSelected,
                    svgContent: item.svgContent,
                    entities: item.entities
                )
            }

            let container = ProjectSaveContainer(
                dxfDataBase64: base64Dxf,
                measurements: measurements,
                logEntries: logEntries,
                canvasScale: Double(canvasScale),
                canvasOffsetX: Double(canvasOffset.width),
                canvasOffsetY: Double(canvasOffset.height),
                refImageBase64: refImageBase64,
                refImageOffsetX: Double(refImageOffset.width),
                refImageOffsetY: Double(refImageOffset.height),
                refImageScale: Double(refImageScale),
                refImageOpacity: refImageOpacity,
                refImageCalibrationDistance: calibrationDistance,
                refImageCalibrationStartX: calibrationPoints.first.map { Double($0.x) },
                refImageCalibrationStartY: calibrationPoints.first.map { Double($0.y) },
                refImageCalibrationEndX: calibrationPoints.count > 1 ? Double(calibrationPoints[1].x) : nil,
                refImageCalibrationEndY: calibrationPoints.count > 1 ? Double(calibrationPoints[1].y) : nil,
                isLearnModeEnabled: isLearnModeEnabled,
                offsetDistance: offsetDistance,
                offsetSide: offsetSide,
                holeOffsetDistance: holeOffsetDistance,
                holeDiameter: holeDiameter,
                holeSpacing: holeSpacing,
                holePattern: holePattern,
                holeCornerBehavior: holeCornerBehavior,
                holeSide: holeSide,
                holeRowSpacing: holeRowSpacing,
                batchItems: savedBatch
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let jsonData = try encoder.encode(container)
            
            // Delete old file if it exists to overwrite completely
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            
            let archive = try Archive(url: url, accessMode: .create)
            
            // Add project.json
            try archive.addEntry(with: "project.json", type: .file, uncompressedSize: UInt32(jsonData.count), provider: { (position, size) -> Data in
                return jsonData.subdata(in: position..<position+size)
            })
            
            // Generate and add preview.png
            if let previewData = generatePreviewPNG() {
                try archive.addEntry(with: "preview.png", type: .file, uncompressedSize: UInt32(previewData.count), provider: { (position, size) -> Data in
                    return previewData.subdata(in: position..<position+size)
                })
            }
            
            self.currentProjectPath = url
            self.hasUnsavedChanges = false
            logEntries.append(LogEntry(action: "Save Project", details: "Saved project successfully to \(url.lastPathComponent)"))
        } catch {
            errorMessage = "Failed to save project: \(error.localizedDescription)"
        }
    }
    
    func loadProject(from url: URL) {
        if !checkUnsavedChangesBeforeProceeding() { return }
        errorMessage = nil
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            var container: ProjectSaveContainer? = nil
            
            // Try loading as ZIP archive first
            if let archive = try? Archive(url: url, accessMode: .read) {
                if let entry = archive["project.json"] {
                    var projectData = Data()
                    _ = try archive.extract(entry, consumer: { chunk in
                        projectData.append(chunk)
                    })
                    container = try? JSONDecoder().decode(ProjectSaveContainer.self, from: projectData)
                }
            }
            
            // Fallback to plain JSON for older project files
            if container == nil {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                container = try decoder.decode(ProjectSaveContainer.self, from: data)
            }
            
            guard let validContainer = container else {
                errorMessage = "Failed to decode project save container."
                return
            }
            
            let tempDir = sessionTempDirectory
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let targetURL = tempDir.appendingPathComponent("active.dxf")
            
            if let dxfBase64 = validContainer.dxfDataBase64, let dxfData = Data(base64Encoded: dxfBase64) {
                try dxfData.write(to: targetURL)
                self.currentFilePath = targetURL
            } else {
                // Project carried no geometry → open onto a valid blank buffer.
                self.currentFilePath = writeEmptyActiveDXF()
            }

            self.currentProjectPath = url
            self.measurements = validContainer.measurements
            self.logEntries = validContainer.logEntries
            self.canvasScale = CGFloat(validContainer.canvasScale)
            self.canvasOffset = CGSize(width: CGFloat(validContainer.canvasOffsetX), height: CGFloat(validContainer.canvasOffsetY))
            
            self.refImageBase64 = validContainer.refImageBase64
            if let base64 = validContainer.refImageBase64, let imgData = Data(base64Encoded: base64) {
                self.refImage = NSImage(data: imgData)
            } else {
                self.refImage = nil
            }
            
            self.refImageOffset = CGSize(width: CGFloat(validContainer.refImageOffsetX), height: CGFloat(validContainer.refImageOffsetY))
            self.refImageScale = CGFloat(validContainer.refImageScale)
            self.refImageOpacity = validContainer.refImageOpacity
            self.calibrationDistance = validContainer.refImageCalibrationDistance
            
            self.calibrationPoints.removeAll()
            if let sx = validContainer.refImageCalibrationStartX, let sy = validContainer.refImageCalibrationStartY {
                self.calibrationPoints.append(CGPoint(x: sx, y: sy))
            }
            if let ex = validContainer.refImageCalibrationEndX, let ey = validContainer.refImageCalibrationEndY {
                self.calibrationPoints.append(CGPoint(x: ex, y: ey))
            }
            
            if let learn = validContainer.isLearnModeEnabled { self.isLearnModeEnabled = learn }
            if let dist = validContainer.offsetDistance { self.offsetDistance = dist }
            if let side = validContainer.offsetSide { self.offsetSide = side }
            if let hDist = validContainer.holeOffsetDistance { self.holeOffsetDistance = hDist }
            if let hDiam = validContainer.holeDiameter { self.holeDiameter = hDiam }
            if let hSpac = validContainer.holeSpacing { self.holeSpacing = hSpac }
            if let hPat = validContainer.holePattern { self.holePattern = hPat }
            if let hCorn = validContainer.holeCornerBehavior { self.holeCornerBehavior = hCorn }
            if let hSide = validContainer.holeSide { self.holeSide = hSide }
            if let hRow = validContainer.holeRowSpacing { self.holeRowSpacing = hRow }

            // Restore a persisted batch session, if any (MAS-24). DXFs are
            // written back to the session batch dir; svg/entities come straight
            // from the snapshot so no Python work is needed on load.
            self.batchItems = []
            if let savedBatch = validContainer.batchItems, !savedBatch.isEmpty {
                let batchDir = sessionTempDirectory.appendingPathComponent("batch")
                try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
                for saved in savedBatch {
                    guard let data = Data(base64Encoded: saved.dxfDataBase64) else { continue }
                    let fileURL = batchDir.appendingPathComponent("\(UUID().uuidString).dxf")
                    do {
                        try data.write(to: fileURL)
                        self.batchItems.append(BatchItem(
                            fileURL: fileURL,
                            originalName: saved.originalName,
                            isSelected: saved.isSelected,
                            entities: saved.entities,
                            svgContent: saved.svgContent
                        ))
                    } catch { }
                }
            }

            self.activeMode = .twoD
            self.selectedHandles.removeAll()
            self.reloadDXF()
            self.hasUnsavedChanges = false
            
            logEntries.append(LogEntry(action: "Load Project", details: "Loaded project successfully from \(url.lastPathComponent)"))
        } catch {
            errorMessage = "Failed to load project: \(error.localizedDescription)"
        }
    }

    func saveProjectWithDialog() {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Project"
        savePanel.nameFieldStringValue = "project.stch"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "stch")].compactMap { $0 }
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            self.saveProject(to: url)
        }
    }
    
    func loadProjectWithDialog() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [UTType(filenameExtension: "stch")].compactMap { $0 }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            self.loadProject(from: url)
        }
    }


    func importPDF(from url: URL) {
        errorMessage = nil
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let targetURL = tempDir.appendingPathComponent("active.dxf")
        
        isProcessing = true
        Task {
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "import_pdf",
                    args: [
                        "input": url.path,
                        "output": targetURL.path
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = targetURL
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Import PDF", details: "Imported PDF vectors from \(url.lastPathComponent)"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to import PDF: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    func traceRaster(from url: URL, threshold: Int = 127, turdsize: Int = 2) {
        errorMessage = nil
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempDir = sessionTempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let targetURL = tempDir.appendingPathComponent("active.dxf")
        
        isProcessing = true
        Task {
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "trace_raster",
                    args: [
                        "input": url.path,
                        "output": targetURL.path,
                        "threshold": threshold,
                        "turdsize": turdsize
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = targetURL
                    self.activeMode = .twoD
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Trace Raster", details: "Traced raster image \(url.lastPathComponent) (threshold: \(threshold))"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to trace image: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }

    func translateSelected(dx: CGFloat, dy: CGFloat) {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        
        let dxDouble = Double(dx)
        let dyDouble = Double(dy)
        
        // 1. Optimistic in-memory update for entities
        self.entities = self.entities.map { entity in
            if self.selectedHandles.contains(entity.handle) {
                return entity.translated(dx: dxDouble, dy: dyDouble)
            } else {
                return entity
            }
        }
        
        // 2. Optimistic in-memory update for measurements
        for idx in 0..<self.measurements.count {
            if let handle = self.measurements[idx].entityHandle, self.selectedHandles.contains(handle) {
                var m = self.measurements[idx]
                m.start.x += dx
                m.start.y += dy
                m.end.x += dx
                m.end.y += dy
                if var p1 = m.rectP1 {
                    p1.x += dx
                    p1.y += dy
                    m.rectP1 = p1
                }
                if var p2 = m.rectP2 {
                    p2.x += dx
                    p2.y += dy
                    m.rectP2 = p2
                }
                self.measurements[idx] = m
            }
        }
        
        self.hasUnsavedChanges = true
        logEntries.append(LogEntry(action: "Translate Entities", details: "Translated selected entities by dx: \(dx), dy: \(dy)"))
        
        // 3. Asynchronous background reconciliation to disk
        let selectedHandlesSnapshot = self.selectedHandles
        let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        
        let task = Task<Void, Never> {
            // Wait for any running reconcileTask to finish first
            await reconcileBufferIfNeeded()
            
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "translate_entities",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandlesSnapshot),
                        "dx": dxDouble,
                        "dy": dyDouble
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                }
            } catch {
                // Background translation failed; the in-memory state is still correct.
                print("Background translation failed: \(error)")
            }
        }
        
        self.reconcileTask = task
    }

    func applyDashedCreases() {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "add_dashed_creases",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "layer": "CREASES"
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Add Creases", details: "Added paper folding crease pattern on selected lines"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applyGlueTabs(height: Double, type: String, side: String) {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "add_glue_tabs",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "height": height,
                        "type": type,
                        "side": side,
                        "layer": "GLUE_TABS"
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Add Glue Tabs", details: "Added \(type) glue tabs on \(side) side, height: \(height)mm"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applyPatternGrid(columns: Int, rows: Int, colSpacing: Double, rowSpacing: Double) {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "pattern_grid",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "columns": columns,
                        "rows": rows,
                        "col_spacing": colSpacing,
                        "row_spacing": rowSpacing,
                        "layer": "PATTERN"
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Grid Pattern", details: "Patterned grid of \(columns)x\(rows) with spacing X:\(colSpacing) Y:\(rowSpacing)"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applyPatternPath(pathHandle: String, spacing: Double) {
        guard let url = currentFilePath, !selectedHandles.isEmpty else { return }
        saveToHistory()
        isProcessing = true
        
        Task {
            do {
                let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "pattern_path",
                    args: [
                        "input": url.path,
                        "output": activeDxfURL.path,
                        "handles": Array(selectedHandles),
                        "path_handle": pathHandle,
                        "spacing": spacing,
                        "layer": "PATTERN"
                    ]
                )
                await MainActor.run {
                    self.currentFilePath = activeDxfURL
                    self.selectedHandles.removeAll()
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Path Pattern", details: "Patterned along path \(pathHandle) with spacing \(spacing)mm"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    func applyAddText(text: String, insert: CGPoint, height: Double) {
        saveToHistory()
        let activeDxfURL = ensureActiveDXFFileExists()
        isProcessing = true
        
        Task {
            do {
                // Flush deferred deletes so text appends to current geometry (MAS-21).
                await reconcileBufferIfNeeded()
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "add_text",
                    args: [
                        "input": activeDxfURL.path,
                        "output": activeDxfURL.path,
                        "text": text,
                        "insert": [Double(insert.x), Double(insert.y)],
                        "height": height,
                        "layer": "TEXT"
                    ]
                )
                await MainActor.run {
                    self.reloadDXF()
                    logEntries.append(LogEntry(action: "Add Text", details: "Placed text: \"\(text)\" at (\(Int(insert.x)), \(Int(insert.y)))"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }

    // MARK: - In-memory source of truth (MAS-21 / MAS-24)
    //
    // The authoritative working state is the in-memory model (`entities`,
    // `measurements`, `layers`), which `DxfCanvasView` renders directly. The
    // on-disk `active.dxf` is a *derived mirror* used only to hand heavy
    // geometry to the Python engine and to persist on Save/Export. Interactive
    // edits update the in-memory model optimistically — instantly, with no
    // Python round-trip and no loading screen — and queue a lightweight buffer
    // reconcile. Any code path that feeds the buffer to Python or serializes it
    // calls `await reconcileBufferIfNeeded()` first, so the mirror is current.

    /// Handles deleted in memory but not yet flushed to the working buffer.
    @ObservationIgnored private var pendingDeletedHandles: Set<String> = []
    /// The in-flight buffer reconcile, if any, so readers can coalesce/await it.
    @ObservationIgnored private var reconcileTask: Task<Void, Never>? = nil

    /// Rebuilds the layer list from the current in-memory entities, preserving
    /// existing color/visibility. Keeps the Layers panel correct after an
    /// optimistic in-memory edit without a Python round-trip.
    func recomputeLayersFromEntities() {
        let uniqueLayers = Array(Set(entities.map { $0.layer })).sorted()
        self.layers = uniqueLayers.map { layerName in
            let existing = self.layers.first(where: { $0.name == layerName })
            return DXFLayer(
                name: layerName,
                color: existing?.color ?? self.colorForLayerName(layerName),
                visible: existing?.visible ?? true
            )
        }
    }

    /// Flushes any deferred optimistic deletions into the on-disk working
    /// buffer so the Python engine and Save/Export operate on current geometry.
    /// Cheap no-op when nothing is pending; safe to call from any op that reads
    /// the buffer. `op_delete_entities` is idempotent, so an occasional
    /// double-flush is harmless.
    func reconcileBufferIfNeeded() async {
        if let running = await MainActor.run(body: { self.reconcileTask }) {
            await running.value
        }
        let snapshot: (handles: [String], input: URL)? = await MainActor.run {
            guard !self.pendingDeletedHandles.isEmpty,
                  let input = self.currentFilePath,
                  FileManager.default.fileExists(atPath: input.path) else {
                self.pendingDeletedHandles.removeAll()
                return nil
            }
            return (Array(self.pendingDeletedHandles), input)
        }
        guard let snap = snapshot else { return }
        let activeURL = sessionTempDirectory.appendingPathComponent("active.dxf")
        let task = Task<Void, Never> {
            do {
                _ = try await PythonBridge.shared.run(
                    module: "dxf_ops",
                    op: "delete_entities",
                    args: ["input": snap.input.path, "output": activeURL.path, "handles": snap.handles]
                )
                await MainActor.run {
                    self.currentFilePath = activeURL
                    self.pendingDeletedHandles.subtract(snap.handles)
                }
            } catch {
                // The in-memory truth already reflects the deletion; a later
                // reader retries. Don't surface an error for a background sync.
            }
        }
        await MainActor.run { self.reconcileTask = task }
        await task.value
        await MainActor.run { self.reconcileTask = nil }
    }

    /// Reconciles the working buffer, then saves the project. Use this from
    /// user-facing Save entry points so a just-performed optimistic edit (e.g.
    /// a delete) is reflected in the persisted `.stch` even in a fast sequence.
    func reconcileThenSave(to url: URL) {
        Task {
            await reconcileBufferIfNeeded()
            await MainActor.run { self.saveProject(to: url) }
        }
    }

    /// Deletes the selected entities. A delete that empties the canvas is a
    /// fully valid state — the in-memory model simply becomes empty and the
    /// canvas renders blank, never an error (MAS-8 / MAS-49). The update is
    /// optimistic (instant, zero Python round-trips, no loading screen); the
    /// working buffer is reconciled in the background for later heavy ops/Save.
    func deleteSelectedEntities() {
        guard !selectedHandles.isEmpty else { return }
        saveToHistory()
        let removed = selectedHandles

        entities.removeAll { removed.contains($0.handle) }
        previewEntities.removeAll { removed.contains($0.handle) }
        measurements.removeAll { m in
            if let h = m.entityHandle { return removed.contains(h) }
            return false
        }
        if let sel = selectedMeasurement, let h = sel.entityHandle, removed.contains(h) {
            selectedMeasurement = nil
        }
        selectedHandles.removeAll()
        recomputeLayersFromEntities()
        hasUnsavedChanges = true
        logAction("Delete Entities", details: "Deleted \(removed.count) selected entit\(removed.count == 1 ? "y" : "ies")")

        pendingDeletedHandles.formUnion(removed)
        Task { await reconcileBufferIfNeeded() }
    }

    private func colorForLayerName(_ name: String) -> Color {
        switch name.uppercased() {
        case "ORIGINAL": return Color(red: 228/255, green: 228/255, blue: 234/255)
        case "OFFSET": return Color.status_warn
        case "SEWING_HOLES": return Color.status_ok
        case "CUTLINE": return Color.accent
        case "DRAWN_SHAPES": return Color.cyan
        case "UNFOLDED_3D": return Color(red: 0.9, green: 0.1, blue: 0.9)
        case "PROJECTED_SKETCH": return Color(red: 1.0, green: 0.8, blue: 0.0)
        case "CREASES": return Color.blue
        case "GLUE_TABS": return Color.orange
        case "PATTERN": return Color.yellow
        case "TEXT": return Color.green
        default:
            let hash = abs(name.hashValue)
            let r = Double((hash & 0xFF0000) >> 16) / 255.0
            let g = Double((hash & 0x00FF00) >> 8) / 255.0
            let b = Double(hash & 0x0000FF) / 255.0
            return Color(red: r, green: g, blue: b)
        }
    }

    // MARK: - Text Inline Editing
    func generateNextHandle() -> String {
        var maxHandleVal = 0
        for ent in entities {
            if let val = Int(ent.handle, radix: 16) {
                if val > maxHandleVal {
                    maxHandleVal = val
                }
            }
        }
        let nextVal = max(maxHandleVal + 1, 0xF0000)
        return String(nextVal, radix: 16).uppercased()
    }

    func startEditingNewText(insert: CGPoint, height: Double) {
        self.isEditingText = true
        self.editingTextHandle = nil
        self.editingTextString = ""
        self.editingTextInsert = insert
        self.editingTextHeight = height
    }
    
    func startEditingText(entity: DXFEntity) {
        self.isEditingText = true
        self.editingTextHandle = entity.handle
        self.editingTextString = entity.text ?? ""
        if let start = entity.start {
            self.editingTextInsert = CGPoint(x: start[0], y: start[1])
        }
        self.editingTextHeight = entity.height ?? 5.0
    }
    
    func cancelTextEditing() {
        self.isEditingText = false
        self.editingTextHandle = nil
        self.editingTextString = ""
    }
    
    func commitTextEditing() {
        guard isEditingText else { return }
        let text = editingTextString.isEmpty ? "Label" : editingTextString
        let insert = editingTextInsert
        let height = editingTextHeight
        let handle = editingTextHandle
        
        self.isEditingText = false
        self.editingTextHandle = nil
        self.editingTextString = ""
        
        if let h = handle {
            // Edit existing text in-memory
            saveToHistory()
            self.entities = self.entities.map { entity in
                if entity.handle == h {
                    return DXFEntity(
                        handle: entity.handle,
                        type: entity.type,
                        layer: entity.layer,
                        color: entity.color,
                        start: [Double(insert.x), Double(insert.y)],
                        end: nil,
                        center: nil,
                        radius: nil,
                        start_angle: nil,
                        end_angle: nil,
                        vertices: nil,
                        closed: nil,
                        text: text,
                        height: height
                    )
                } else {
                    return entity
                }
            }
            self.hasUnsavedChanges = true
            
            // Reconcile background DXF
            guard let url = currentFilePath else { return }
            let activeDxfURL = sessionTempDirectory.appendingPathComponent("active.dxf")
            let task = Task<Void, Never> {
                await reconcileBufferIfNeeded()
                do {
                    _ = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "update_text",
                        args: [
                            "input": url.path,
                            "output": activeDxfURL.path,
                            "handle": h,
                            "text": text,
                            "height": height
                        ]
                    )
                    await MainActor.run {
                        self.currentFilePath = activeDxfURL
                    }
                } catch {
                    print("Background text update failed: \(error)")
                }
            }
            self.reconcileTask = task
        } else {
            // Create new text in-memory
            saveToHistory()
            let tempHandle = "TEMP_" + UUID().uuidString
            let newEntity = DXFEntity(
                handle: tempHandle,
                type: "TEXT",
                layer: "TEXT",
                color: 7,
                start: [Double(insert.x), Double(insert.y)],
                end: nil,
                center: nil,
                radius: nil,
                start_angle: nil,
                end_angle: nil,
                vertices: nil,
                closed: nil,
                text: text,
                height: height
            )
            self.entities.append(newEntity)
            self.recomputeLayersFromEntities()
            self.hasUnsavedChanges = true
            
            // Reconcile background DXF
            let activeDxfURL = ensureActiveDXFFileExists()
            let task = Task<Void, Never> {
                await reconcileBufferIfNeeded()
                do {
                    let res = try await PythonBridge.shared.run(
                        module: "dxf_ops",
                        op: "add_text",
                        args: [
                            "input": activeDxfURL.path,
                            "output": activeDxfURL.path,
                            "text": text,
                            "insert": [Double(insert.x), Double(insert.y)],
                            "height": height,
                            "layer": "TEXT"
                        ]
                    )
                    if let data = res["data"] as? [String: Any],
                       let realHandle = data["handle"] as? String {
                        await MainActor.run {
                            // Update the temporary handle in-memory
                            self.entities = self.entities.map { entity in
                                if entity.handle == tempHandle {
                                    return DXFEntity(
                                        handle: realHandle,
                                        type: entity.type,
                                        layer: entity.layer,
                                        color: entity.color,
                                        start: entity.start,
                                        end: entity.end,
                                        center: entity.center,
                                        radius: entity.radius,
                                        start_angle: entity.start_angle,
                                        end_angle: entity.end_angle,
                                        vertices: entity.vertices,
                                        closed: entity.closed,
                                        text: entity.text,
                                        height: entity.height
                                    )
                                } else {
                                    return entity
                                }
                            }
                            if self.selectedHandles.contains(tempHandle) {
                                self.selectedHandles.remove(tempHandle)
                                self.selectedHandles.insert(realHandle)
                            }
                            for idx in 0..<self.measurements.count {
                                if self.measurements[idx].entityHandle == tempHandle {
                                    self.measurements[idx].entityHandle = realHandle
                                }
                            }
                        }
                    }
                } catch {
                    print("Background text add failed: \(error)")
                }
            }
            self.reconcileTask = task
        }
    }
}
