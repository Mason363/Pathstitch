import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowManager.shared.applicationDidFinishLaunching(notification)
    }
    
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return WindowManager.shared.applicationShouldOpenUntitledFile(sender)
    }

    /// Routes files opened from Finder (double-click, "Open With", drag onto the
    /// Dock icon) into Pathstitch windows. Without this, opening a `.stch` did
    /// nothing useful and macOS could surface a blank window (MAS-14, MAS-37).
    func application(_ application: NSApplication, open urls: [URL]) {
        WindowManager.shared.openFiles(urls)
    }
}

extension NSApplication {
    var activeAppState: AppState? {
        if let keyWindow = self.keyWindow,
           let delegate = keyWindow.delegate as? DocumentWindowDelegate {
            return delegate.state
        }
        return nil
    }
}

@main
struct PathstitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // File persistence menu items (Open, Save, Save As)
            CommandGroup(replacing: .saveItem) {
                Button("New File") {
                    WindowManager.shared.createNewDocument(fromWindow: NSApp.keyWindow)
                }
                .keyboardShortcut("n", modifiers: [.command])
                
                Button("Open Project...") {
                    WindowManager.shared.openProjectWithDialog()
                }
                .keyboardShortcut("o", modifiers: [.command])
                
                Divider()
                
                Button("Save Project") {
                    if let state = NSApp.activeAppState {
                        if let current = state.currentProjectPath {
                            // Flush optimistic in-memory edits, then persist (MAS-21).
                            state.reconcileThenSave(to: current)
                        } else {
                            state.saveProjectWithDialog()
                        }
                    }
                }
                .keyboardShortcut("s", modifiers: [.command])
                
                Button("Save Project As...") {
                    if let state = NSApp.activeAppState {
                        state.saveProjectWithDialog()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NSApp.activeAppState?.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                
                Button("Redo") {
                    NSApp.activeAppState?.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Delete") {
                    NSApp.activeAppState?.deleteSelectedEntities()
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
            
            // Selection / Tools menu
            CommandMenu("Tools") {
                Button("Select") { NSApp.activeAppState?.currentTool = .select }
                    .keyboardShortcut("v", modifiers: [])
                Button("Pan") { NSApp.activeAppState?.currentTool = .pan }
                    .keyboardShortcut("h", modifiers: [])
                Button("Offset") { NSApp.activeAppState?.currentTool = .offset }
                    .keyboardShortcut("o", modifiers: [])
                Button("Add Holes") { NSApp.activeAppState?.currentTool = .addHoles }
                    .keyboardShortcut("s", modifiers: [])
                Button("Join/Cleanup") { NSApp.activeAppState?.currentTool = .cleanup }
                    .keyboardShortcut("j", modifiers: [])
                Button("Measure") { NSApp.activeAppState?.currentTool = .measure }
                    .keyboardShortcut("m", modifiers: [])
                
                Divider()
                
                Button("Line Sketch") { NSApp.activeAppState?.currentTool = .sketchLine }
                    .keyboardShortcut("l", modifiers: [])
                Button("Circle Sketch") { NSApp.activeAppState?.currentTool = .sketchCircle }
                    .keyboardShortcut("c", modifiers: [])
                Button("Rectangle Sketch") { NSApp.activeAppState?.currentTool = .sketchRectangle }
                    .keyboardShortcut("r", modifiers: [])
                Button("Text Sketch") { NSApp.activeAppState?.currentTool = .sketchText }
                    .keyboardShortcut("t", modifiers: [])
            }
            
            // Custom item to toggle logs
            CommandGroup(after: .sidebar) {
                Button(NSApp.activeAppState?.isLogTrayExpanded == true ? "Hide Logs" : "Show Logs") {
                    NSApp.activeAppState?.isLogTrayExpanded.toggle()
                }
            }
            
            // Custom Help menu
            CommandGroup(replacing: .help) {
                Button("Pathstitch Help & Documentation") {
                    openWindow(id: "help-window")
                }
            }
        }
        
        // Help Window Scene
        Window("Pathstitch Help & Documentation", id: "help-window") {
            HelpView()
        }
        .windowResizability(.contentSize)
    }
}
