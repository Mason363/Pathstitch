import SwiftUI
import WebKit

/// Swift↔JS bridge for the construct (assembly) viewport. Mirrors the proven
/// `ThreeDViewport` pattern: token-gated `evaluateJavaScript` pushes out, a
/// `WKScriptMessageHandler` for messages in, and a drop-forwarding web view so
/// dropping a `.dxf`/`.stch` adds it to the workspace instead of navigating.
///
/// The real-time XPBD solve (folding, no-stretch propagation) lives entirely in
/// `constructViewport.html`. This bridge only ships the rest model + controls.
struct ConstructViewport: NSViewRepresentable {
    // Declared as explicit values so SwiftUI re-invokes `updateNSView` when any
    // of them changes (the construct state lives on the @Observable AppState).
    let modelToken: Int
    let foldStateToken: Int
    let seamStateToken: Int
    let toolToken: Int
    let brushToken: Int
    let materialToken: Int
    let decalToken: Int
    let homeToken: Int
    var state: AppState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "construct")
        config.userContentController = contentController

        let webView = ConstructDropWebView(frame: .zero, configuration: config)
        webView.registerForDraggedTypes([.fileURL])
        webView.onFileDrop = { [weak state] urls in
            DispatchQueue.main.async { state?.importFiles(urls) }
        }
        context.coordinator.webView = webView

        // Dev live-loading first (so HTML edits show without a rebuild), then the
        // bundled copy — same approach as the 3D viewport.
        let devHtmlURL = URL(fileURLWithPath: "/Users/chen/Documents/Assets/Pathstitch/Pathstitch/Pathstitch/Modes/ConstructMode/constructViewport.html")
        if let html = try? String(contentsOf: devHtmlURL, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: devHtmlURL.deletingLastPathComponent())
        } else if let bundlePath = Bundle.main.path(forResource: "constructViewport", ofType: "html"),
                  let html = try? String(contentsOfFile: bundlePath, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: Bundle.main.bundleURL)
        } else {
            webView.loadHTMLString("<h1>Failed to load construct viewport HTML</h1>", baseURL: nil)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.pushModel()
        context.coordinator.pushControls()
        context.coordinator.pushSeams()
        context.coordinator.pushTool()
        context.coordinator.pushBrush()
        context.coordinator.pushMaterial()
        context.coordinator.pushDecals()
        context.coordinator.pushHome()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var state: AppState
        weak var webView: WKWebView?

        private var ready = false
        private var lastModelToken = -1
        private var lastFoldToken = -1
        private var lastSeamToken = -1
        private var lastToolToken = -1
        private var lastBrushToken = -1
        private var lastMaterialToken = -1
        private var lastDecalToken = -1
        private var lastHomeToken = -1

        init(state: AppState) { self.state = state }

        // MARK: incoming (JS → Swift)
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = json["op"] as? String else { return }

            switch op {
            case "ready":
                DispatchQueue.main.async {
                    self.ready = true
                    self.lastModelToken = -1
                    self.lastFoldToken = -1
                    self.lastSeamToken = -1
                    self.lastToolToken = -1
                    self.lastBrushToken = -1
                    self.lastMaterialToken = -1
                    self.lastDecalToken = -1
                    self.pushModel()
                    self.pushControls()
                    self.pushSeams()
                    self.pushTool()
                    self.pushBrush()
                    self.pushMaterial()
                    self.pushDecals()
                }
            case "selectFold":
                let panelId = json["panelId"] as? Int ?? 0
                let foldId = json["foldId"] as? Int ?? -1
                DispatchQueue.main.async {
                    if foldId >= 0 {
                        self.state.selectedFoldId = "\(panelId)-\(foldId)"
                        if self.state.constructTool == .select { self.state.setConstructTool(.fold) }
                    }
                }
            case "selectPanel":
                let panelId = json["panelId"] as? Int ?? 0
                DispatchQueue.main.async {
                    switch self.state.constructTool {
                    case .ground: self.state.setConstructGround(panelId)
                    case .glue:   self.state.pickPanelForGlue(panelId)
                    default: break
                    }
                }
            case "addFold":
                let panelId = json["panelId"] as? Int ?? 0
                let seg = json["seg"] as? [[Double]] ?? []
                DispatchQueue.main.async {
                    if seg.count == 2 && seg[0].count == 2 && seg[1].count == 2 {
                        self.state.addConstructUserFold(panelId: panelId,
                            x0: seg[0][0], y0: seg[0][1], x1: seg[1][0], y1: seg[1][1])
                    }
                }
            case "decalApplied":
                let panelId = json["panelId"] as? Int ?? -1
                let dataURL = json["dataURL"] as? String ?? ""
                DispatchQueue.main.async {
                    if panelId >= 0 && !dataURL.isEmpty {
                        self.state.constructDecals[panelId] = dataURL
                        if self.state.constructDecalXforms[panelId] == nil {
                            self.state.constructDecalXforms[panelId] = [0, 0, 1, 0, 0]  // centred, full, upright
                        }
                        self.state.activeDecalPanel = panelId   // framing controls target it
                        self.lastDecalToken = self.state.constructDecalToken  // already applied in JS
                        self.state.hasUnsavedChanges = true
                    }
                }
            case "dragAxis":
                let axis = json["axis"] as? String ?? "screen"
                DispatchQueue.main.async {
                    if self.state.constructDragAxis != axis {
                        self.state.constructDragAxis = axis           // reflect X/Y/Z keys in the UI
                        self.lastBrushToken = self.state.constructBrushToken  // JS already has it
                    }
                }
            case "selectChain":
                let chainId = json["chainId"] as? Int ?? -1
                DispatchQueue.main.async {
                    if self.state.constructTool == .stitch && chainId >= 0 {
                        self.state.pickChainForStitch(chainId)
                    }
                }
            case "stretchReport":
                let pct = json["maxStretchPct"] as? Double ?? 0
                DispatchQueue.main.async { self.state.constructMaxStretchPct = pct }
            case "consoleError":
                let msg = json["message"] as? String ?? ""
                let src = json["source"] as? String ?? ""
                let line = json["lineno"] as? Int ?? 0
                print("🔴 CONSTRUCT JS ERROR: \(msg) at \(src):\(line)")
            default:
                break
            }
        }

        // MARK: outgoing (Swift → JS)
        func pushModel() {
            guard ready, let webView = webView, let json = state.constructModelJSON else { return }
            guard lastModelToken != state.constructModelToken else { return }
            lastModelToken = state.constructModelToken
            lastFoldToken = -1  // re-apply controls to the freshly loaded mesh
            lastSeamToken = -1  // re-apply seams to the freshly loaded mesh
            lastDecalToken = -1 // re-apply decals to the freshly loaded mesh
            let esc = Self.escape(json)
            webView.evaluateJavaScript("loadConstructModel(\"\(esc)\");", completionHandler: nil)
        }

        func pushControls() {
            guard ready, let webView = webView else { return }
            guard lastFoldToken != state.constructFoldStateToken else { return }
            lastFoldToken = state.constructFoldStateToken
            let esc = Self.escape(state.constructControlsJSON)
            webView.evaluateJavaScript("setConstructControls(\"\(esc)\");", completionHandler: nil)
        }

        func pushSeams() {
            guard ready, let webView = webView else { return }
            guard lastSeamToken != state.constructSeamStateToken else { return }
            lastSeamToken = state.constructSeamStateToken
            let esc = Self.escape(state.constructSeamsJSON)
            webView.evaluateJavaScript("setConstructSeams(\"\(esc)\");", completionHandler: nil)
        }

        func pushTool() {
            guard ready, let webView = webView else { return }
            guard lastToolToken != state.constructToolToken else { return }
            lastToolToken = state.constructToolToken
            webView.evaluateJavaScript("setConstructTool('\(state.constructTool.rawValue)');", completionHandler: nil)
        }

        func pushBrush() {
            guard ready, let webView = webView else { return }
            guard lastBrushToken != state.constructBrushToken else { return }
            lastBrushToken = state.constructBrushToken
            webView.evaluateJavaScript("setConstructBrush(\(state.constructBrushRadius));", completionHandler: nil)
            webView.evaluateJavaScript("setConstructDragAxis('\(state.constructDragAxis)');", completionHandler: nil)
        }

        func pushMaterial() {
            guard ready, let webView = webView else { return }
            guard lastMaterialToken != state.constructMaterialToken else { return }
            lastMaterialToken = state.constructMaterialToken
            webView.evaluateJavaScript("setConstructMaterial(\(state.constructMaterialColorInt));", completionHandler: nil)
            webView.evaluateJavaScript("setConstructThickness(\(state.constructThicknessMm));", completionHandler: nil)
        }

        func pushDecals() {
            guard ready, let webView = webView else { return }
            guard lastDecalToken != state.constructDecalToken else { return }
            lastDecalToken = state.constructDecalToken
            let esc = Self.escape(state.constructDecalsJSON)
            webView.evaluateJavaScript("setConstructDecals(\"\(esc)\");", completionHandler: nil)
        }

        func pushHome() {
            guard ready, let webView = webView else { return }
            guard lastHomeToken != state.triggerConstructHomeToken else { return }
            lastHomeToken = state.triggerConstructHomeToken
            webView.evaluateJavaScript("recenterCamera();", completionHandler: nil)
        }

        private static func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
             .replacingOccurrences(of: "\r", with: "\\r")
        }
    }
}

/// WKWebView that forwards dropped file URLs into the workspace instead of
/// navigating to them (same fix as the 3D viewport's `DropForwardingWebView`).
final class ConstructDropWebView: WKWebView {
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
        // An image dropped onto the assembly becomes an artwork decal on the panel
        // under the cursor (visual-only, never added to the 2D geometry). Everything
        // else (.dxf/.stch) is imported into the workspace as before.
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic"]
        if let img = urls.first(where: { imageExts.contains($0.pathExtension.lowercased()) }),
           let data = try? Data(contentsOf: img) {
            let pt = convert(sender.draggingLocation, from: nil)
            let nx = Double(pt.x / max(bounds.width, 1)) * 2 - 1
            let ny = Double(pt.y / max(bounds.height, 1)) * 2 - 1   // AppKit y is bottom-up = NDC y
            let mimes = ["png": "image/png", "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp"]
            let mime = mimes[img.pathExtension.lowercased()] ?? "image/jpeg"
            let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
            DispatchQueue.main.async {
                self.evaluateJavaScript("applyDroppedDecal('\(dataURL)', \(nx), \(ny));", completionHandler: nil)
            }
            return true
        }
        onFileDrop?(urls)
        return true
    }
}
