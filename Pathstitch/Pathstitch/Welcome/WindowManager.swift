import AppKit
import SwiftUI
import UniformTypeIdentifiers

class WindowManager: NSObject, NSApplicationDelegate {
    static let shared = WindowManager()
    
    private var welcomeWindowController: WelcomeWindowController?
    /// The Documentation/Help window, hosted in AppKit on demand. It is NOT a
    /// SwiftUI `Window` scene because those auto-open at launch (ghost window).
    private var documentationWindow: NSWindow?
    private var documentWindows: [NSWindow] = []
    /// `NSWindow.delegate` is a WEAK reference, so the per-window
    /// `DocumentWindowDelegate` must be retained here or it deallocates the
    /// instant `openDocumentWindow` returns — which silently nils out
    /// `NSApp.activeAppState` and breaks every menu command (Save, Undo, …).
    private var documentDelegates: [DocumentWindowDelegate] = []
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't let macOS restore auxiliary windows (a previously-open Settings or
        // Documentation window) on the next launch — the app should start with only
        // the welcome window. This also stops the ghost-window flash.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])

        showWelcomeWindow()

        // Belt-and-suspenders: if any stray auxiliary SwiftUI window slips through
        // at launch, close it immediately (before it can be shown), not on a delay.
        closeStrayAuxiliaryWindows()
        DispatchQueue.main.async { self.closeStrayAuxiliaryWindows() }
    }

    /// Closes any blank Settings/Documentation window SwiftUI may auto-create at
    /// launch. The Documentation window is now AppKit-hosted on demand, so this is
    /// only a safety net.
    private func closeStrayAuxiliaryWindows() {
        for window in NSApp.windows {
            let title = window.title
            if title.localizedCaseInsensitiveContains("Settings")
                || title.localizedCaseInsensitiveContains("Documentation") {
                if window !== documentationWindow { window.close() }
            }
        }
    }

    /// Shows (creating once) the Documentation window, hosting `HelpView` in an
    /// AppKit window so it never auto-opens at launch.
    func showDocumentationWindow() {
        if documentationWindow == nil {
            let hosting = NSHostingController(rootView: HelpView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Documentation"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 720, height: 560))
            window.center()
            documentationWindow = window
        }
        documentationWindow?.makeKeyAndOrderFront(nil)
    }
    
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func showWelcomeWindow() {
        if welcomeWindowController == nil {
            welcomeWindowController = WelcomeWindowController()
        }
        welcomeWindowController?.window?.center()
        welcomeWindowController?.showWindow(nil)
    }
    
    func hideWelcomeWindow() {
        welcomeWindowController?.close()
    }
    
    /// `true` while at least one document workspace window is open. Used by the
    /// welcome window to decide whether closing it should quit the app (MAS-138).
    var hasOpenDocumentWindows: Bool { !documentWindows.isEmpty }

    /// New File always opens a NEW workspace window, leaving any existing window
    /// untouched (MAS-104). `fromWindow` is accepted for call-site compatibility
    /// but no longer replaces that window's document.
    func createNewDocument(fromWindow: NSWindow? = nil) {
        let state = AppState()
        state.startBlankDocument()
        openDocumentWindow(with: state)
    }
    
    /// Opens one or more files. Projects (`.stch`) and 3D models open in their own
    /// window; importable vector files are grouped into one distributed/batched
    /// workspace (MAS-13). Shared by drag-drop, Finder "Open With", and File ▸ Open.
    func openFiles(_ urls: [URL]) {
        openFilesDistributing(urls)
    }

    /// Only `.stch` projects get their own window. Everything else — 3D models
    /// (`.step`/`.stp`) and importable 2D files (`.dxf`/`.svg`/`.pdf`/images) —
    /// lands in ONE new workspace window: 3D and 2D share a workspace (MAS-107),
    /// and 2D files are auto-distributed (fewer than 5) or sent to Batch mode
    /// (5+) by `AppState.importFiles` (MAS-13).
    func openFilesDistributing(_ urls: [URL]) {
        let projectExts: Set<String> = ["stch"]
        let projects = urls.filter { projectExts.contains($0.pathExtension.lowercased()) }
        let importable = urls.filter { !projectExts.contains($0.pathExtension.lowercased()) }

        for url in projects { openAnyFile(url: url) }

        guard !importable.isEmpty else { return }
        let state = AppState()
        state.startBlankDocument()
        openDocumentWindow(with: state)
        for url in importable { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        state.importFiles(importable)
    }

    func openDocument(url: URL) {
        let state = AppState()
        state.loadProject(from: url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        // Re-opening a previously-removed project brings it back to recents.
        RecentsHiding.unhide(url.standardized.path)
        openDocumentWindow(with: state)
    }

    func openAnyFile(url: URL) {
        let ext = url.pathExtension.lowercased()

        if ext == "stch" {
            if !documentWindows.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Import Project"
                alert.informativeText = "Would you like to combine the contents of '\(url.lastPathComponent)' into your active window, or open it in a new window?"
                alert.addButton(withTitle: "Combine")
                alert.addButton(withTitle: "New Window")
                alert.addButton(withTitle: "Cancel")
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    if let activeState = NSApp.activeAppState {
                        activeState.combineProject(from: url)
                    }
                    return
                } else if response == .alertThirdButtonReturn {
                    return
                }
            }
            openDocument(url: url)
            return
        }

        // Start from a clean, valid blank workspace then load the file into it.
        let state = AppState()
        state.startBlankDocument()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        if ext == "pdf" {
            state.importPDF(from: url)
        } else {
            state.loadFile(url: url)
        }
        openDocumentWindow(with: state)
    }
    
    func openProjectWithDialog() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [UTType(filenameExtension: "stch")].compactMap { $0 }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        if openPanel.runModal() == .OK, let url = openPanel.url {
            openAnyFile(url: url)
        }
    }

    /// Opens any supported file type (project, DXF, STEP, SVG, PDF, image),
    /// each in its own workspace window.
    func openAnyFileWithDialog() {
        let exts = ["stch", "dxf", "step", "stp", "svg", "pdf", "png", "jpg", "jpeg", "bmp", "tiff", "gif"]
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        if openPanel.runModal() == .OK {
            openFiles(openPanel.urls)
        }
    }
    
    func importFileWithDialog() {
        let openPanel = NSOpenPanel()
        let exts = ["stch", "dxf", "step", "stp", "svg", "pdf", "png", "jpg", "jpeg", "bmp", "tiff", "gif"]
        openPanel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        if openPanel.runModal() == .OK {
            let urls = openPanel.urls
            // Import goes INTO the active workspace. Only full `.stch` projects
            // open in their own window; 3D models (`.step`/`.stp`) import into the
            // current window like any other content (MAS-107).
            let projectExts: Set<String> = ["stch"]
            let projects = urls.filter { projectExts.contains($0.pathExtension.lowercased()) }
            let others = urls.filter { !projectExts.contains($0.pathExtension.lowercased()) }

            for url in projects {
                openAnyFile(url: url)
            }

            if !others.isEmpty {
                if let activeState = NSApp.activeAppState {
                    activeState.importFiles(others)
                } else {
                    let state = AppState()
                    state.startBlankDocument()
                    openDocumentWindow(with: state)
                    state.importFiles(others)
                }
            }
        }
    }
    
    /// Opens Batch mode as its own workspace window with its own document/state,
    /// completely separate from the 2D/3D drawing (MAS-75).
    func openBatchWorkspace() {
        let state = AppState()
        state.startBlankDocument()
        state.activeMode = .batch
        openDocumentWindow(with: state)
    }

    private func openDocumentWindow(with state: AppState) {
        let contentView = ContentView(state: state)
        let hostingController = NSHostingController(rootView: contentView)
        let window = PathstitchDocumentWindow(contentViewController: hostingController, appState: state)
        
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.title = "Pathstitch"
        window.isReleasedWhenClosed = false
        
        if let lastWindow = documentWindows.last {
            let lastOrigin = lastWindow.frame.origin
            window.setFrameOrigin(NSPoint(x: lastOrigin.x + 30.0, y: lastOrigin.y - 30.0))
        } else {
            window.center()
        }
        
        let delegate = DocumentWindowDelegate(window: window, state: state)
        window.delegate = delegate

        documentWindows.append(window)
        documentDelegates.append(delegate)
        window.makeKeyAndOrderFront(nil)
        
        hideWelcomeWindow()
    }
    
    /// Reviews every open document with unsaved changes before the app quits
    /// (⌘Q). Prompts per window (Save / Cancel / Don't Save); cancelling any
    /// prompt — or cancelling a Save dialog — aborts termination. The save
    /// methods are synchronous, so `hasUnsavedChanges` is reliable right after.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = documentDelegates.filter { $0.state.hasUnsavedChanges }
        guard !dirty.isEmpty else { return .terminateNow }

        for delegate in dirty {
            guard let window = delegate.window else { continue }
            window.makeKeyAndOrderFront(nil)

            let name = delegate.state.currentProjectPath?.lastPathComponent ?? "untitled.stch"
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes made to “\(name)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")        // .alertFirstButtonReturn
            alert.addButton(withTitle: "Cancel")      // .alertSecondButtonReturn
            alert.addButton(withTitle: "Don't Save")  // .alertThirdButtonReturn

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let current = delegate.state.currentProjectPath {
                    delegate.state.saveProject(to: current)
                } else {
                    delegate.state.saveProjectWithDialog()
                }
                // Save dialog cancelled → still dirty → abort the quit.
                if delegate.state.hasUnsavedChanges { return .terminateCancel }
            } else if response == .alertSecondButtonReturn {
                return .terminateCancel
            }
            // Don't Save → fall through to the next dirty document.
        }
        return .terminateNow
    }

    func removeDocumentWindow(_ window: NSWindow) {
        documentWindows.removeAll(where: { $0 == window })
        documentDelegates.removeAll(where: { $0.window == window })
        if documentWindows.isEmpty {
            showWelcomeWindow()
        }
    }
}

