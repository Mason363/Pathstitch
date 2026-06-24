import SwiftUI
import WebKit

struct SelectedFace: Hashable, Codable {
    let bodyIndex: Int
    let faceIndex: Int
}

struct SelectedEdge: Hashable, Codable {
    let bodyIndex: Int
    let edgeIndex: Int
}

struct Face3D: Identifiable, Codable, Hashable {
    var id: String { "\(face_index)" }
    let face_index: Int
    let type: String
    let area: Double
}

struct Body3D: Identifiable, Codable, Hashable {
    var id: String { name }
    let body_index: Int
    let name: String
    let faces: [Face3D]
    var visible: Bool = true

    enum CodingKeys: String, CodingKey {
        case body_index
        case name
        case faces
    }

    init(body_index: Int, name: String, faces: [Face3D], visible: Bool = true) {
        self.body_index = body_index
        self.name = name
        self.faces = faces
        self.visible = visible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.body_index = try container.decode(Int.self, forKey: .body_index)
        self.name = try container.decode(String.self, forKey: .name)
        self.faces = try container.decode([Face3D].self, forKey: .faces)
        self.visible = true
    }
}

/// WKWebView that forwards dropped file URLs to a handler instead of letting
/// WebKit navigate to them. Without this the 3D viewport (a web view) swallows
/// every file drop after the first model loads, so you could only ever import
/// one STEP — dropping more onto the model did nothing. Now drops on the
/// viewport append into the same 3D workspace, side by side.
final class DropForwardingWebView: WKWebView {
    var onFileDrop: (([URL]) -> Void)?

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileURLs(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onFileDrop?(urls)
        return true
    }
}

struct ThreeDViewport: NSViewRepresentable {
    let selectedFaces3D: Set<SelectedFace>
    let stepJsonContent: String?
    let bodies3D: [Body3D]
    
    let isPlaneSelectionActive: Bool
    let planeSelectionModeType: String
    let selectedProjectionPlane: String?
    let selectedProjectionFaceIndex: Int?
    let selectedProjectionBodyIndex: Int?
    let planeOffset: Double
    let threeDOrthographic: Bool
    let triggerCameraAnimationToken: Int
    let triggerHomeFrameToken: Int

    // Body move tool (MAS-125)
    let bodyMoveToolActive: Bool
    let selectedBodyIndex: Int?
    let bodyOffsetsJSON: String
    let bodyMoveStateToken: Int

    // Phase 2 & 3: Seam Control & Distortion Heatmap
    let forcedSeams3D: Set<SelectedEdge>
    let forbiddenSeams3D: Set<SelectedEdge>
    let seamControlMode: String
    let distortionDataJSON: String

    var state: AppState
    
    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "pathstitch")
        config.userContentController = contentController
        
        let webView = DropForwardingWebView(frame: .zero, configuration: config)
        // Forward file drops onto the 3D viewport into the import pipeline, which
        // appends STEP models into this same workspace (single or several at once).
        webView.registerForDraggedTypes([.fileURL])
        webView.onFileDrop = { [weak state] urls in
            DispatchQueue.main.async { state?.importFiles(urls) }
        }
        context.coordinator.webView = webView

        // Development live-loading check
        let devHtmlURL = URL(fileURLWithPath: "/Users/chen/Documents/Assets/Pathstitch/Pathstitch/Pathstitch/Modes/ThreeDMode/viewport3d.html")
        if let htmlContent = try? String(contentsOf: devHtmlURL, encoding: .utf8) {
            webView.loadHTMLString(htmlContent, baseURL: devHtmlURL.deletingLastPathComponent())
        } else if let bundleHtmlPath = Bundle.main.path(forResource: "viewport3d", ofType: "html"),
                  let htmlContent = try? String(contentsOfFile: bundleHtmlPath, encoding: .utf8) {
            webView.loadHTMLString(htmlContent, baseURL: Bundle.main.bundleURL)
        } else {
            webView.loadHTMLString("<h1>Failed to load 3D viewport HTML</h1>", baseURL: nil)
        }
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.updateModel()
        context.coordinator.updateSelection()
        context.coordinator.updateBodyVisibilities()
        context.coordinator.updatePlaneSelectionState()
        context.coordinator.updateOrthographicMode()
        context.coordinator.updateHomeFrame()
        context.coordinator.updateBodyMoveState()
        context.coordinator.updateSeams()
        context.coordinator.updateDistortion()
    }
}

