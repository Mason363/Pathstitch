import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceCancellable: AnyCancellable?
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apply the saved appearance app-wide BEFORE any window is shown so the
        // Start screen, Settings, Help and document windows all open themed (MAS-72).
        // Calling this early also sets the correct Dock icon before the app finishes launching.
        ThemeManager.apply()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Track which document window is frontmost so menu-bar commands react to
        // the active document. SwiftUI `Commands` don't observe the computed
        // `NSApp.activeAppState`, so the Export menu's enabled state and
        // checkmarks went permanently stale (MAS-136). Register before windows
        // come up so the first document's becomeKey is captured.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            let window = note.object as? NSWindow
            ActiveDocument.shared.state = (window?.delegate as? DocumentWindowDelegate)?.state
        }

        WindowManager.shared.applicationDidFinishLaunching(notification)

        // Start Sparkle so scheduled update checks run and the second-launch
        // "check automatically?" prompt appears (MAS-142).
        _ = UpdaterManager.shared

        // Monitor system appearance to update dock icon dynamically
        appearanceCancellable = NSApp.publisher(for: \.effectiveAppearance)
            .sink { [weak self] _ in
                self?.updateAppIcon()
            }
        updateAppIcon()
    }
    
    private func updateAppIcon() {
        // Honors the user's icon preference; "auto" follows system appearance (MAS-72).
        AppIconManager.refresh()
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

    /// Prompt to save any unsaved documents before the app quits (⌘Q). Without
    /// this, quitting silently discarded changes since per-window
    /// `windowShouldClose` isn't consulted on termination.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return WindowManager.shared.applicationShouldTerminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Fast-kill the Python worker process so it doesn't delay app shutdown
        // (which causes the Dock icon to flash back to light while the process is lingering).
        let bridge = PythonBridge.shared
        Task {
            await bridge.shutdown()
        }
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

/// Observable mirror of the frontmost document's `AppState`, kept up to date by
/// the `didBecomeKeyNotification` observer in `AppDelegate`. Menu-bar commands
/// observe this instead of the non-reactive `NSApp.activeAppState` so their
/// enabled state and checkmarks update live (MAS-136).
@Observable
final class ActiveDocument {
    static let shared = ActiveDocument()
    var state: AppState?
    private init() {}
}

/// The File ▸ Export submenu, in its own observing `View` so the Export item's
/// enabled state, the selected-format checkmark, and the two toggle checkmarks
/// all reflect the active document live. Previously these read
/// `NSApp.activeAppState` directly inside `Commands`, which SwiftUI never
/// re-evaluates — leaving Export permanently greyed out and the checkmarks
/// stuck (MAS-136).
struct ExportMenu: View {
    @State private var activeDoc = ActiveDocument.shared

    var body: some View {
        // Read the observed values in the body so the Observation framework
        // tracks them and re-renders the menu when they change.
        let state = activeDoc.state
        let canExport = state?.currentFilePath != nil
        let format = state?.exportFormat ?? "dxf"
        let selectedOnly = state?.exportSelectedOnly ?? false
        let measurementLines = state?.exportMeasurementLines ?? false

        Menu("Export") {
            Button("Export...") {
                activeDoc.state?.exportWithDialog()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(!canExport)

            Divider()

            Picker("Export Format", selection: Binding(
                get: { format },
                set: { activeDoc.state?.exportFormat = $0 }
            )) {
                Text("AutoCAD DXF (.dxf)").tag("dxf")
                Text("Scalable Vector Graphics (.svg)").tag("svg")
                Text("Document PDF (.pdf)").tag("pdf")
                Text("Raster Image (.png)").tag("png")
            }

            Toggle("Export Selected Only", isOn: Binding(
                get: { selectedOnly },
                set: { activeDoc.state?.exportSelectedOnly = $0 }
            ))

            Toggle("Export Measurement Lines", isOn: Binding(
                get: { measurementLines },
                set: { activeDoc.state?.exportMeasurementLines = $0 }
            ))
        }
    }
}

@main
struct PathstitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            PreferencesView()
        }
        .commands {
            // Replace the standard about panel with our custom one (MAS-149 /
            // MAS-142): surfaces the support link, version and update controls.
            CommandGroup(replacing: .appInfo) {
                Button("About Pathstitch") {
                    WindowManager.shared.showAboutWindow()
                }
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdaterManager.shared.checkForUpdates()
                }
                Button("Start Screen") {
                    WindowManager.shared.showWelcomeWindow()
                }
            }
            
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
                
                Button("Import...") {
                    WindowManager.shared.importFileWithDialog()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                
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

                Divider()

                // Export (was the top-level "Export Settings" menu — MAS-68).
                // Lives in its own observing view so the enabled state and
                // checkmarks track the active document (MAS-136).
                ExportMenu()

                // Image (was the top-level "Reference Image" menu — MAS-68)
                Menu("Image") {
                    Button("Load Reference Image...") {
                        if let state = NSApp.activeAppState {
                            let openPanel = NSOpenPanel()
                            openPanel.allowedContentTypes = [.image]
                            openPanel.allowsMultipleSelection = false
                            openPanel.canChooseDirectories = false
                            openPanel.canChooseFiles = true
                            if openPanel.runModal() == .OK, let url = openPanel.url {
                                state.loadReferenceImage(from: url)
                            }
                        }
                    }

                    Button("Clear Reference Image") {
                        if let state = NSApp.activeAppState {
                            state.refImage = nil
                            state.refImageBase64 = nil
                        }
                    }
                    .disabled(NSApp.activeAppState?.refImage == nil)

                    Divider()

                    Toggle("Calibration Mode", isOn: Binding(
                        get: { NSApp.activeAppState?.isCalibrationActive ?? false },
                        set: { NSApp.activeAppState?.isCalibrationActive = $0 }
                    ))
                    .disabled(NSApp.activeAppState?.refImage == nil)

                    Button("Set Calibration Distance...") {
                        if let state = NSApp.activeAppState {
                            let alert = NSAlert()
                            alert.messageText = "Set Calibration Distance"
                            alert.informativeText = "Enter target distance in millimeters:"
                            alert.addButton(withTitle: "OK")
                            alert.addButton(withTitle: "Cancel")

                            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                            input.stringValue = String(format: "%.1f", state.calibrationDistance)
                            alert.accessoryView = input

                            if alert.runModal() == .alertFirstButtonReturn {
                                if let val = Double(input.stringValue) {
                                    state.calibrationDistance = val
                                }
                            }
                        }
                    }
                    .disabled(NSApp.activeAppState?.refImage == nil)

                    Divider()

                    Menu("Opacity") {
                        Button("10%") { NSApp.activeAppState?.refImageOpacity = 0.1 }
                        Button("25%") { NSApp.activeAppState?.refImageOpacity = 0.25 }
                        Button("50%") { NSApp.activeAppState?.refImageOpacity = 0.50 }
                        Button("75%") { NSApp.activeAppState?.refImageOpacity = 0.75 }
                        Button("100%") { NSApp.activeAppState?.refImageOpacity = 1.0 }
                    }
                    .disabled(NSApp.activeAppState?.refImage == nil)
                }
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
            
            // Selection / Tools menu. Keyboard shortcuts for these live in the
            // customizable keybind registry (MAS-72) and are captured by the
            // hidden hotkey buttons in ContentView, so the menu items here carry
            // no hardcoded shortcuts (single source of truth). Use ⌘K (Search)
            // or Preferences to discover/change them.
            CommandMenu("Tools") {
                Button("Search…") { NSApp.activeAppState?.showSearchPalette = true }
                    .keyboardShortcut("s", modifiers: [])
                Divider()
                Button("Select") { NSApp.activeAppState?.currentTool = .select }
                Button("Move") { NSApp.activeAppState?.currentTool = .move }
                Button("Scale") { NSApp.activeAppState?.currentTool = .scale }
                Button("Pan") { NSApp.activeAppState?.currentTool = .pan }
                Button("Offset") { NSApp.activeAppState?.currentTool = .offset }
                Button("Add Thickness") { NSApp.activeAppState?.currentTool = .addThickness }
                Button("Add Holes") { NSApp.activeAppState?.currentTool = .addHoles }
                Button("Join/Cleanup") { NSApp.activeAppState?.currentTool = .cleanup }
                Button("Measure") { NSApp.activeAppState?.currentTool = .measure }
                Button("Dimension") { NSApp.activeAppState?.currentTool = .dimension }
                Button("Mirror") { NSApp.activeAppState?.currentTool = .mirror }
                Button("Convert Lines") { NSApp.activeAppState?.currentTool = .convertLines }
                Button("Trim") { NSApp.activeAppState?.currentTool = .trim }
                Button("Paper Folding") { NSApp.activeAppState?.currentTool = .paperFolding }
                Button("Patterning") { NSApp.activeAppState?.currentTool = .patterning }

                Divider()

                Button("Line Sketch") { NSApp.activeAppState?.currentTool = .sketchLine }
                Button("Circle Sketch") { NSApp.activeAppState?.currentTool = .sketchCircle }
                Button("Rectangle Sketch") { NSApp.activeAppState?.currentTool = .sketchRectangle }
                Button("Polygon Sketch") { NSApp.activeAppState?.currentTool = .sketchPolygon }
                Button("Text Sketch") { NSApp.activeAppState?.currentTool = .sketchText }
                Button("Pen") { NSApp.activeAppState?.currentTool = .pen }
                Button("Fillet") { NSApp.activeAppState?.currentTool = .fillet }
                Button("Chamfer") { NSApp.activeAppState?.currentTool = .chamfer }
            }

            // Modify menu — geometric transforms on the current selection.
            // Shortcuts live in the keybind registry (edit.flipH / edit.flipV).
            CommandMenu("Modify") {
                Button("Flip Horizontal") {
                    NSApp.activeAppState?.reflectSelectedEntities(axis: "horizontal")
                }
                .disabled((NSApp.activeAppState?.selectedHandles.isEmpty ?? true))

                Button("Flip Vertical") {
                    NSApp.activeAppState?.reflectSelectedEntities(axis: "vertical")
                }
                .disabled((NSApp.activeAppState?.selectedHandles.isEmpty ?? true))
            }

            // Custom item to toggle logs & learn mode
            CommandGroup(after: .sidebar) {
                Button(NSApp.activeAppState?.isLogTrayExpanded == true ? "Hide Logs" : "Show Logs") {
                    NSApp.activeAppState?.isLogTrayExpanded.toggle()
                }
                
                Button(NSApp.activeAppState?.isLearnModeEnabled == true ? "Disable Learn Mode" : "Enable Learn Mode") {
                    NSApp.activeAppState?.isLearnModeEnabled.toggle()
                }
            }
            
            // Custom Help menu
            CommandGroup(replacing: .help) {
                Button("Documentation") {
                    WindowManager.shared.showDocumentationWindow()
                }
            }
        }
        // NOTE: the Documentation window is intentionally NOT a top-level `Window`
        // scene — those auto-open at launch and caused a ghost window. It's hosted
        // on demand in an AppKit window by WindowManager instead.
    }
}
