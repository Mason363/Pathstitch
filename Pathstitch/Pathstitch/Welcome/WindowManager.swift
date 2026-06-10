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
    
    /// Opens one or more files, each in its own workspace window.
    func openFiles(_ urls: [URL]) {
        for url in urls {
            openAnyFile(url: url)
        }
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
        let window = NSWindow(contentViewController: hostingController)
        
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Pathstitch"
        window.isReleasedWhenClosed = false
        
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