class DocumentWindowDelegate: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    let state: AppState
    
    init(window: NSWindow, state: AppState) {
        self.window = window
        self.state = state
        super.init()
        // Reflect unsaved changes in the window's close-button dot (MAS-21).
        window.isDocumentEdited = state.hasUnsavedChanges
        observeDirtyState()
    }

    /// Keeps `window.isDocumentEdited` in sync with the document's dirty flag.
    /// `withObservationTracking` fires once per change, so it re-arms itself.
    private func observeDirtyState() {
        withObservationTracking {
            _ = state.hasUnsavedChanges
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.window?.isDocumentEdited = self.state.hasUnsavedChanges
                self.observeDirtyState()
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if state.hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes made to this document?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")     // .alertFirstButtonReturn
            alert.addButton(withTitle: "Cancel")   // .alertSecondButtonReturn
            alert.addButton(withTitle: "Discard")  // .alertThirdButtonReturn

            alert.beginSheetModal(for: sender) { response in
                if response == .alertFirstButtonReturn {
                    // Save → keep window open if the save panel was cancelled.
                    if let current = self.state.currentProjectPath {
                        self.state.saveProject(to: current)
                        if !self.state.hasUnsavedChanges { sender.close() }
                    } else {
                        self.state.saveProjectWithDialog()
                        if !self.state.hasUnsavedChanges { sender.close() }
                    }
                } else if response == .alertThirdButtonReturn {
                    // Discard → close, abandoning changes.
                    self.state.hasUnsavedChanges = false
                    sender.close()
                }
                // Cancel (.alertSecondButtonReturn) → do nothing; window stays open.
            }
            return false // Defer until sheet response
        }
        return true
    }
    
    func windowWillClose(_ notification: Notification) {
        if let window = window {
            WindowManager.shared.removeDocumentWindow(window)
        }
    }
}