class Coordinator: NSObject, WKScriptMessageHandler {
    var state: AppState
    weak var webView: WKWebView?
    
    private var isWebViewReady = false
    private var lastLoadedModelPath: String?
    private var lastSelectedJson: String = ""
    private var lastSelectedFaces: Set<SelectedFace> = []
    private var lastBodyVisibilities: [Int: Bool] = [:]
    
    private var lastPlaneSelectionActive = false
    private var lastPlaneSelectionModeType = "origin"
    private var lastSelectedProjectionPlane: String? = nil
    private var lastSelectedProjectionFaceIndex: Int? = nil
    private var lastSelectedProjectionBodyIndex: Int? = nil
    private var lastPlaneOffset: Double = 0.0
    private var lastTriggerCameraAnimationToken = 0
    private var lastTriggerHomeFrameToken = 0
    private var lastThreeDOrthographic = false
    private var lastBodyMoveStateToken = -1
    
    // Seams and distortion tracking
    private var lastForcedSeams: Set<SelectedEdge> = []
    private var lastForbiddenSeams: Set<SelectedEdge> = []
    private var lastSeamControlMode: String = "auto"
    private var lastDistortionDataJSON: String = ""
    
    init(state: AppState) {
        self.state = state
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let messageBody = message.body as? String,
              let data = messageBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        guard let op = json["op"] as? String else { return }
        
        if op == "ready" {
            DispatchQueue.main.async {
                self.isWebViewReady = true
                self.lastLoadedModelPath = nil // Force load
                self.updateModel()
                self.updateSelection()
                self.updateBodyVisibilities()
                self.updatePlaneSelectionState()
                self.lastBodyMoveStateToken = -1
                self.updateBodyMoveState()

                // Force update orthographic mode
                self.lastThreeDOrthographic = !self.state.threeDOrthographic
                self.updateOrthographicMode()
            }
        } else if op == "selectFace" {
            let bodyIndex = json["bodyIndex"] as? Int ?? 0
            let faceIndex = json["faceIndex"] as? Int ?? 0
            let isShiftKey = json["isShiftKey"] as? Bool ?? false
            
            DispatchQueue.main.async {
                let faceSel = SelectedFace(bodyIndex: bodyIndex, faceIndex: faceIndex)
                if isShiftKey {
                    if self.state.selectedFaces3D.contains(faceSel) {
                        self.state.selectedFaces3D.remove(faceSel)
                    } else {
                        self.state.selectedFaces3D.insert(faceSel)
                    }
                } else {
                    self.state.selectedFaces3D = [faceSel]
                }
            }
        } else if op == "clearSelection" {
            DispatchQueue.main.async {
                self.state.selectedFaces3D.removeAll()
            }
        } else if op == "selectBody" {
            // Body move tool: a body was clicked in the viewport (MAS-125).
            let bodyIndex = json["bodyIndex"] as? Int ?? 0
            DispatchQueue.main.async {
                self.state.selectBody(bodyIndex)
            }
        } else if op == "bodyMoveBegin" {
            // Gizmo drag started — snapshot offsets so the move is one undo step.
            DispatchQueue.main.async {
                self.state.beginBodyMove()
            }
        } else if op == "bodyMoved" {
            // The 3D translate gizmo dragged a body; persist its new offset.
            let bodyIndex = json["bodyIndex"] as? Int ?? 0
            let x = json["x"] as? Double ?? 0.0
            let y = json["y"] as? Double ?? 0.0
            let z = json["z"] as? Double ?? 0.0
            DispatchQueue.main.async {
                // Don't echo back to the viewport — it already reflects the drag.
                self.state.setBodyOffset(index: bodyIndex, x: x, y: y, z: z, pushToViewport: false)
                self.lastBodyMoveStateToken = self.state.bodyMoveStateToken
            }
        } else if op == "selectProjectionPlane" {
            let plane = json["plane"] as? String ?? "XY"
            DispatchQueue.main.async {
                self.state.selectedProjectionPlane = plane
            }
        } else if op == "selectProjectionFace" {
            let bodyIdx = json["bodyIndex"] as? Int ?? 0
            let faceIdx = json["faceIndex"] as? Int ?? 0
            let norm = json["normal"] as? [Double]
            let orig = json["origin"] as? [Double]
            DispatchQueue.main.async {
                self.state.selectedProjectionPlane = "face"
                self.state.selectedProjectionFaceIndex = faceIdx
                self.state.selectedProjectionBodyIndex = bodyIdx
                self.state.selectedProjectionFaceNormal = norm
                self.state.selectedProjectionFaceOrigin = orig
            }
        } else if op == "selectEdge" {
            let bodyIndex = json["bodyIndex"] as? Int ?? 0
            let edgeIndex = json["edgeIndex"] as? Int ?? 0
            DispatchQueue.main.async {
                let edgeSel = SelectedEdge(bodyIndex: bodyIndex, edgeIndex: edgeIndex)
                self.state.selectedEdge3D = edgeSel
                if self.state.seamControlMode == "manual" {
                    if self.state.forcedSeams3D.contains(edgeSel) {
                        self.state.forcedSeams3D.remove(edgeSel)
                    } else {
                        self.state.forcedSeams3D.insert(edgeSel)
                        self.state.forbiddenSeams3D.remove(edgeSel)
                    }
                } else if self.state.seamControlMode == "hybrid" {
                    if self.state.forbiddenSeams3D.contains(edgeSel) {
                        self.state.forbiddenSeams3D.remove(edgeSel)
                    } else {
                        self.state.forbiddenSeams3D.insert(edgeSel)
                        self.state.forcedSeams3D.remove(edgeSel)
                    }
                }
            }
        } else if op == "updateOffset" {
            let offset = json["offset"] as? Double ?? 0.0
            DispatchQueue.main.async {
                self.state.planeOffset = offset
                self.lastPlaneOffset = offset
            }
        } else if op == "confirmProjection" {
            DispatchQueue.main.async {
                self.state.confirmPlaneProjection()
            }
        } else if op == "cameraAnimationComplete" {
            DispatchQueue.main.async {
                self.state.executeProjection()
            }
        } else if op == "consoleError" {
            let msg = json["message"] as? String ?? ""
            let src = json["source"] as? String ?? ""
            let line = json["lineno"] as? Int ?? 0
            let col = json["colno"] as? Int ?? 0
            let stack = json["error"] as? String ?? ""
            print("🔴 JS ERROR: \(msg) at \(src):\(line):\(col)\n\(stack)")
        }
    }
    
