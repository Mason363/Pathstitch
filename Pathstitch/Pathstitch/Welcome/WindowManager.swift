import AppKit
import SwiftUI
import UniformTypeIdentifiers

class WindowManager: NSObject, NSApplicationDelegate {
    static let shared = WindowManager()
    
    private var welcomeWindowController: WelcomeWindowController?
    private var documentWindows: [NSWindow] = []
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        showWelcomeWindow()
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
    
    func createNewDocument(fromWindow: NSWindow? = nil) {
        if let targetWindow = fromWindow,
           let delegate = targetWindow.delegate as? DocumentWindowDelegate {
            if delegate.state.hasUnsavedChanges {
                let alert = NSAlert()
                alert.messageText = "Do you want to save the changes made to this document?"
                alert.informativeText = "Your changes will be lost if you don't save them."
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Don't Save")
                
                alert.beginSheetModal(for: targetWindow) { response in
                    if response == .alertFirstButtonReturn {
                        if let current = delegate.state.currentProjectPath {
                            delegate.state.saveProject(to: current)
                            delegate.state.startBlankDocument()
                        } else {
                            // prompt for location
                            delegate.state.saveProjectWithDialog()
                            if !delegate.state.hasUnsavedChanges {
                                delegate.state.startBlankDocument()
                            }
                        }
                    } else if response == .alertThirdButtonReturn {
                        delegate.state.startBlankDocument()
                    }
                }
            } else {
                delegate.state.startBlankDocument()
            }
        } else {
            let state = AppState()
            state.startBlankDocument()
            openDocumentWindow(with: state)
        }
    }
    
    /// Opens one or more files. Projects (`.stch`) and 3D models open in their own
    /// window; importable vector files are grouped into one distributed/batched
    /// workspace (MAS-13). Shared by drag-drop, Finder "Open With", and File ▸ Open.
    func openFiles(_ urls: [URL]) {
        openFilesDistributing(urls)
    }

    /// `.stch`/`.step`/`.stp` each get their own window; the remaining importable
    /// files (`.dxf`/`.svg`/`.pdf`/images) all land in ONE new workspace and are
    /// auto-distributed (fewer than 5) or sent to Batch mode (5+) by
    /// `AppState.importFiles` (MAS-13).
    func openFilesDistributing(_ urls: [URL]) {
        let newWindowExts: Set<String> = ["stch", "step", "stp"]
        let windowFiles = urls.filter { newWindowExts.contains($0.pathExtension.lowercased()) }
        let importable = urls.filter { !newWindowExts.contains($0.pathExtension.lowercased()) }

        for url in windowFiles { openAnyFile(url: url) }

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
        openDocumentWindow(with: state)
    }

    func openAnyFile(url: URL) {
        let ext = url.pathExtension.lowercased()

        if ext == "stch" {
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
            openDocument(url: url)
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
    
    private func openDocumentWindow(with state: AppState) {
        let contentView = ContentView(state: state)
        let hostingController = NSHostingController(rootView: contentView)
        let window = PathstitchDocumentWindow(contentViewController: hostingController, appState: state)
        
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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
        window.makeKeyAndOrderFront(nil)
        
        hideWelcomeWindow()
    }
    
    func removeDocumentWindow(_ window: NSWindow) {
        documentWindows.removeAll(where: { $0 == window })
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
    }
    
    override func sendEvent(_ event: NSEvent) {
        // If editing text (e.g. in a text field), bypass key intercepts to allow normal typing
        if let responder = firstResponder,
           responder.isKind(of: NSText.self) || responder.isKind(of: NSTextView.self) {
            super.sendEvent(event)
            return
        }
        
        // Spacebar Panning (Photoshop style)
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
        
        if event.type == .keyDown {
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
            
            // Only process shortcuts when no modifier key (Cmd/Opt/Ctrl) is pressed
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.isEmpty || modifiers == .capsLock {
                if let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 {
                    switch chars {
                    case "v":
                        appState.currentTool = .select
                        return
                    case "h":
                        appState.currentTool = .pan
                        return
                    case "o":
                        appState.currentTool = .offset
                        return
                    case "s":
                        appState.currentTool = .addHoles
                        return
                    case "j":
                        appState.currentTool = .cleanup
                        return
                    case "m":
                        appState.currentTool = .measure
                    default:
                        break
                    }
                }
            }
        }
        
        super.sendEvent(event)
    }
}