class PathstitchDocumentWindow: NSWindow {
    let appState: AppState
    private var preSpaceTool: TwoDTool? = nil
    
    init(contentViewController: NSViewController, appState: AppState) {
        self.appState = appState
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.backgroundColor = .pathstitchWindowBackground   // adaptive (MAS-72)
        self.contentViewController = contentViewController
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let titlebarView = self.standardWindowButton(.closeButton)?.superview {
                let titleHostingView = NSHostingView(rootView: TitleBarView(state: appState))
                titleHostingView.frame = titlebarView.bounds
                titleHostingView.autoresizingMask = [.width, .height]
                titlebarView.addSubview(titleHostingView)
            }
        }
    }
    
    override func sendEvent(_ event: NSEvent) {
        // If editing text (e.g. in a text field), bypass key intercepts to allow normal typing
        if let responder = firstResponder,
           responder.isKind(of: NSText.self) || responder.isKind(of: NSTextView.self) {
            super.sendEvent(event)
            return
        }
        
        // Spacebar Panning (Photoshop style)
        if event.type == .keyDown || event.type == .keyUp {
            if event.keyCode == 49 { // Spacebar
                if event.type == .keyDown {
                    if !event.isARepeat {
                        if appState.currentTool != .pan {
                            preSpaceTool = appState.currentTool
                            appState.currentTool = .pan
                        }
                    }
                    return
                } else if event.type == .keyUp {
                    if let oldTool = preSpaceTool {
                        appState.currentTool = oldTool
                        preSpaceTool = nil
                    }
                    return
                }
            }
        }
        
        if event.type == .keyDown {
            // Reference image transform and trace handling
            if appState.isTracingRefImage {
                if event.keyCode == 53 { // ESC
                    appState.isTracingRefImage = false
                    appState.tracePreviewEntities = []
                    return
                }
                if event.keyCode == 36 || event.keyCode == 76 { // ENTER
                    appState.commitTrace()
                    return
                }
                if event.keyCode == 123 { // Left Arrow
                    appState.traceTolerance = max(1.0, appState.traceTolerance - 1.0)
                    appState.updateTracePreview()
                    return
                }
                if event.keyCode == 124 { // Right Arrow
                    appState.traceTolerance = min(100.0, appState.traceTolerance + 1.0)
                    appState.updateTracePreview()
                    return
                }
            } else if appState.isEditingRefImageTransform {
                if event.keyCode == 53 { // ESC
                    appState.restoreActiveLayerTransform()
                    appState.isEditingRefImageTransform = false
                    return
                }
                if event.keyCode == 36 || event.keyCode == 76 { // ENTER
                    appState.isEditingRefImageTransform = false
                    return
                }
            }

            // Escape key cancels add plane if active
            if event.keyCode == 53 {
                if appState.isPlaneSelectionActive {
                    appState.cancelPlaneSelection()
                    return
                }
            }
            
            // Return / Enter confirms the active action for commit-capable tools
            // (Line, Pen, and Fillet/Chamfer). Text fields are already bypassed
            // above, so this never interferes with typing/onSubmit.
            if event.keyCode == 36 || event.keyCode == 76 {
                if appState.currentTool == .sketchLine || appState.currentTool == .pen
                    || appState.currentTool.isCornerTool {
                    appState.commitToolToken += 1
                    return
                }
            }

            // Check for Delete / Backspace keys (Backspace is 51, Delete/Forward Delete is 117)
            if event.keyCode == 51 || event.keyCode == 117 {
                if appState.selectedMeasurement != nil {
                    appState.deleteSelectedMeasurement()
                    return
                } else if !appState.selectedHandles.isEmpty {
                    appState.deleteSelectedEntities()
                    return
                }
            }
            
            // Match against customizable keybind commands
            let keybinds = KeybindStore.shared
            for cmd in AppCommands.all {
                let combo = keybinds.combo(for: cmd.id)
                if combo.key != "" && combo.matches(event: event) {
                    if cmd.isEnabled(appState) {
                        cmd.action(appState)
                    }
                    return
                }
            }
        }
        
        super.sendEvent(event)
    }
}

