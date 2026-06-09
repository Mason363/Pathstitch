import SwiftUI
import WebKit

struct SelectedFace: Hashable, Codable {
    let bodyIndex: Int
    let faceIndex: Int
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

struct ThreeDViewport: NSViewRepresentable {
    let selectedFaces3D: Set<SelectedFace>
    let stepJsonContent: String?
    let bodies3D: [Body3D]
    var state: AppState
    
    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "pathstitch")
        config.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
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
    }
}

class Coordinator: NSObject, WKScriptMessageHandler {
    var state: AppState
    weak var webView: WKWebView?
    
    private var isWebViewReady = false
    private var lastLoadedModelPath: String?
    private var lastSelectedJson: String = ""
    private var lastBodyVisibilities: [Int: Bool] = [:]
    
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
        }
    }
    
    func updateModel() {
        guard isWebViewReady, let webView = webView, let jsonStr = state.stepJsonContent else { return }
        let modelPath = state.currentStepFilePath?.path ?? ""
        
        if lastLoadedModelPath != modelPath {
            lastLoadedModelPath = modelPath
            
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
        
        let array = Array(state.selectedFaces3D).map { ["bodyIndex": $0.bodyIndex, "faceIndex": $0.faceIndex] }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: array),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        if lastSelectedJson != jsonStr {
            lastSelectedJson = jsonStr
            let escapedStr = jsonStr.replacingOccurrences(of: "\"", with: "\\\"")
            let js = "setSelectedFaces(\"\(escapedStr)\");"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
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
}