    func updatePlaneSelectionState() {
        guard isWebViewReady, let webView = webView else { return }
        
        let active = state.isPlaneSelectionActive
        let modeType = state.planeSelectionModeType
        let selPlane = state.selectedProjectionPlane ?? ""
        let selFaceIdx = state.selectedProjectionFaceIndex ?? -1
        let selBodyIdx = state.selectedProjectionBodyIndex ?? -1
        let offset = state.planeOffset
        
        if lastPlaneSelectionActive != active ||
           lastPlaneSelectionModeType != modeType ||
           lastSelectedProjectionPlane != selPlane ||
           lastSelectedProjectionFaceIndex != selFaceIdx ||
           lastSelectedProjectionBodyIndex != selBodyIdx ||
           lastPlaneOffset != offset {
            
            lastPlaneSelectionActive = active
            lastPlaneSelectionModeType = modeType
            lastSelectedProjectionPlane = selPlane
            lastSelectedProjectionFaceIndex = selFaceIdx
            lastSelectedProjectionBodyIndex = selBodyIdx
            lastPlaneOffset = offset
            
            let js = "setPlaneSelectionState(\(active ? "true" : "false"), '\(modeType)', '\(selPlane)', \(selFaceIdx), \(selBodyIdx), \(offset));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        
        if lastTriggerCameraAnimationToken != state.triggerCameraAnimationToken {
            lastTriggerCameraAnimationToken = state.triggerCameraAnimationToken
            let js = "animateCameraToPlane();"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// Recenters/optimally frames the 3D model when the Home button is pressed.
    func updateHomeFrame() {
        guard isWebViewReady, let webView = webView else { return }
        if lastTriggerHomeFrameToken != state.triggerHomeFrameToken {
            lastTriggerHomeFrameToken = state.triggerHomeFrameToken
            webView.evaluateJavaScript("recenterCamera();", completionHandler: nil)
        }
    }
    
    /// Pushes the body-move tool state (active flag, selected body, per-body
    /// offsets) to the viewport whenever it changes (MAS-125).
    func updateBodyMoveState() {
        guard isWebViewReady, let webView = webView else { return }
        guard lastBodyMoveStateToken != state.bodyMoveStateToken else { return }
        lastBodyMoveStateToken = state.bodyMoveStateToken

        let active = state.bodyMoveToolActive ? "true" : "false"
        let sel = state.selectedBodyIndex ?? -1
        let offsetsEscaped = state.bodyOffsetsJSON.replacingOccurrences(of: "\"", with: "\\\"")
        let js = "setBodyMoveState(\(active), \(sel), \"\(offsetsEscaped)\");"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func updateModel() {
        guard isWebViewReady, let webView = webView, let jsonStr = state.stepJsonContent else { return }
        let modelPath = state.currentStepFilePath?.path ?? ""

        if lastLoadedModelPath != modelPath {
            lastLoadedModelPath = modelPath
            lastBodyMoveStateToken = -1  // re-push body-move state for the new model
            lastSelectedFaces.removeAll() // Force selection update for the new model
            lastForcedSeams.removeAll()
            lastForbiddenSeams.removeAll()
            lastSeamControlMode = "auto"
            lastDistortionDataJSON = ""
            
            // Re-initialize body visibilities tracking
            lastBodyVisibilities.removeAll()
            for body in state.bodies3D {
                lastBodyVisibilities[body.body_index] = body.visible
            }
            
            let escapedStr = jsonStr.replacingOccurrences(of: "\\", with: "\\\\")
                                    .replacingOccurrences(of: "\"", with: "\\\"")
                                    .replacingOccurrences(of: "\n", with: "\\n")
                                    .replacingOccurrences(of: "\r", with: "\\r")
            
            let js = "loadModel(\"\(escapedStr)\\n\");"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    func updateSelection() {
        guard isWebViewReady, let webView = webView else { return }
        
        let currentSelection = state.selectedFaces3D
        if lastSelectedFaces == currentSelection {
            return
        }
        lastSelectedFaces = currentSelection
        
        let array = Array(currentSelection).map { ["bodyIndex": $0.bodyIndex, "faceIndex": $0.faceIndex] }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: array),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        lastSelectedJson = jsonStr
        let escapedStr = jsonStr.replacingOccurrences(of: "\"", with: "\\\"")
        let js = "setSelectedFaces(\"\(escapedStr)\");"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    func updateBodyVisibilities() {
        guard isWebViewReady, let webView = webView else { return }
        
        for body in state.bodies3D {
            let idx = body.body_index
            let visible = body.visible
            if lastBodyVisibilities[idx] != visible {
                lastBodyVisibilities[idx] = visible
                let js = "setBodyVisibility(\(idx), \(visible ? "true" : "false"));"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
    
    func updateOrthographicMode() {
        guard isWebViewReady, let webView = webView else { return }
        let ortho = state.threeDOrthographic
        if lastThreeDOrthographic != ortho {
            lastThreeDOrthographic = ortho
            let js = "setOrthographicMode(\(ortho ? "true" : "false"));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    func updateSeams() {
        guard isWebViewReady, let webView = webView else { return }
        
        let forced = state.forcedSeams3D
        let forbidden = state.forbiddenSeams3D
        let mode = state.seamControlMode
        
        if lastForcedSeams != forced || lastForbiddenSeams != forbidden || lastSeamControlMode != mode {
            lastForcedSeams = forced
            lastForbiddenSeams = forbidden
            lastSeamControlMode = mode
            
            let forcedArr = Array(forced).map { ["bodyIndex": $0.bodyIndex, "edgeIndex": $0.edgeIndex] }
            let forbiddenArr = Array(forbidden).map { ["bodyIndex": $0.bodyIndex, "edgeIndex": $0.edgeIndex] }
            
            guard let forcedData = try? JSONSerialization.data(withJSONObject: forcedArr),
                  let forcedStr = String(data: forcedData, encoding: .utf8),
                  let forbiddenData = try? JSONSerialization.data(withJSONObject: forbiddenArr),
                  let forbiddenStr = String(data: forbiddenData, encoding: .utf8) else {
                return
            }
            
            let escapedForced = forcedStr.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedForbidden = forbiddenStr.replacingOccurrences(of: "\"", with: "\\\"")
            let js = "setSeams(\"\(escapedForced)\", \"\(escapedForbidden)\", \"\(mode)\");"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    func updateDistortion() {
        guard isWebViewReady, let webView = webView else { return }
        
        let current = state.distortionDataJSON
        if lastDistortionDataJSON != current {
            lastDistortionDataJSON = current
            
            let escapedStr = current.replacingOccurrences(of: "\"", with: "\\\"")
            let js = "setFaceDistortion(\"\(escapedStr)\");"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