struct TitleBarView: View {
    let state: AppState
    
    var body: some View {
        HStack(spacing: 0) {
            // Left block (fixed width of 150px to clear traffic lights and mode text)
            HStack(spacing: 0) {
                Spacer().frame(width: 76)
                
                let modeShortStr: String = {
                    switch state.activeMode {
                    case .twoD: return "2D"
                    case .batch: return "Batch"
                    case .threeD: return "3D"
                    }
                }()
                
                Text(modeShortStr)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color.accent)
                
                Spacer()
            }
            .frame(width: 150)
            
            Spacer()
            
            // Center block: filename, with a bullet when there are unsaved
            // changes (the custom title bar hides the native edited indicator).
            let fileName = state.currentProjectPath?.lastPathComponent ?? "untitled.stch"
            HStack(spacing: 6) {
                Text(fileName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color.text_primary)
                if state.hasUnsavedChanges {
                    Circle()
                        .fill(Color.text_secondary)
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
            }
            
            Spacer()
            
            // Right block (fixed width of 150px containing buttons)
            HStack(spacing: 0) {
                Spacer()
                
                if state.activeMode == .twoD {
                    HStack(spacing: 12) {
                        Button(action: {
                            // Home = optimal framing, not a naive reset to 1:1 at
                            // the origin (MAS-67). Drives the canvas's robust
                            // fitToContent via fitRequestToken.
                            state.fitRequestToken += 1
                        }) {
                            Image(systemName: "house.fill")
                                .foregroundColor(Color.text_primary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Frame All (Home)")

                        Button(action: { state.snapEnabled.toggle() }) {
                            Image(systemName: state.snapEnabled ? "dot.scope" : "scope")
                                .foregroundColor(state.snapEnabled ? Color.accent : Color.text_secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(state.snapEnabled ? "Snapping: On" : "Snapping: Off")

                        Button(action: { state.chainSelectionEnabled.toggle() }) {
                            Image(systemName: state.chainSelectionEnabled ? "link.circle.fill" : "link.circle")
                                .foregroundColor(state.chainSelectionEnabled ? Color.accent : Color.text_secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(state.chainSelectionEnabled ? "Chain Selection: On" : "Chain Selection: Off")

                        Button(action: { state.gridVisible.toggle() }) {
                            Image(systemName: state.gridVisible ? "grid" : "grid.circle")
                                .foregroundColor(state.gridVisible ? Color.accent : Color.text_secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(state.gridVisible ? "Grid: Visible" : "Grid: Hidden")

                        Button(action: { state.autocropBackgroundlessImage.toggle() }) {
                            Image(systemName: "crop")
                                .foregroundColor(state.autocropBackgroundlessImage ? Color.accent : Color.text_secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Crop Transparent Margins: \(state.autocropBackgroundlessImage ? "On" : "Off")")


                        Button(action: { state.isLogTrayExpanded.toggle() }) {
                            Image(systemName: state.isLogTrayExpanded ? "terminal.fill" : "terminal")
                                .foregroundColor(state.isLogTrayExpanded ? Color.accent : Color.text_secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(state.isLogTrayExpanded ? "Log Tray: Expanded" : "Log Tray: Collapsed")
                    }
                    .padding(.trailing, 16)
                } else if state.activeMode == .threeD {
                    HStack(spacing: 12) {
                        Button(action: { state.threeDOrthographic.toggle() }) {
                            Image(systemName: state.threeDOrthographic ? "cube.fill" : "cube")
                                .foregroundColor(state.threeDOrthographic ? Color.accent : Color.text_secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(state.threeDOrthographic ? "View: Orthographic" : "View: Perspective")
                        
                        Button(action: { state.isLogTrayExpanded.toggle() }) {
                            Image(systemName: state.isLogTrayExpanded ? "terminal.fill" : "terminal")
                                .foregroundColor(state.isLogTrayExpanded ? Color.accent : Color.text_secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(state.isLogTrayExpanded ? "Log Tray: Expanded" : "Log Tray: Collapsed")
                    }
                    .padding(.trailing, 16)
                }
            }
            .frame(width: 150)
        }
        .frame(maxHeight: .infinity)
    }
}
