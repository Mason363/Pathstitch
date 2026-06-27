import SwiftUI
import UniformTypeIdentifiers
import Combine

struct ModeButton: View {
    let mode: AppMode
    let systemName: String
    let help: String
    var state: AppState
    @State private var isHovered = false
    
    var body: some View {
        Button(action: {
            // Batch is its own workspace/window (MAS-75): open a separate document
            // window rather than switching this one. 2D/3D stay in-place (they're
            // the same document).
            if mode == .batch {
                if state.activeMode != .batch {
                    WindowManager.shared.openBatchWorkspace()
                }
            } else {
                state.activeMode = mode
            }
        }) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            state.activeMode == mode ? 
            Color.bg_selected : 
            (isHovered ? Color.accent.opacity(0.08) : Color.clear)
        )
        .foregroundColor(
            state.activeMode == mode ? 
            Color.accent : 
            (isHovered ? Color.accent_hover : Color.text_secondary)
        )
        .help(help)
        .onHover { hover in
            isHovered = hover
        }
    }
}

/// An "⌐" corner whose elbow is rounded (fillet) or cut (chamfer) — a real,
/// unambiguous glyph for the Fillet/Chamfer tools (MAS-62).
struct CornerGlyph: Shape {
    var rounded: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let pad = rect.width * 0.2
        let k = rect.width * 0.42  // fillet radius / chamfer setback
        let x0 = rect.minX + pad, y0 = rect.minY + pad
        let x1 = rect.maxX - pad, y1 = rect.maxY - pad
        p.move(to: CGPoint(x: x0, y: y0))
        p.addLine(to: CGPoint(x: x0, y: y1 - k))
        if rounded {
            p.addArc(center: CGPoint(x: x0 + k, y: y1 - k), radius: k,
                     startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        } else {
            p.addLine(to: CGPoint(x: x0 + k, y: y1))
        }
        p.addLine(to: CGPoint(x: x1, y: y1))
        return p
    }
}

struct ToolButton: View {
    let tool: TwoDTool
    var state: AppState
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            state.currentTool = tool
            state.activeMeasureStart = nil
        }) {
            Group {
                if tool == .fillet || tool == .chamfer {
                    CornerGlyph(rounded: tool == .fillet)
                        .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: tool.icon)
                        .font(.system(size: 14))
                }
            }
                .frame(width: 24, height: 24)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            state.currentTool == tool ? 
            Color.bg_selected : 
            (isHovered ? Color.accent.opacity(0.08) : Color.clear)
        )
        .foregroundColor(
            state.currentTool == tool ? 
            Color.accent : 
            (isHovered ? Color.accent_hover : Color.text_secondary)
        )
        .help(tool.tooltip)
        .onHover { hover in
            isHovered = hover
        }
    }
}

struct ShapeToolButton: View {
    let tool: TwoDTool
    var state: AppState
    @State private var isHovered = false
    
    var body: some View {
        Button(action: {
            state.currentTool = tool
            state.activeMeasureStart = nil
        }) {
            Image(systemName: tool.icon)
                .font(.system(size: 12))
                .frame(width: 20, height: 20)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            state.currentTool == tool ? 
            Color.bg_selected : 
            (isHovered ? Color.accent.opacity(0.08) : Color.clear)
        )
        .foregroundColor(
            state.currentTool == tool ? 
            Color.accent : 
            (isHovered ? Color.accent_hover : Color.text_muted)
        )
        .help(tool.tooltip)
        .onHover { hover in
            isHovered = hover
        }
    }
}

/// One entry in the "more tools" overflow grid (MAS-66).
struct ExtraTool: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let enabled: Bool
    let action: () -> Void
}

/// Lays the extra tools out in the smallest near-square grid that fits them
/// (e.g. 12 tools → 4×3, not 1×12), as described in MAS-66.
struct MoreToolsGrid: View {
    let tools: [ExtraTool]

    private var cols: Int {
        let n = tools.count
        if n <= 1 { return 1 }
        var c = 1
        while c * c < n { c += 1 }   // smallest c with c*c >= n == ceil(sqrt(n))
        return c
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(60), spacing: 8), count: cols)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(tools) { tool in
                Button(action: tool.action) {
                    VStack(spacing: 4) {
                        Image(systemName: tool.icon).font(.system(size: 16))
                        Text(tool.title).font(.system(size: 9)).lineLimit(1)
                    }
                    .frame(width: 56, height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .background(Color.bg_input.opacity(0.4))
                .cornerRadius(6)
                .foregroundColor(tool.enabled ? Color.text_primary : Color.text_muted)
                .disabled(!tool.enabled)
            }
        }
    }
}

struct ToolbarHoverButton: View {
    let systemName: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(
            disabled ? 
            Color.text_muted : 
            (isHovered ? Color.accent_hover : Color.text_secondary)
        )
        .disabled(disabled)
        .help(help)
        .onHover { hover in
            isHovered = hover
        }
    }
}

struct ContentView: View {
    @State var state: AppState
    /// Live keybind registry — drives the hidden hotkey buttons (MAS-72).
    private let keybinds = KeybindStore.shared
    /// Persisted, user-rearrangeable toolbar layout (MAS-99).
    private let layout = ToolbarLayout.shared
    /// Focus on the fillet radius field; Esc clears it so single-key shortcuts
    /// work again (MAS-91).
    @FocusState private var isFilletFieldFocused: Bool
    @AppStorage(SettingsKeys.theme) private var themeRaw = AppTheme.dark.rawValue
    @State private var showExportDialog = false
    // Debounced processing flag: only becomes true if work runs longer than a
    // short delay, so fast worker ops (~ms) never flash a loading overlay.
    @State private var showSlowLoader = false
    @State private var isShapesHovered = false
    @State private var showShapes = false
    @State private var isMoreToolsHovered = false
    @State private var showMoreTools = false
    @State private var offsetMode = "curve" // "curve" or "bbox"
    @State private var customLayerName: String = ""
    @State private var selectedExistingLayer: String = ""
    @State private var rotationAngle: Double = 90.0
    @State private var leftSidebarTopHeight: CGFloat = 350
    // Resizable panel widths (MAS-131). Right inspector drag-resizes; left tool
    // sidebar widens in whole-column steps.
    @State private var rightPanelWidth: CGFloat = 240
    @State private var leftToolbarWidth: CGFloat = 48
    // Active-tool option panels are always fully expanded — no collapse chevron
    // or sub-menu feel (MAS-60). Their options render directly in the panel.
    @State private var isReferenceImageExpanded = false
    @State private var isLayersExpanded = false
    @State private var isImportSettingsExpanded = false
    @State private var isExportSettingsExpanded = false
    
    @State private var renamingItemId: String? = nil
    @State private var renamingText: String = ""
    
    @State private var gridCols: Int = 3
    @State private var gridRows: Int = 3
    @State private var gridColSpacing: Double = 20.0
    @State private var gridRowSpacing: Double = 20.0
    @State private var pathHandle: String = ""
    @State private var pathPatternSpacing: Double = 10.0
    
    @State private var textString: String = "Label"
    @State private var textHeight: Double = 5.0
    @State private var textInsertX: Double = 0.0
    @State private var textInsertY: Double = 0.0

    // Drives the first-run guided tutorial's spotlight + auto-advance; shared with
    // the left toolbar so it can scroll the current step's tool into view.
    @State private var tutorial = TutorialController()
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftToolbar
                
                if state.activeMode == .twoD {
                    twoDEditorView
                } else if state.activeMode == .batch {
                    BatchModeView(state: state)
                } else if state.activeMode == .construct {
                    ConstructModeView(state: state)
                } else {
                    threeDImporterView
                }
            }
            
            logAndStatusBarView
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color.bg_base)
        .background(WindowAccessor(state: state).frame(width: 0, height: 0).opacity(0))
        .font(PlasticityFont.body)
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .dark).colorScheme)
        // One-off Export Options panel (MAS-156).
        .sheet(isPresented: Binding(
            get: { state.showExportOptions },
            set: { state.showExportOptions = $0 }
        )) {
            ExportOptionsPanel(state: state)
        }
        // Bind hotkeys
        .background(hotkeyBindings)
        // Command search palette (MAS-53)
        .overlay {
            if state.showSearchPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { state.showSearchPalette = false }
                    SearchPalette(state: state)
                        .padding(.top, 96)
                }
            }
        }
        // PSD import choice dialog, centered (MAS-141).
        .overlay {
            if state.showPSDImportDialog, let psd = state.pendingPSDImport {
                PSDImportDialog(state: state, psd: psd)
            }
        }
        // First-run guided tutorial + per-mode intros (batch 4), bundled into one
        // modifier so the (already large) body stays type-checkable.
        .modifier(OnboardingModifier(state: state, tutorial: tutorial))
        // Only reveal the loading overlay if work outlasts a short delay, so the
        // now-fast worker ops never flash a loader (§7).
        .task(id: state.isProcessing) {
            if state.isProcessing {
                try? await Task.sleep(nanoseconds: 280_000_000)
                if !Task.isCancelled && state.isProcessing { showSlowLoader = true }
            } else {
                showSlowLoader = false
            }
        }
        .onChange(of: state.openDocsToken) { _ in WindowManager.shared.showDocumentationWindow() }
        .onChange(of: state.selectedHandles) { _ in
            state.updateLivePreview()
            // Keep the Holes Side picker in the right vocabulary (outer/inner vs
            // left/right) for whatever's now selected.
            if state.currentTool == .addHoles { state.normalizeHoleSideVocabulary() }
        }
        // Esc unfocuses the fillet radius field so keyboard shortcuts work (MAS-91).
        .onChange(of: state.escapePressedToken) { _ in isFilletFieldFocused = false }
        // Selecting a converted-line group loads its style/settings into the
        // editor so the panel reflects what's actually applied (MAS-58).
        .onChange(of: state.selectedConvertedGroupId) { gid in
            if let gid = gid, let g = state.convertedLineGroups[gid] {
                state.convertLineStyle = g.style
                state.convertLineSettings[g.style] = g.settings
            }
        }
        .onChange(of: state.currentTool) { _ in
            state.updateLivePreview()
            // Entering the Holes tool: make sure the Side picker shows the right
            // vocabulary (outer/inner vs left/right) for the current selection.
            if state.currentTool == .addHoles { state.normalizeHoleSideVocabulary() }
            // Entering a corner tool starts a confirm/cancel session and (with a
            // selection) applies it to all the shape's corners at once; leaving
            // confirms the session and clears the active target (MAS-62).
            if state.currentTool.isCornerTool {
                state.beginCornerToolSession()
                if !state.selectedHandles.isEmpty {
                    state.activateCornerToolForSelection()
                }
            } else {
                state.confirmCornerToolSession()
                state.filletSelectedHandle = nil
            }
        }
        .onChange(of: state.filletContinuity) { _ in state.refreshActiveCornerShape() }
        .onChange(of: state.offsetDistance) { _ in state.updateLivePreview() }
        .onChange(of: state.offsetSide) { _ in state.updateLivePreview() }
        .onChange(of: state.offsetConstruction) { _ in state.updateLivePreview() }
        .onChange(of: state.holeOffsetDistance) { _ in state.updateLivePreview() }
        .onChange(of: state.holeDiameter) { _ in state.updateLivePreview() }
        .onChange(of: state.holeSpacing) { _ in state.updateLivePreview() }
        .onChange(of: state.holeDistribution) { _ in state.updateLivePreview() }
        .onChange(of: state.holeCount) { _ in state.updateLivePreview() }
        .onChange(of: state.holePattern) { _ in state.updateLivePreview() }
        .onChange(of: state.holeCornerHoles) { _ in state.updateLivePreview() }
        .onChange(of: state.holeSide) { _ in state.updateLivePreview() }
        .onChange(of: state.holeRowSpacing) { _ in state.updateLivePreview() }
        .onChange(of: state.holeSaddleSpacing) { _ in state.updateLivePreview() }
        .onChange(of: state.chainSelectionEnabled) { _ in state.updateLivePreview() }
        .onChange(of: state.holeStartInset) { _ in state.updateLivePreview() }
        .onChange(of: state.holeEndInset) { _ in state.updateLivePreview() }
        .onChange(of: state.holeEndMode) { _ in state.updateLivePreview() }
        .onChange(of: state.holeOffsetCornerFillet) { _ in state.updateLivePreview() }
        .onChange(of: state.holeEnableVariableSpacing) { _ in
            // Entering Variable mode: target the band's lower bound so the spacing
            // matches what the slider shows.
            if state.holeEnableVariableSpacing { state.holeSpacing = state.holeVariableSpacingMin }
            state.updateLivePreview()
        }
        // In Variable Spacing mode the slider / Min field edit the band, but the
        // hole pipeline targets `holeSpacing` (the corner-hole path uses it
        // directly). Keep holeSpacing pinned to the band's lower bound so moving
        // the slider actually changes the spacing — otherwise it does nothing on
        // any part with corners.
        .onChange(of: state.holeVariableSpacingMin) { _ in
            if state.holeEnableVariableSpacing { state.holeSpacing = state.holeVariableSpacingMin }
            state.updateLivePreview()
        }
        .onChange(of: state.holeVariableSpacingMax) { _ in state.updateLivePreview() }
        .onChange(of: state.holeEnableProximityFilter) { _ in state.updateLivePreview() }
        .onChange(of: state.holeEnableCornerInterpolation) { _ in state.updateLivePreview() }

    }
    
    @ViewBuilder
    private var hotkeyBindings: some View {
        // All app-specific hotkeys are now data-driven from the user-customizable
        // keybind registry (MAS-72). Each command renders one hidden Button whose
        // shortcut is read live from the store, so rebinds in Preferences take
        // effect immediately.
        ZStack {
            ForEach(AppCommands.all) { command in
                let combo = keybinds.combo(for: command.id)
                if let key = combo.keyEquivalent, !combo.key.isEmpty {
                    Button("") { command.action(state) }
                        .keyboardShortcut(key, modifiers: combo.modifiers)
                }
            }
            // Universal cancel + forward-delete are fixed (not rebindable).
            Button("") { state.escapePressedToken += 1 }
                .keyboardShortcut(.escape, modifiers: [])
            Button("") {
                if state.selectedMeasurement != nil { state.deleteSelectedMeasurement() }
                else { state.deleteSelectedEntities() }
            }.keyboardShortcut(.deleteForward, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
    
    private func importFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [
            UTType(filenameExtension: "dxf"),
            UTType(filenameExtension: "step"),
            UTType(filenameExtension: "stp"),
            UTType(filenameExtension: "obj"),
            UTType(filenameExtension: "stl"),
            UTType(filenameExtension: "svg"),
            UTType(filenameExtension: "stch"),
            UTType(filenameExtension: "psd"),
            UTType.image
        ].compactMap { $0 }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                if url.pathExtension.lowercased() == "stch" {
                    state.loadProject(from: url)
                } else {
                    state.loadFile(url: url)
                }
            }
        }
    }
    
    private func importReferenceImage() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [UTType.image].compactMap { $0 }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                state.loadReferenceImage(from: url)
            }
        }
    }
    
    private func saveProject() {
        if let current = state.currentProjectPath {
            // Flush optimistic in-memory edits, then persist (MAS-21).
            state.reconcileThenSave(to: current)
        } else {
            state.saveProjectWithDialog()
        }
    }
    
    private func loadProject() {
        state.loadProjectWithDialog()
    }
}

struct WindowAccessor: NSViewRepresentable {
    var state: AppState
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.setup(window: window, state: state)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        weak var window: NSWindow?
        var state: AppState?
        private var flagsMonitor: Any?

        func setup(window: NSWindow, state: AppState) {
            self.window = window
            self.state = state
            installShiftMonitor()
        }

        /// Track the Shift key globally so holding it momentarily inverts snapping
        /// (MAS-157). A flagsChanged monitor fires on every modifier transition.
        private func installShiftMonitor() {
            guard flagsMonitor == nil else { return }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let held = event.modifierFlags.contains(.shift)
                if self?.state?.shiftSnapHeld != held {
                    self?.state?.shiftSnapHeld = held
                }
                return event
            }
        }

        deinit {
            if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        }
    }
}

// Helper document wrapper for Swift FileExporter
struct DXFExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.item] }
    var fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    init(configuration: ReadConfiguration) throws {
        // Read-only constructor (not strictly used for exporter)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url = fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try FileWrapper(url: url, options: .immediate)
    }
}

struct HoverableButtonLabel<Label: View>: View {
    let label: Label
    let isEnabled: Bool
    let isPressed: Bool
    @State private var isHovered = false
    
    var body: some View {
        label
            .font(PlasticityFont.body)
            .fontWeight(.medium)
            .foregroundColor(isEnabled ? Color.text_primary : Color.text_muted)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(isEnabled ? (isPressed ? Color.accent_hover : (isHovered ? Color.accent_hover : Color.accent)) : Color.bg_input)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isEnabled ? Color.clear : Color.border_strong, lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .onHover { hover in
                self.isHovered = hover
            }
    }
}

// Plasticity style buttons
struct PlasticityButtonStyle: ButtonStyle {
    var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        HoverableButtonLabel(label: configuration.label, isEnabled: isEnabled, isPressed: configuration.isPressed)
    }
}

// MARK: - PSD import dialog (MAS-141)
// Centered modal asking how to bring an imported .psd into the workspace.
struct PSDImportDialog: View {
    @Bindable var state: AppState
    let psd: PSDImportData

    private var rasterCount: Int { psd.rasterLayers.count }
    private var vectorCount: Int { psd.vectorLayers.count }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { state.cancelPSDImport() }

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundColor(Color.accent)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import Photoshop File")
                            .font(PlasticityFont.header)
                            .foregroundColor(Color.text_primary)
                        Text(layerSummary)
                            .font(.system(size: 11))
                            .foregroundColor(Color.text_secondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 14)

                Text("How would you like to import “\(psd.sourceURL.deletingPathExtension().lastPathComponent)”?")
                    .font(.system(size: 12))
                    .foregroundColor(Color.text_secondary)
                    .padding(.bottom, 12)

                VStack(spacing: 8) {
                    option(icon: "rectangle.stack",
                           title: "Load As Is",
                           subtitle: vectorCount > 0
                                ? "Keep each layer separate — raster layers as reference images, vector layers as editable paths."
                                : "Keep each layer separate as its own reference-image layer.",
                           action: { state.applyPSDImport(mode: .loadAsIs) })

                    option(icon: "photo",
                           title: "Load As One Image",
                           subtitle: "Flatten every layer into a single reference image.",
                           action: { state.applyPSDImport(mode: .loadAsOne) })

                    option(icon: "wand.and.stars",
                           title: "Auto-Convert to Vector",
                           subtitle: rasterCount > 0
                                ? "Load the layers, then vectorize all \(rasterCount) raster layer\(rasterCount == 1 ? "" : "s") with shared settings."
                                : "Load the vector layers (no raster layers to convert).",
                           action: { state.applyPSDImport(mode: .autoVectorize) })

                    option(icon: "square.on.square.dashed",
                           title: "Merge & Convert",
                           subtitle: "Flatten everything to one image, then vectorize it.",
                           action: { state.applyPSDImport(mode: .mergeAndConvert) })
                }

                Button(action: { state.cancelPSDImport() }) {
                    Text("Cancel")
                        .font(PlasticityFont.body)
                        .foregroundColor(Color.text_primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.bg_input)
                        .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 14)
            }
            .padding(22)
            .frame(width: 460)
            .background(Color.bg_panel)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.border_subtle, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.4), radius: 24, y: 8)
        }
    }

    private var layerSummary: String {
        var parts: [String] = []
        if rasterCount > 0 { parts.append("\(rasterCount) raster") }
        if vectorCount > 0 { parts.append("\(vectorCount) vector") }
        let detail = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        return "\(psd.totalLayerCount) layer\(psd.totalLayerCount == 1 ? "" : "s")\(detail)"
    }

    @ViewBuilder
    private func option(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        PSDImportOptionButton(icon: icon, title: title, subtitle: subtitle, action: action)
    }
}

private struct PSDImportOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(Color.accent)
                    .font(.system(size: 15))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(PlasticityFont.body)
                        .fontWeight(.semibold)
                        .foregroundColor(Color.text_primary)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color.text_secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Color.accent.opacity(0.12) : Color.bg_input)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(hovered ? Color.accent : Color.border_subtle, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovered = $0 }
    }
}

struct LinkButtonStyle: ButtonStyle {
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isHovered ? Color.accent_hover : Color.accent)
            .font(PlasticityFont.body)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .onHover { hover in
                self.isHovered = hover
            }
    }
}


// MARK: - Sidebar Panels Extension
extension ContentView {
    @ViewBuilder
    private var selectionSection: some View {
        if state.currentTool == .select {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "cursorarrow.and.square.on.square.dashed")
                        .foregroundColor(Color.accent)
                    Text("SELECTION DETAILS")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }
                .padding(.bottom, 4)
                
                VStack(alignment: .leading, spacing: 8) {
                    if state.selectedHandles.isEmpty {
                        Text("No selection")
                            .font(PlasticityFont.body)
                            .foregroundColor(Color.text_muted)
                            .padding(.vertical, 4)
                    } else {
                        HStack {
                            Text("\(state.selectedHandles.count) selected")
                                .font(PlasticityFont.body)
                                .foregroundColor(Color.text_primary)
                            Spacer()
                            Button("Deselect") {
                                state.selectedHandles.removeAll()
                            }
                            .buttonStyle(LinkButtonStyle())
                            .help("Deselect all selected entities on the canvas")
                        }
                        .padding(.vertical, 4)

                        // Boolean combine (MAS-144): surface Union/Subtract/
                        // Intersect without right-clicking, when 2+ watertight
                        // closed paths are selected.
                        if state.selectionCanBoolean {
                            VStack(alignment: .leading, spacing: 6) {
                                Divider().background(Color.border_subtle).padding(.vertical, 4)
                                Text("COMBINE")
                                    .font(PlasticityFont.label)
                                    .fontWeight(.bold)
                                    .foregroundColor(Color.accent)
                                HStack(spacing: 6) {
                                    Button("Union") { state.booleanCombineSelection("union") }
                                        .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                                        .help("Merge the selected closed paths into one")
                                    Button("Subtract") { state.booleanCombineSelection("subtract") }
                                        .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                                        .help("Cut the other selected paths out of the largest one")
                                    Button("Intersect") { state.booleanCombineSelection("intersect") }
                                        .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                                        .help("Keep only the overlapping region")
                                }
                            }
                            .padding(.bottom, 6)
                        }

                        if state.selectedHandles.count == 1,
                           let handle = state.selectedHandles.first,
                           let wMeasure = state.measurements.first(where: { $0.entityHandle == handle && $0.dimensionType == "width" }),
                           let hMeasure = state.measurements.first(where: { $0.entityHandle == handle && $0.dimensionType == "height" }) {
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Divider().background(Color.border_subtle).padding(.vertical, 4)
                                
                                Text("RECTANGLE DIMENSIONS")
                                    .font(PlasticityFont.label)
                                    .fontWeight(.bold)
                                    .foregroundColor(Color.accent)
                                
                                HStack {
                                    Text("Width (mm)")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_secondary)
                                    Spacer()
                                    TextField("Width", value: Binding<Double>(
                                        get: { wMeasure.distanceMm },
                                        set: { state.updateRectangleDimensions(handle: handle, width: $0, height: nil, filletRadius: nil) }
                                    ), format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 80)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                }
                                
                                HStack {
                                    Text("Height (mm)")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_secondary)
                                    Spacer()
                                    TextField("Height", value: Binding<Double>(
                                        get: { hMeasure.distanceMm },
                                        set: { state.updateRectangleDimensions(handle: handle, width: nil, height: $0, filletRadius: nil) }
                                    ), format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 80)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                }
                                
                                HStack {
                                    Text("Corner Fillet (mm)")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_secondary)
                                    Spacer()
                                    TextField("Fillet", value: Binding<Double>(
                                        get: { wMeasure.filletRadius },
                                        set: { state.updateRectangleDimensions(handle: handle, width: nil, height: nil, filletRadius: $0) }
                                    ), format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 80)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                }
                            }
                            .padding(.bottom, 6)
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ASSIGN TO LAYER")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            
                            Picker("", selection: $selectedExistingLayer) {
                                Text("Select existing layer...").tag("")
                                ForEach(state.layers) { layer in
                                    Text(layer.name).tag(layer.name)
                                }
                            }
                            .pickerStyle(DefaultPickerStyle())
                            .labelsHidden()
                            .help("Select an existing layer to assign selected entities to")
                            .onChange(of: selectedExistingLayer) { val in
                                if !val.isEmpty {
                                    customLayerName = val
                                }
                            }
                            
                            HStack {
                                TextField("New layer name", text: $customLayerName)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(6)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .font(PlasticityFont.body)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    .help("Enter a name to assign selected entities to a new layer")
                                
                                Button("Assign") {
                                    state.assignSelectedToLayer(customLayerName)
                                    customLayerName = ""
                                    selectedExistingLayer = ""
                                }
                                .buttonStyle(BorderedButtonStyle())
                                .disabled(customLayerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .help("Assign selected entities to the specified layer name")
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Divider().background(Color.border_subtle).padding(.vertical, 4)
                            
                            Text("ROTATE SELECTION")
                                .font(PlasticityFont.label)
                                .fontWeight(.bold)
                                .foregroundColor(Color.accent)
                            
                            HStack {
                                Text("Angle (degrees)")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_secondary)
                                Spacer()
                                TextField("Angle", value: $rotationAngle, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 80)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                            }
                            
                            HStack(spacing: 8) {
                                Button("Rotate") {
                                    if let center = state.selectionCenterModel {
                                        state.rotateSelected(angleDegrees: rotationAngle, center: [Double(center.x), Double(center.y)])
                                    }
                                }
                                .buttonStyle(BorderedButtonStyle())
                                .disabled(state.selectionCenterModel == nil)
                                .help("Rotate selected entities by the specified angle around their center")
                                
                                Button("+90°") {
                                    if let center = state.selectionCenterModel {
                                        state.rotateSelected(angleDegrees: 90.0, center: [Double(center.x), Double(center.y)])
                                    }
                                }
                                .buttonStyle(BorderedButtonStyle())
                                .disabled(state.selectionCenterModel == nil)
                                
                                Button("-90°") {
                                    if let center = state.selectionCenterModel {
                                        state.rotateSelected(angleDegrees: -90.0, center: [Double(center.x), Double(center.y)])
                                    }
                                }
                                .buttonStyle(BorderedButtonStyle())
                                .disabled(state.selectionCenterModel == nil)
                            }
                        }
                    }
                }
            }
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var dimensionEditorSection: some View {
        if state.currentTool == .select, let selected = state.selectedMeasurement {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("DIMENSION EDITOR")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_secondary)
                        .tracking(0.5)
                    Spacer()
                    Button("Clear") {
                        state.selectedMeasurement = nil
                    }
                    .buttonStyle(LinkButtonStyle())
                    .help("Deselect the current active measurement/dimension line")
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(selected.isAutoDimension ? "Auto-Dimension Line" : "Manual Measurement")
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_secondary)
                    
                    if let dimType = selected.dimensionType {
                        Text("Type: \(dimType.capitalized)")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_muted)
                    }
                    
                    HStack {
                        Text("Length (mm)")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        Spacer()
                    }
                    
                    let binding = Binding<Double>(
                        get: { selected.distanceMm },
                        set: { newValue in
                            if selected.isAutoDimension {
                                state.updateSelectedDimensionValue(newValue: newValue)
                            } else {
                                if let idx = state.measurements.firstIndex(where: { $0.id == selected.id }) {
                                    state.measurements[idx].distanceMm = newValue
                                    state.selectedMeasurement?.distanceMm = newValue
                                }
                            }
                        }
                    )
                    
                    TextField("Dimension", value: binding, format: .number)
                        .textFieldStyle(PlainTextFieldStyle())
                        .padding(6)
                        .background(Color.bg_input)
                        .cornerRadius(4)
                        .foregroundColor(Color.text_primary)
                        .font(PlasticityFont.body)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                        .disabled(!selected.isAutoDimension && selected.entityHandle == nil)
                        .help("Edit the dimension measurement value in millimeters")
                }
            }
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var activeToolDetailsSection: some View {
        if state.currentTool == .offset || state.currentTool == .addThickness || state.currentTool == .cleanup || state.currentTool == .measure || state.currentTool == .sketchLine || state.currentTool == .sketchCircle || state.currentTool == .sketchRectangle || state.currentTool == .sketchText {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ACTIVE TOOL DETAILS")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_secondary)
                        .tracking(0.5)
                }

                if state.currentTool == .addThickness {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Adds thickness to selected zero-width lines (or all lines if none selected), turning each centerline into a closed, cuttable outline. Lines that already have thickness are skipped.")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Thickness (mm)")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)

                        TextField("Thickness", value: $state.addThicknessWidth, format: .number)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding(6)
                            .background(Color.bg_input)
                            .cornerRadius(4)
                            .foregroundColor(Color.text_primary)
                            .font(PlasticityFont.body)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                            .help("Total width of the thickened outline in millimeters")
                            .onSubmit {
                                if state.addThicknessWidth > 0 { state.addThickness(exitAfterApply: true) }
                            }

                        HStack(spacing: 8) {
                            Button("OK") {
                                state.addThickness(exitAfterApply: true)
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: state.addThicknessWidth > 0))
                            .disabled(state.addThicknessWidth <= 0)
                            .help("Add thickness and exit the tool")

                            Button("Cancel") {
                                state.currentTool = .select
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                            .help("Drop the tool without changing geometry (Esc)")
                        }

                        Button("Apply (keep tool)") {
                            state.addThickness()
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: state.addThicknessWidth > 0))
                        .disabled(state.addThicknessWidth <= 0)
                        .help("Add thickness but stay in the tool")
                    }
                }

                if state.currentTool == .offset {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Offset Mode")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        
                        Picker("", selection: $offsetMode) {
                            Text("Curve").tag("curve")
                            Text("BBox").tag("bbox")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .help("Choose between parallel curve offset and bounding box (BBox) offset")
                        
                        if offsetMode == "curve" {
                            Text("Offset Distance (mm)")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            
                            TextField("Distance", value: $state.offsetDistance, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(6)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .font(PlasticityFont.body)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                .help("Offset distance in millimeters")
                                // Enter commits and exits the single-action Offset
                                // tool, returning to Select (MAS-111).
                                .onSubmit {
                                    if !state.selectedHandles.isEmpty { state.applyOffset(exitAfterApply: true) }
                                }
                            
                            Text("Side")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            
                            Picker("", selection: $state.offsetSide) {
                                Text("Outward").tag("outer")
                                Text("Inward").tag("inner")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .help("Offset outward (grow) or inward (shrink). Defaults to outward.")

                            // Flip the offset to the opposite side (MAS-109).
                            Button {
                                state.flipOffsetDirection()
                            } label: {
                                Label("Flip Direction", systemImage: "arrow.left.arrow.right")
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                            .help("Invert the positive/negative side of the offset")

                            Text("Geometry Type")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Picker("", selection: $state.offsetConstruction) {
                                Text("Normal").tag(false)
                                Text("Construction").tag(true)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .help("Normal — solid sketch lines. Construction — dashed reference lines.")

                            HStack(spacing: 8) {
                                Button("OK") {
                                    state.applyOffset(exitAfterApply: true)
                                }
                                .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                                .disabled(state.selectedHandles.isEmpty)
                                .help("Commit the offset and exit the tool")

                                Button("Cancel") {
                                    state.cancelOffsetTool()
                                }
                                .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                                .help("Drop the tool without generating geometry (Esc)")
                            }

                            Button("Apply (keep tool)") {
                                state.applyOffset()
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                            .disabled(state.selectedHandles.isEmpty)
                            .help("Commit the offset but stay in the tool to offset again")
                        } else {
                            Text("Offset Distance (mm)")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            
                            TextField("Distance", value: $state.bboxOffsetDistance, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(6)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .font(PlasticityFont.body)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                .help("Bounding box offset distance in millimeters")
                            
                            Text("Corner Fillet Radius (mm)")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            
                            TextField("Fillet Radius", value: $state.bboxOffsetFillet, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(6)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .font(PlasticityFont.body)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                .help("Radius for rounding bounding box corners in millimeters")
                            
                            Button("Apply BBox Offset") {
                                state.applyBBoxOffset()
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                            .help("Apply bounding box offset with rounded corners around selected path entities")
                        }
                    }
                } else if state.currentTool == .cleanup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cleanup Tolerance (mm)")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        
                        TextField("Tolerance", value: $state.cleanupTolerance, format: .number)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding(6)
                            .background(Color.bg_input)
                            .cornerRadius(4)
                            .foregroundColor(Color.text_primary)
                            .font(PlasticityFont.body)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                            .help("Endpoint distance tolerance gap in millimeters to join segments")
                        
                        Button("Apply Join/Cleanup") {
                            state.applyCleanup()
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: state.currentFilePath != nil))
                        .disabled(state.currentFilePath == nil)
                        .help("Join segment endpoints and clean up overlapping geometries")
                    }
                } else if state.currentTool == .measure {
                    VStack(alignment: .leading, spacing: 8) {
                        if state.measurements.isEmpty {
                            Text("No measurements taken")
                                .font(PlasticityFont.body)
                                .foregroundColor(Color.text_muted)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(state.measurements.filter { !$0.isAutoDimension }, id: \.id) { item in
                                HStack {
                                    Text("Dist:")
                                        .foregroundColor(Color.text_secondary)
                                    Text(String(format: "%.2f mm", item.distanceMm))
                                        .foregroundColor(Color.status_warn)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Button(action: {
                                        if let idx = state.measurements.firstIndex(where: { $0.id == item.id }) {
                                            if state.selectedMeasurement?.id == item.id {
                                                state.selectedMeasurement = nil
                                            }
                                            state.measurements.remove(at: idx)
                                        }
                                    }) {
                                        Image(systemName: "xmark.circle")
                                            .foregroundColor(Color.text_secondary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help("Delete this measurement line")
                                }
                                .font(PlasticityFont.body)
                                .padding(.vertical, 2)
                            }
                            
                            Button("Clear All") {
                                state.measurements.removeAll { !$0.isAutoDimension }
                                state.selectedMeasurement = nil
                                state.activeMeasureStart = nil
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                            .help("Clear all manual measurements from the canvas")
                        }
                    }
                } else if state.currentTool == .sketchLine {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LINE SKETCH TOOL")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.accent)
                        if state.isLearnModeEnabled {
                            Text("Drag to draw.")
                                .font(PlasticityFont.body)
                                .foregroundColor(Color.text_secondary)
                        }
                    }
                } else if state.currentTool == .sketchCircle {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CIRCLE SKETCH TOOL")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.accent)
                        if state.isLearnModeEnabled {
                            Text("Drag from the center outward.")
                                .font(PlasticityFont.body)
                                .foregroundColor(Color.text_secondary)
                        }
                    }
                } else if state.currentTool == .sketchRectangle {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RECTANGLE SKETCH TOOL")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.accent)
                        Text("Fillet Radius (mm)")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        
                        TextField("Fillet Radius", value: $state.sketchFilletRadius, format: .number)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding(6)
                            .background(Color.bg_input)
                            .cornerRadius(4)
                            .foregroundColor(Color.text_primary)
                            .font(PlasticityFont.body)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                            .help("Fillet radius in millimeters for rounding sketched rectangle corners")
                        
                        if state.isLearnModeEnabled {
                            Text("Drag corner-to-corner.")
                                .font(PlasticityFont.body)
                                .foregroundColor(Color.text_secondary)
                        }
                    }
                } else if state.currentTool == .sketchText {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TEXT SKETCH TOOL")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.accent)
                        if state.isLearnModeEnabled {
                            Text("Drag a box, then type.")
                                .font(PlasticityFont.body)
                                .foregroundColor(Color.text_secondary)
                        }
                    }
                }
            }
            .padding(8)
            .background(Color.bg_input.opacity(0.2))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    /// A small preview of one iron's slit shape, drawn in the chip / picker.
    @ViewBuilder
    private func ironSlitGlyph(shape: String) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let cx = w / 2, cy = h / 2
            Path { p in
                switch shape {
                case "diamond":
                    p.move(to: CGPoint(x: cx, y: cy - h * 0.32))
                    p.addLine(to: CGPoint(x: cx + w * 0.16, y: cy))
                    p.addLine(to: CGPoint(x: cx, y: cy + h * 0.32))
                    p.addLine(to: CGPoint(x: cx - w * 0.16, y: cy))
                    p.closeSubpath()
                case "flat":
                    p.addRect(CGRect(x: cx - w * 0.10, y: cy - h * 0.32,
                                     width: w * 0.20, height: h * 0.64))
                case "french", "oval":
                    p.addEllipse(in: CGRect(x: cx - w * 0.12, y: cy - h * 0.32,
                                            width: w * 0.24, height: h * 0.64))
                default: // round
                    p.addEllipse(in: CGRect(x: cx - w * 0.16, y: cy - h * 0.16,
                                            width: w * 0.32, height: h * 0.32))
                }
            }
            .fill(Color.accent)
        }
    }

    /// Horizontal gallery of pricking irons + the live slit shape controls.
    private var prickingIronPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PRICKING IRON")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)
                .tracking(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PrickingIronStore.shared.all) { iron in
                        let selected = state.prickingIronId == iron.id
                        VStack(spacing: 3) {
                            ironSlitGlyph(shape: iron.shape)
                                .frame(width: 34, height: 30)
                            Text(iron.name)
                                .font(.system(size: 8))
                                .lineLimit(1)
                                .foregroundColor(Color.text_secondary)
                                .frame(width: 52)
                        }
                        .padding(4)
                        .background(selected ? Color.accent.opacity(0.18) : Color.bg_input)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(selected ? Color.accent : Color.border_strong, lineWidth: 1))
                        .onTapGesture { state.applyPrickingIron(iron) }
                        .help("\(iron.name) — \(iron.shape), pitch \(String(format: "%.2f", iron.pitch)) mm")
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Text("Shape")
                    .font(PlasticityFont.label)
                    .foregroundColor(Color.text_primary)
                Spacer()
                Picker("", selection: $state.holeShape) {
                    Text("Round").tag("round")
                    Text("Diamond").tag("diamond")
                    Text("French").tag("french")
                    Text("Flat").tag("flat")
                    Text("Oval").tag("oval")
                }
                .labelsHidden()
                .frame(width: 150)
                .help("Slit cross-section punched at each stitch")
            }

            if state.holeShape != "round" {
                HStack {
                    Text("Slit L×W (mm)")
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_primary)
                    Spacer()
                    TextField("L", value: $state.holeSlitLength, format: .number)
                        .textFieldStyle(PlainTextFieldStyle()).padding(4).frame(width: 48)
                        .background(Color.bg_input).cornerRadius(4)
                        .foregroundColor(Color.text_primary)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                    TextField("W", value: $state.holeSlitWidth, format: .number)
                        .textFieldStyle(PlainTextFieldStyle()).padding(4).frame(width: 48)
                        .background(Color.bg_input).cornerRadius(4)
                        .foregroundColor(Color.text_primary)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                }
                HStack {
                    Text("Angle / Invert")
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_primary)
                    Spacer()
                    TextField("°", value: $state.holeSlitAngle, format: .number)
                        .textFieldStyle(PlainTextFieldStyle()).padding(4).frame(width: 48)
                        .background(Color.bg_input).cornerRadius(4)
                        .foregroundColor(Color.text_primary)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                    Toggle("", isOn: $state.holeInverted)
                        .labelsHidden()
                        .help("Mirror the slant (left vs right iron)")
                }
            }

            Toggle("Snap to whole chisel steps", isOn: $state.snapToChisel)
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_primary)
                .help("Round each path's hole count to a whole multiple of the selected iron's prong count (\(state.selectedIronBladeCount)), so a multi-prong chisel lands cleanly with uniform pitch end to end. Off keeps the plain fixed-pitch fill.")

            Toggle("Preview seam (Stitching Simulator)", isOn: $state.showStitchSimulation)
                .font(PlasticityFont.label)
                .help("Thread the holes to preview the finished seam — overlay only, never alters geometry")

            Divider().padding(.vertical, 2)
        }
        .onChange(of: state.holeShape) { _ in state.updateLivePreview() }
        .onChange(of: state.holeSlitLength) { _ in state.updateLivePreview() }
        .onChange(of: state.holeSlitWidth) { _ in state.updateLivePreview() }
        .onChange(of: state.holeSlitAngle) { _ in state.updateLivePreview() }
        .onChange(of: state.holeInverted) { _ in state.updateLivePreview() }
        .onChange(of: state.snapToChisel) { _ in state.updateLivePreview() }
    }

    /// Single-line (chain-off) endpoint controls for the sewing tool: how the run is
    /// anchored between the tips (end-placement mode) and how far the first / last
    /// holes sit in from each tip (margin, in mm or × pitch, linked or per-end).
    @ViewBuilder
    private var holeSingleLineControls: some View {
        // Canonical insets stay in mm; these bindings convert for the active unit.
        let startMargin = Binding<Double>(
            get: { state.holeInsetToDisplay(state.holeStartInset) },
            set: { state.holeStartInset = state.holeInsetFromDisplay($0) })
        let endMargin = Binding<Double>(
            get: { state.holeInsetToDisplay(state.holeEndInset) },
            set: { state.holeEndInset = state.holeInsetFromDisplay($0) })
        // Linked: one field writes BOTH ends.
        let bothMargin = Binding<Double>(
            get: { state.holeInsetToDisplay(state.holeStartInset) },
            set: {
                let mm = state.holeInsetFromDisplay($0)
                state.holeStartInset = mm
                state.holeEndInset = mm
            })

        HStack {
            Text("End placement")
                .font(PlasticityFont.label).foregroundColor(Color.text_primary)
            Spacer()
            Picker("", selection: $state.holeEndMode) {
                Text("Spread").tag("ends")
                Text("From start").tag("fill")
                Text("Centered").tag("even")
            }
            .pickerStyle(SegmentedPickerStyle())
            .frame(width: 200)
            .help("How holes are anchored between the line's two ends. Spread: evenly distributed with a hole on each tip (spacing flexes to fit). From start: exact spacing from the start tip, the leftover gap falls at the far end. Centered: exact spacing with equal margins at both ends.")
        }

        HStack {
            Text("Margin unit")
                .font(PlasticityFont.label).foregroundColor(Color.text_primary)
            Spacer()
            Picker("", selection: $state.holeInsetUnit) {
                Text("mm").tag("mm")
                Text("× pitch").tag("pitch")
            }
            .pickerStyle(SegmentedPickerStyle())
            .frame(width: 120)
            .help("Type the margins in millimetres, or as a multiple of the stitch spacing (e.g. 0.5× = half a stitch).")
        }

        if state.holeInsetLinked {
            HStack {
                Text("Margin (\(state.holeInsetUnitLabel))")
                    .font(PlasticityFont.label).foregroundColor(Color.text_primary)
                Spacer()
                TextField("Margin", value: bothMargin, format: .number)
                    .frame(width: 60).textFieldStyle(.roundedBorder)
            }
            .help("How far the first AND last holes sit in from each tip of the line.")
            Toggle("Set ends separately", isOn: Binding(
                get: { !state.holeInsetLinked },
                set: { state.holeInsetLinked = !$0 }))
                .toggleStyle(.checkbox)
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)
        } else {
            HStack {
                Text("Start (\(state.holeInsetUnitLabel))")
                    .font(PlasticityFont.label).foregroundColor(Color.text_primary)
                Spacer()
                TextField("Start", value: startMargin, format: .number)
                    .frame(width: 60).textFieldStyle(.roundedBorder)
            }
            .help("How far the FIRST hole sits in from the line's start point.")
            HStack {
                Text("End (\(state.holeInsetUnitLabel))")
                    .font(PlasticityFont.label).foregroundColor(Color.text_primary)
                Spacer()
                TextField("End", value: endMargin, format: .number)
                    .frame(width: 60).textFieldStyle(.roundedBorder)
            }
            .help("How far the LAST hole sits in from the line's end point.")
            Toggle("Link both ends", isOn: $state.holeInsetLinked)
                .toggleStyle(.checkbox)
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)
        }
    }

    @ViewBuilder
    private var holesSewingSection: some View {
        if state.currentTool == .select || state.currentTool == .addHoles {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "circle.dashed")
                        .foregroundColor(Color.accent)
                    Text("HOLES SEWING")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }

                prickingIronPicker

                VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Offset Distance (mm)")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_primary)
                            Spacer()
                            TextField("Offset", value: $state.holeOffsetDistance, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 80)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                .help("Distance from boundary path to place sewing holes in millimeters")
                        }
                        
                        HStack {
                            Text("Hole Diameter (mm)")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_primary)
                            Spacer()
                            TextField("Diameter", value: $state.holeDiameter, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 80)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                .help("Diameter of each sewing hole in millimeters")
                        }
                        
                        HStack {
                            Text("Distribution")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_primary)
                            Spacer()
                            Picker("", selection: $state.holeDistribution) {
                                Text("Fill").tag("spacing")
                                Text("Count").tag("count")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 120)
                            .help("Fill the path at a fixed spacing, or place an exact number of evenly-spaced holes")
                        }

                        if state.holeDistribution == "count" {
                            HStack {
                                Text("Hole Count")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_primary)
                                Spacer()
                                TextField("Count", value: $state.holeCount, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 80)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    .help("Exact number of evenly-spaced holes per contour")
                            }
                        } else {
                            // Spacing control. A 1–20 mm slider is the primary
                            // control. With Variable Spacing off it drives the single
                            // hole spacing; with it on it slides BOTH the min and max
                            // together, keeping their gap fixed. The numeric fields
                            // edit the same values and the slider tracks them. The box
                            // below the slider shows / edits the slider's value.
                            let spacingSlider = Binding<Double>(
                                get: {
                                    state.holeEnableVariableSpacing
                                        ? state.holeVariableSpacingMin
                                        : state.holeSpacing
                                },
                                set: { raw in
                                    let v = min(20.0, max(1.0, raw))
                                    if state.holeEnableVariableSpacing {
                                        let gap = max(0.0, state.holeVariableSpacingMax - state.holeVariableSpacingMin)
                                        state.holeVariableSpacingMin = v
                                        state.holeVariableSpacingMax = v + gap
                                    } else {
                                        state.holeSpacing = v
                                    }
                                }
                            )
                            if !state.holeEnableVariableSpacing {
                                HStack {
                                    Text("Hole Spacing (mm)")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_primary)
                                    Spacer()
                                    TextField("Spacing", value: $state.holeSpacing, format: .number)
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .padding(4)
                                        .frame(width: 80)
                                        .background(Color.bg_input)
                                        .cornerRadius(4)
                                        .foregroundColor(Color.text_primary)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                        .help("Distance between consecutive sewing holes in millimeters")
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text("1")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_muted)
                                    Slider(value: spacingSlider, in: 1...20)
                                    Text("20")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_muted)
                                }
                                HStack {
                                    Spacer()
                                    TextField("", value: spacingSlider, format: .number)
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .multilineTextAlignment(.center)
                                        .padding(4)
                                        .frame(width: 64)
                                        .background(Color.bg_input)
                                        .cornerRadius(4)
                                        .foregroundColor(Color.text_primary)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    Text("mm")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_secondary)
                                    Spacer()
                                }
                            }
                            .help(state.holeEnableVariableSpacing
                                  ? "Spacing slider (1–20 mm). Slides the min and max together, keeping their gap. Edit Min / Max below for fine control."
                                  : "Spacing slider (1–20 mm). Sets the distance between holes; the field above edits the same value.")
                        }

                        HStack {
                            Text("Pattern Style")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_primary)
                            Spacer()
                            Picker("", selection: $state.holePattern) {
                                Text("Single").tag("single")
                                Text("Saddle").tag("saddle")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 120)
                            .help("Choose between a single row or double-row saddle stitch hole pattern")
                        }
                        
                        Toggle("Hole at Corners", isOn: $state.holeCornerHoles)
                            .toggleStyle(.checkbox)
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_primary)
                            .help("Place a stitch on — or as near as possible to — every corner sharper than ~45°, flexing the spacing between holes so one lands on each corner. On by default.")

                        if !state.chainSelectionEnabled {
                            holeSingleLineControls
                        }

                        HStack {
                            Text("Offset Corners")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_primary)
                            Spacer()
                            Picker("", selection: $state.holeOffsetCornerFillet) {
                                Text("Sharp").tag(false)
                                Text("Rounded").tag(true)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 140)
                            .help("Corner treatment of the offset stitch line: Sharp keeps crisp corners (default); Rounded fillets them so holes follow a smooth arc.")
                        }

                        HStack {
                            Text("Side")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_primary)
                            Spacer()
                            Picker("", selection: $state.holeSide) {
                                if state.holeHandleIsRadial {
                                    // Circles / arcs / curves: outer/inner is
                                    // unambiguous; left/right is not (and disagreed
                                    // with the dashed preview).
                                    Text("Outer").tag("outer")
                                    Text("Inner").tag("inner")
                                    Text("Both").tag("both")
                                } else {
                                    Text("Left").tag("left")
                                    Text("Right").tag("right")
                                    Text("Both").tag("both")
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 180)
                            .help("Choose the side(s) of the path to distribute holes. Closed curves use outer / inner; open paths use left / right.")
                        }

                        if state.holePattern == "saddle" {
                            HStack {
                                Text("Saddle Row Distance (mm)")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_primary)
                                Spacer()
                                TextField("Distance", value: $state.holeSaddleSpacing, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 80)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    .help("Distance in millimeters between the two staggered rows of a saddle stitch")
                            }
                        }

                        Toggle("Variable Spacing", isOn: $state.holeEnableVariableSpacing)
                            .toggleStyle(.checkbox)
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_primary)
                            .help("Enable variable spacing to fit holes perfectly along segment lengths")
                        
                        if state.holeEnableVariableSpacing {
                            HStack {
                                Text("  Min / Max (mm)")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_primary)
                                Spacer()
                                TextField("Min", value: $state.holeVariableSpacingMin, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 45)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    .help("Minimum spacing allowed between holes in millimeters")
                                Text("/")
                                TextField("Max", value: $state.holeVariableSpacingMax, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 45)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    .help("Maximum spacing allowed between holes in millimeters")
                            }
                            .padding(.leading, 8)
                        }
                        
                        Toggle("Proximity Filter", isOn: $state.holeEnableProximityFilter)
                            .toggleStyle(.checkbox)
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_primary)
                            .help("Filter out generated holes that are too close to other canvas paths")
                        
                        if state.holeEnableProximityFilter {
                            HStack {
                                Text("  Distance (mm)")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_primary)
                                Spacer()
                                TextField("Distance", value: $state.holeProximityDistance, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 60)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    .help("Proximity detection threshold radius in millimeters")
                            }
                            .padding(.leading, 8)
                        }
                        
                        Toggle("Line Proximity Filter", isOn: $state.holeEnableLineProximityFilter)
                            .toggleStyle(.checkbox)
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_primary)
                            .help("Filter out holes close to the ends of lines")
                        
                        if state.holeEnableLineProximityFilter {
                            HStack {
                                Text("  Threshold (mm)")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_primary)
                                Spacer()
                                TextField("Threshold", value: $state.holeLineProximityThreshold, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 60)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    .help("Line end proximity threshold distance in millimeters")
                            }
                            .padding(.leading, 8)
                        }
                        
                        Divider().background(Color.border_subtle)

                        // Proximity Avoidance / Keep-Out (MAS-120 Phase 1).
                        Text("KEEP-OUT AVOIDANCE")
                            .font(PlasticityFont.label).fontWeight(.bold).foregroundColor(Color.accent)
                        Toggle("Avoid Keep-Out Zones", isOn: $state.holeEnableAvoidance)
                            .toggleStyle(.checkbox)
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_primary)
                            .help("Suppress stitch holes within the clearance radius of tagged hardware/keep-out geometry")
                        if state.holeEnableAvoidance {
                            HStack {
                                Text("  Clearance (mm)")
                                    .font(PlasticityFont.label).foregroundColor(Color.text_primary)
                                Spacer()
                                TextField("Clearance", value: $state.holeAvoidanceRadius, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4).frame(width: 60)
                                    .background(Color.bg_input).cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                            }
                            .padding(.leading, 8)
                            HStack {
                                Text("  Tagged: \(state.sewingKeepoutHandles.count)")
                                    .font(PlasticityFont.label).foregroundColor(Color.text_secondary)
                                Spacer()
                                Button("Tag Selected") {
                                    state.sewingKeepoutHandles.formUnion(state.selectedHandles)
                                }
                                .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                                .disabled(state.selectedHandles.isEmpty)
                                .help("Mark the selected geometry as keep-out elements")
                                if !state.sewingKeepoutHandles.isEmpty {
                                    Button("Clear") { state.sewingKeepoutHandles.removeAll() }
                                        .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                                }
                            }
                            .padding(.leading, 8)
                        }

                        // NOTE: the "Apply Sewing Holes" action is rendered as a
                        // pinned footer (holesApplyFooter) below the scrolling
                        // panel so it stays reachable no matter how many advanced
                        // options are expanded — see the inspector VSplitView.
                    }
                    .padding(.vertical, 4)
            }
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    /// Primary Sewing-Holes action, pinned beneath the (scrolling) options panel
    /// so it's always visible regardless of how tall the parameter list grows.
    @ViewBuilder
    private var holesApplyFooter: some View {
        VStack(spacing: 0) {
            Divider().background(Color.border_subtle)
            Button("Apply Sewing Holes") {
                state.applySewingHoles()
            }
            .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
            .disabled(state.selectedHandles.isEmpty)
            .help("Generate sewing holes along selected paths using these parameters")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .background(Color.bg_panel)
    }

    /// Binds the radius field to the active corner's value, applying live so the
    /// preview updates as you type (MAS-91). Reads back the active corner so the
    /// field always shows what you're editing.
    private var filletFieldValue: Binding<Double> {
        Binding(
            get: {
                if let h = state.filletSelectedHandle, let idx = state.activeCornerIndex,
                   let c = state.parametricShapes[h]?.corners.first(where: { $0.index == idx }) {
                    return c.value
                }
                return state.filletToolRadius
            },
            set: { newVal in
                state.filletToolRadius = newVal
                state.setActiveCornerValue(newVal)
            }
        )
    }

    @ViewBuilder
    private var filletSection: some View {
        let isChamfer = state.currentTool == .chamfer
        let activeCorners = state.filletSelectedHandle.flatMap { state.parametricShapes[$0]?.corners.count } ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CornerGlyph(rounded: !isChamfer)
                    .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .foregroundColor(Color.accent)
                    .frame(width: 14, height: 14)
                Text(isChamfer ? "CHAMFER" : "FILLET")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary)
                    .tracking(0.5)
            }

            if !isChamfer {
                Text("Continuity")
                    .font(PlasticityFont.label)
                    .foregroundColor(Color.text_secondary)
                Picker("", selection: $state.filletContinuity) {
                    Text("G1").tag("G1")
                    Text("G2").tag("G2")
                }
                .pickerStyle(SegmentedPickerStyle())
                .help("G1 — true circular arc. G2 — curvature-continuous blend (smoother).")
            }

            Text(isChamfer ? "Setback (mm) — active corner" : "Radius (mm) — active corner")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)
            // Edits ONLY the active (last-selected) corner — fillets are individual
            // (MAS-91). Esc unfocuses so single-key shortcuts work again.
            TextField("Value", value: filletFieldValue, format: .number)
                .textFieldStyle(PlainTextFieldStyle())
                .focused($isFilletFieldFocused)
                .padding(6)
                .background(Color.bg_input)
                .cornerRadius(4)
                .foregroundColor(Color.text_primary)
                .font(PlasticityFont.body)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                .onSubmit { state.setActiveCornerValue(state.filletToolRadius) }

            Text(activeCorners == 0
                 ? "Select a shape (or click its corners) to \(isChamfer ? "chamfer" : "fillet")."
                 : "\(activeCorners) corner\(activeCorners == 1 ? "" : "s") selected — they share this radius. Drag the corner arrow or edit the value.")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_muted)

            if let notice = state.cornerLimitNotice {
                Text(notice)
                    .font(PlasticityFont.label)
                    .foregroundColor(Color.status_err)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var paperFoldingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "scissors")
                    .foregroundColor(Color.accent)
                Text("PAPER FOLDING")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary)
                    .tracking(0.5)
                Spacer()
            }

            if true {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CREASE PATTERN")
                                .font(PlasticityFont.label)
                                .fontWeight(.bold)
                                .foregroundColor(Color.accent)
                            Text("Turns selected segments into dashed crease folds.")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Button("Apply Dashed Creases") {
                                state.applyDashedCreases()
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                            .disabled(state.selectedHandles.isEmpty)
                            .help("Convert selected segments into dashed crease folds for paper/leather modeling")
                        }
                        
                        Divider().background(Color.border_subtle)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("GLUE TABS")
                                .font(PlasticityFont.label)
                                .fontWeight(.bold)
                                .foregroundColor(Color.accent)
                            
                            HStack {
                                Text("Tab Height (mm)")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_secondary)
                                Spacer()
                                TextField("Height", value: $state.glueTabHeight, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 80)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    .help("Height of the generated glue tabs in millimeters")
                            }
                            
                            HStack {
                                Text("Tab Type")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_secondary)
                                Spacer()
                                Picker("", selection: $state.glueTabType) {
                                    Text("Trapezoid").tag("trapezoid")
                                    Text("Triangle").tag("triangle")
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .frame(width: 140)
                                .help("Choose the shape of the generated glue tabs: trapezoidal or triangular")
                            }
                            
                            HStack {
                                Text("Side")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_secondary)
                                Spacer()
                                Picker("", selection: $state.glueTabSide) {
                                    Text("Left").tag("left")
                                    Text("Right").tag("right")
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .frame(width: 140)
                                .help("Select the side of the path to place the glue tabs (left or right)")
                            }

                            HStack {
                                Text("Start Offset (mm)")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_secondary)
                                Spacer()
                                TextField("Start Offset", value: $state.glueTabStartOffset, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 80)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    .help("Offset distance from the starting point of the segment in millimeters")
                            }

                            HStack {
                                Text("End Offset (mm)")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_secondary)
                                Spacer()
                                TextField("End Offset", value: $state.glueTabEndOffset, format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .frame(width: 80)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .foregroundColor(Color.text_primary)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    .help("Offset distance from the ending point of the segment in millimeters")
                            }
                            
                            Button("Apply Glue Tabs") {
                                state.applyGlueTabs()
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                            .disabled(state.selectedHandles.isEmpty)
                            .help("Generate glue tabs along selected paths using these parameters")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
    }

    @ViewBuilder
    private var patterningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "square.grid.3x3")
                    .foregroundColor(Color.accent)
                Text("PATTERNING")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary)
                    .tracking(0.5)
                Spacer()
            }

            if true {
                VStack(alignment: .leading, spacing: 10) {
                    if state.selectedHandles.isEmpty {
                        Text("Select geometry to pattern.")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                    }
                    Picker("", selection: $state.patternMode) {
                        Text("Rect").tag("rectangular")
                        Text("Circular").tag("circular")
                        Text("Path").tag("path")
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    if state.patternMode == "rectangular" {
                        Text("Drag the on-canvas arrows, or set values:")
                            .font(PlasticityFont.label).foregroundColor(Color.text_muted)

                        // Number of copies (per axis), with steppers (MAS-157).
                        HStack {
                            Text("Copies X / Y").font(PlasticityFont.label).foregroundColor(Color.text_secondary)
                            Spacer()
                            patternStepperField(Binding(get: { Double(state.patternCountX) }, set: { state.patternCountX = max(1, Int($0)) }), step: 1, minValue: 1, isInt: true)
                            Text("×")
                            patternStepperField(Binding(get: { Double(state.patternCountY) }, set: { state.patternCountY = max(1, Int($0)) }), step: 1, minValue: 1, isInt: true)
                        }

                        // Choose how the distance between copies is specified.
                        Picker("", selection: $state.patternDistanceMode) {
                            Text("Spacing").tag("spacing")
                            Text("Extent").tag("extent")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .help("Spacing — gap between adjacent copies. Extent — total distance from the first to the last copy.")

                        if state.patternDistanceMode == "spacing" {
                            HStack {
                                Text("Spacing X / Y").font(PlasticityFont.label).foregroundColor(Color.text_secondary)
                                Spacer()
                                patternStepperField($state.patternSpacingX, step: 1)
                                Text("/")
                                patternStepperField($state.patternSpacingY, step: 1)
                            }
                        } else {
                            HStack {
                                Text("Extent X / Y").font(PlasticityFont.label).foregroundColor(Color.text_secondary)
                                Spacer()
                                patternStepperField($state.patternExtentX, step: 1)
                                Text("/")
                                patternStepperField($state.patternExtentY, step: 1)
                            }
                            Text("≈ \(state.effectivePatternSpacingX, specifier: "%.1f") / \(state.effectivePatternSpacingY, specifier: "%.1f") mm between copies")
                                .font(PlasticityFont.label).foregroundColor(Color.text_muted)
                        }

                        Button("Apply Pattern") {
                            state.applyPatternGrid(columns: state.patternCountX, rows: state.patternCountY,
                                                   colSpacing: state.effectivePatternSpacingX, rowSpacing: state.effectivePatternSpacingY)
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                        .disabled(state.selectedHandles.isEmpty)
                    } else if state.patternMode == "circular" {
                        HStack {
                            Text("Copies").font(PlasticityFont.label).foregroundColor(Color.text_secondary)
                            Spacer()
                            patternStepperField(Binding(get: { Double(state.patternCircCount) }, set: { state.patternCircCount = max(2, Int($0)) }), step: 1, minValue: 2, isInt: true)
                        }
                        HStack {
                            Text("Total Angle (°)").font(PlasticityFont.label).foregroundColor(Color.text_secondary)
                            Spacer()
                            patternStepperField($state.patternCircAngle, step: 5)
                        }
                        Button {
                            state.pickingPatternPivot = true
                        } label: {
                            Label(state.patternPivotModel == nil ? "Pick Center…" : "Re-pick Center…", systemImage: "scope")
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                        if state.pickingPatternPivot {
                            Text("Click a center point on the canvas…")
                                .font(PlasticityFont.label).foregroundColor(Color.accent)
                        }
                        Button("Apply Pattern") {
                            state.applyPatternCircular(count: state.patternCircCount, angle: state.patternCircAngle)
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                        .disabled(state.selectedHandles.isEmpty)
                    } else if state.patternMode == "path" {
                        HStack {
                            Text("Spacing (mm)").font(PlasticityFont.label).foregroundColor(Color.text_secondary)
                            Spacer()
                            patternStepperField($state.patternPathSpacing, step: 1)
                        }
                        Button {
                            state.pickingPatternPath = true
                            state.pickingPatternPivot = false
                        } label: {
                            Label(state.patternPathHandle == nil ? "Pick Path…" : "Re-pick Path…", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                        if state.pickingPatternPath {
                            Text("Click a guide path on the canvas…")
                                .font(PlasticityFont.label).foregroundColor(Color.accent)
                        } else if let handle = state.patternPathHandle {
                            Text("Picked Path: \(handle)")
                                .font(PlasticityFont.label).foregroundColor(Color.text_muted)
                        }
                        Button("Apply Pattern") {
                            if let handle = state.patternPathHandle {
                                state.applyPatternPath(pathHandle: handle, spacing: state.patternPathSpacing)
                            }
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty && state.patternPathHandle != nil))
                        .disabled(state.selectedHandles.isEmpty || state.patternPathHandle == nil)
                    }
                }
                .padding(.vertical, 4)
            }
            }
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
    }

    /// Compact numeric field used across the patterning panel.
    private func patternField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(PlainTextFieldStyle())
            .padding(4)
            .frame(width: 48)
            .background(Color.bg_input)
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
    }

    /// Numeric field with little up/down stepper arrows so values can be nudged
    /// without retyping (MAS-157). `isInt` rounds to whole numbers; `minValue`
    /// clamps the low end.
    private func patternStepperField(_ value: Binding<Double>, step: Double = 1,
                                     minValue: Double = -.greatestFiniteMagnitude,
                                     isInt: Bool = false) -> some View {
        HStack(spacing: 3) {
            patternField(value)
            VStack(spacing: 1) {
                Button {
                    var v = value.wrappedValue + step
                    if isInt { v = (v).rounded() }
                    value.wrappedValue = max(minValue, v)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 7, weight: .bold))
                        .frame(width: 14, height: 9)
                }
                .buttonStyle(PlainButtonStyle())
                Button {
                    var v = value.wrappedValue - step
                    if isInt { v = (v).rounded() }
                    value.wrappedValue = max(minValue, v)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .frame(width: 14, height: 9)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .foregroundColor(Color.text_secondary)
            .background(Color.bg_input)
            .cornerRadius(3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.border_strong, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var textPlacingSection: some View {
        if state.currentTool == .select || state.currentTool == .sketchText {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "textformat")
                        .foregroundColor(Color.accent)
                    Text("TEXT PLACING")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }

                if true {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Draw a box on the canvas, then type. Shift+Enter for a new line, Enter to place.")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_muted)

                        // Style for the next text (and live for the one being typed).
                        textStyleControls(
                            font: textToolStyleBinding(\.editingTextFont, \.textToolFont),
                            size: Binding(
                                get: { state.isEditingText ? state.editingTextHeight : textHeight },
                                set: { state.isEditingText ? (state.editingTextHeight = $0) : (textHeight = $0) }
                            ),
                            spacing: textToolStyleBinding(\.editingTextCharSpacing, \.textToolCharSpacing),
                            bold: textToolStyleBinding(\.editingTextBold, \.textToolBold),
                            italic: textToolStyleBinding(\.editingTextItalic, \.textToolItalic),
                            underline: textToolStyleBinding(\.editingTextUnderline, \.textToolUnderline)
                        )

                        Divider().background(Color.border_subtle).padding(.vertical, 2)

                        // Fit the text to its drawn bounding box (MAS-157). Standard
                        // options found in other apps: warp to fit height, fit width,
                        // or stretch to fill the whole box.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fit to Box")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Picker("", selection: $state.textFitMode) {
                                Text("None").tag("none")
                                Text("Height").tag("height")
                                Text("Width").tag("width")
                                Text("Both").tag("both")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .labelsHidden()
                            .help("Draw a box, then type. None keeps the font size; Height/Width fit one axis; Both warps to fill the whole box.")
                        }

                        Divider().background(Color.border_subtle).padding(.vertical, 2)

                        HStack {
                            Text("Text String")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            TextField("Text", text: $textString)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 120)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                .help("The text characters to place as a CAD text entity")
                        }
                        
                        HStack {
                            Text("Height (mm)")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            TextField("Height", value: $textHeight, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 80)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                .help("Height of the text characters in millimeters")
                        }
                        
                        HStack {
                            Text("Insert X (mm)")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            TextField("X", value: $textInsertX, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 80)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                .help("X insertion origin coordinate in millimeters")
                        }
                        
                        HStack {
                            Text("Insert Y (mm)")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            TextField("Y", value: $textInsertY, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 80)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                .help("Y insertion origin coordinate in millimeters")
                        }
                        
                        Button("Place Text") {
                            state.applyAddText(text: textString, insert: CGPoint(x: textInsertX, y: textInsertY), height: textHeight,
                                               font: state.textToolFont, bold: state.textToolBold, italic: state.textToolItalic,
                                               underline: state.textToolUnderline, charSpacing: state.textToolCharSpacing)
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: !textString.isEmpty))
                        .disabled(textString.isEmpty)
                        .help("Create and place a text entity at the specified coordinates")
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    /// Reusable font / size / spacing / B-I-U controls (MAS-134/135). Each control
    /// is driven by a caller-supplied binding, so the same UI serves both the Text
    /// tool's defaults (and live in-progress edit) and a selected text entity.
    /// Labels sit above full-width controls so nothing crowds in a narrow panel.
    @ViewBuilder
    private func textStyleControls(
        font: Binding<String>,
        size: Binding<Double>,
        spacing: Binding<Double>,
        bold: Binding<Bool>,
        italic: Binding<Bool>,
        underline: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Font")
                FontPickerField(selection: font, onHoverFont: { state.fontHoverPreview = $0 })
                    .help("Choose from every font installed on this device — hover a font to preview it live")
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Size (mm)")
                    numberField(size, placeholder: "Size")
                        .help("Text height in millimetres (the box you drew sets the starting size)")
                }
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Spacing (mm)")
                    numberField(spacing, placeholder: "Spacing")
                        .help("Extra space added between every character (and to spaces)")
                }
            }

            HStack(spacing: 6) {
                textStyleToggle("B", isOn: bold, font: .system(size: 12, weight: .bold))
                textStyleToggle("I", isOn: italic, font: .system(size: 12).italic())
                textStyleToggle("U", isOn: underline, font: .system(size: 12, weight: .regular))
                    .underline(true, color: Color.text_primary)
                Spacer()
            }
        }
    }

    /// A single-line panel label that never wraps character-by-character.
    @ViewBuilder
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(PlasticityFont.label)
            .foregroundColor(Color.text_secondary)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A full-width numeric field used across the text style controls.
    @ViewBuilder
    private func numberField(_ value: Binding<Double>, placeholder: String) -> some View {
        TextField(placeholder, value: value, format: .number)
            .textFieldStyle(PlainTextFieldStyle())
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(Color.bg_input)
            .cornerRadius(4)
            .foregroundColor(Color.text_primary)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
    }

    /// One bold/italic/underline toggle chip for `textStyleControls`.
    @ViewBuilder
    private func textStyleToggle(_ label: String, isOn: Binding<Bool>, font: Font) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(font)
                .frame(width: 28, height: 24)
                .background(isOn.wrappedValue ? Color.accent.opacity(0.25) : Color.bg_input)
                .foregroundColor(isOn.wrappedValue ? Color.accent : Color.text_primary)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(isOn.wrappedValue ? Color.accent : Color.border_strong, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Routes a Text-tool style binding to the *live* editing value while a text
    /// is being typed (so changes preview instantly), otherwise to the tool
    /// default applied to the next text created (MAS-135).
    private func textToolStyleBinding<T>(_ editingKP: ReferenceWritableKeyPath<AppState, T>,
                                         _ toolKP: ReferenceWritableKeyPath<AppState, T>) -> Binding<T> {
        Binding(
            get: { state.isEditingText ? state[keyPath: editingKP] : state[keyPath: toolKP] },
            set: { newVal in
                if state.isEditingText { state[keyPath: editingKP] = newVal }
                else { state[keyPath: toolKP] = newVal }
            }
        )
    }

    /// TEXT properties for a single selected text entity (MAS-135): edit its
    /// content, font, size, spacing and B/I/U live. Shown in the Select tool's
    /// active options when exactly one TEXT entity is selected.
    @ViewBuilder
    private var textPropertiesSection: some View {
        if state.currentTool == .select, let textEnt = state.singleSelectedTextEntity {
            let handle = textEnt.handle
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "textformat")
                        .foregroundColor(Color.accent)
                    Text("TEXT")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Content")
                    TextField("Text", text: Binding(
                        get: { textEnt.text ?? "" },
                        set: { state.updateTextEntity(handle: handle, text: $0) }
                    ))
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .background(Color.bg_input)
                    .cornerRadius(4)
                    .foregroundColor(Color.text_primary)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                }

                textStyleControls(
                    font: Binding(
                        get: { textEnt.fontName ?? "" },
                        set: { state.updateTextEntity(handle: handle, font: $0) }
                    ),
                    size: Binding(
                        get: { textEnt.height ?? 5.0 },
                        set: { state.updateTextEntity(handle: handle, height: $0) }
                    ),
                    spacing: Binding(
                        get: { textEnt.charSpacing ?? 0.0 },
                        set: { state.updateTextEntity(handle: handle, charSpacing: $0) }
                    ),
                    bold: Binding(
                        get: { textEnt.bold ?? false },
                        set: { state.updateTextEntity(handle: handle, bold: $0) }
                    ),
                    italic: Binding(
                        get: { textEnt.italic ?? false },
                        set: { state.updateTextEntity(handle: handle, italic: $0) }
                    ),
                    underline: Binding(
                        get: { textEnt.underline ?? false },
                        set: { state.updateTextEntity(handle: handle, underline: $0) }
                    )
                )

                Text("Double-click the text on the canvas to retype it.")
                    .font(PlasticityFont.label)
                    .foregroundColor(Color.text_muted)
            }
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var referenceImageSection: some View {
        if state.currentTool == .select {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "photo")
                        .foregroundColor(Color.accent)
                    Text("REFERENCE IMAGE")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }
                .padding(.bottom, 4)
                
                VStack(alignment: .leading, spacing: 8) {
                    if state.refImage == nil {
                        Button("Load Reference Image...") {
                            importReferenceImage()
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Image Underlay Loaded")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.status_ok)
                                Spacer()
                                Button("Clear") {
                                    state.refImage = nil
                                    state.refImageBase64 = nil
                                }
                                .buttonStyle(LinkButtonStyle())
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Opacity")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_secondary)
                                HStack {
                                    Slider(value: $state.refImageOpacity, in: 0...1)
                                    Text(String(format: "%.1f", state.refImageOpacity))
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_primary)
                                        .frame(width: 25)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Position Offset (mm)")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_secondary)
                                
                                HStack {
                                    Text("X:")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_muted)
                                    TextField("X Offset", value: Binding<Double>(
                                        get: { Double(state.refImageOffset.width) },
                                        set: { state.refImageOffset.width = CGFloat($0) }
                                    ), format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    
                                    Text("Y:")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_muted)
                                    TextField("Y Offset", value: Binding<Double>(
                                        get: { Double(state.refImageOffset.height) },
                                        set: { state.refImageOffset.height = CGFloat($0) }
                                    ), format: .number)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .padding(4)
                                    .background(Color.bg_input)
                                    .cornerRadius(4)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                }
                                
                                HStack(spacing: 8) {
                                    Button(action: { state.refImageOffset.width -= NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0 }) {
                                        Image(systemName: "arrow.left")
                                            .font(.system(size: 10))
                                            .frame(width: 20, height: 20)
                                            .background(Color.bg_input)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    
                                    Button(action: { state.refImageOffset.height += NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0 }) {
                                        Image(systemName: "arrow.up")
                                            .font(.system(size: 10))
                                            .frame(width: 20, height: 20)
                                            .background(Color.bg_input)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    
                                    Button(action: { state.refImageOffset.height -= NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0 }) {
                                        Image(systemName: "arrow.down")
                                            .font(.system(size: 10))
                                            .frame(width: 20, height: 20)
                                            .background(Color.bg_input)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    
                                    Button(action: { state.refImageOffset.width += NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0 }) {
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 10))
                                            .frame(width: 20, height: 20)
                                            .background(Color.bg_input)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    
                                    Text("Nudge (Shift=10mm)")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_muted)
                                }
                                .padding(.top, 4)
                            }
                            
                            Divider().background(Color.border_subtle)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("2-POINT CALIBRATION")
                                    .font(PlasticityFont.label)
                                    .fontWeight(.bold)
                                    .foregroundColor(Color.accent)
                                
                                HStack {
                                    Text("Target Dist (mm)")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_secondary)
                                    Spacer()
                                    TextField("Distance", value: $state.calibrationDistance, format: .number)
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .padding(4)
                                        .frame(width: 80)
                                        .background(Color.bg_input)
                                        .cornerRadius(4)
                                        .foregroundColor(Color.text_primary)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                }
                                
                                Toggle("Enable Calibrate Mode", isOn: $state.isCalibrationActive)
                                    .toggleStyle(.checkbox)
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_primary)
                                
                                if state.isCalibrationActive {
                                    Text("Click 2 points on grid. Points: \(state.calibrationPoints.count)/2")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.status_warn)
                                }
                            }
                        }
                    }
                }
            }
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var layersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with action buttons
            HStack(spacing: 8) {
                Image(systemName: "square.3.layers.3d")
                    .foregroundColor(Color.accent)
                Text("LAYERS")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary)
                    .tracking(0.5)
                
                Spacer()

                // Hide-all-construction-layers toggle (left of Add Layer).
                Button(action: { state.hideConstructionLayers.toggle() }) {
                    Image(systemName: state.hideConstructionLayers ? "ruler.fill" : "ruler")
                        .font(.system(size: 11))
                        .foregroundColor(state.hideConstructionLayers ? Color.text_muted : .orange)
                }
                .buttonStyle(PlainButtonStyle())
                .help(state.hideConstructionLayers ? "Show construction layers" : "Hide all construction layers")

                // Add Layer Button
                Button(action: {
                    let num = state.layers.count + 1
                    state.addLayer(name: "Layer \(num)")
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Add a new layer")
                
                // Add Folder Button
                Button(action: {
                    let num = state.layerFolders.count + 1
                    state.addFolder(name: "Folder \(num)")
                }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Add a new folder")
            }
            .padding(.bottom, 4)
            
            // List of hierarchical items
            VStack(alignment: .leading, spacing: 5) {
                let items = state.getFlattenedLayerItems()
                if items.isEmpty {
                    Text("No layers")
                        .font(PlasticityFont.body)
                        .foregroundColor(Color.text_muted)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(items) { item in
                                HStack(spacing: 6) {
                                    // Indentation
                                    Spacer().frame(width: CGFloat(item.depth * 14))
                                    
                                    if item.isFolder {
                                        // Folder expand/collapse chevron
                                        Button(action: {
                                            if state.expandedFolderIds.contains(item.id) {
                                                state.expandedFolderIds.remove(item.id)
                                            } else {
                                                state.expandedFolderIds.insert(item.id)
                                            }
                                        }) {
                                            Image(systemName: state.expandedFolderIds.contains(item.id) ? "chevron.down" : "chevron.right")
                                                .font(.system(size: 8, weight: .black))
                                                .foregroundColor(Color.text_secondary)
                                                .frame(width: 12, height: 12)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        
                                        Image(systemName: state.expandedFolderIds.contains(item.id) ? "folder.fill" : "folder")
                                            .font(.system(size: 10))
                                            .foregroundColor(Color.accent)
                                    } else {
                                        // Layer visibility toggle
                                        Button(action: {
                                            if let idx = state.layers.firstIndex(where: { $0.id == item.id }) {
                                                state.layers[idx].visible.toggle()
                                            }
                                        }) {
                                            Image(systemName: item.visible ? "eye" : "eye.slash")
                                                .font(.system(size: 10))
                                                .foregroundColor(item.visible ? Color.text_primary : Color.text_muted)
                                                .frame(width: 12, height: 12)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        
                                        if item.isReferenceImageLayer {
                                            Image(systemName: "photo")
                                                .font(.system(size: 10))
                                                .foregroundColor(Color.accent)
                                                .frame(width: 12, height: 12)
                                        } else {
                                            // Premium color dot overlaying a borderless color
                                            // picker. The picker fills a larger, fully
                                            // hit-testable area so a click anywhere on the
                                            // swatch reliably opens the picker (MAS-157).
                                            ZStack {
                                                Circle()
                                                    .fill(item.color ?? Color.clear)
                                                    .overlay(
                                                        Circle().stroke(Color.border_strong, lineWidth: 1)
                                                    )
                                                    .frame(width: 12, height: 12)
                                                    .allowsHitTesting(false)
                                                ColorPicker("", selection: Binding(
                                                    get: { item.color ?? Color.clear },
                                                    set: { state.colorLayer(id: item.id, newColorHex: $0.toHex()) }
                                                ))
                                                .labelsHidden()
                                                .opacity(0.02)
                                                .frame(width: 20, height: 20)
                                                .contentShape(Rectangle())
                                            }
                                            .frame(width: 20, height: 20)
                                            .help("Click to change this layer's color")
                                        }
                                    }
                                    
                                    // Renamable Name text field / label
                                    if renamingItemId == item.id {
                                        TextField("", text: $renamingText, onCommit: {
                                            if item.isFolder {
                                                state.renameFolder(id: item.id, newName: renamingText)
                                            } else {
                                                state.renameLayer(id: item.id, newName: renamingText)
                                            }
                                            renamingItemId = nil
                                        })
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .font(PlasticityFont.body)
                                        .foregroundColor(Color.text_primary)
                                        .background(Color.bg_input)
                                        .frame(maxWidth: .infinity)
                                    } else {
                                        Text(item.name)
                                            .font(PlasticityFont.body)
                                            .foregroundColor((item.isFolder || item.visible) ? Color.text_primary : Color.text_muted)
                                            .gesture(
                                                TapGesture(count: 2).onEnded {
                                                    renamingItemId = item.id
                                                    renamingText = item.name
                                                }
                                            )

                                        if state.layers.first(where: { $0.id == item.id })?.isConstruction == true {
                                            Image(systemName: "ruler")
                                                .font(.system(size: 9))
                                                .foregroundColor(.orange)
                                                .help("Construction layer — orange, and excluded from the final export")
                                        }

                                        Spacer()
                                    }
                                    
                                    // Context actions menu for ordering and grouping
                                    Menu {
                                        Button("Rename") {
                                            renamingItemId = item.id
                                            renamingText = item.name
                                        }
                                        
                                        Divider()
                                        
                                        Button("Move Up") {
                                            state.moveUp(id: item.id, isFolder: item.isFolder)
                                        }
                                        Button("Move Down") {
                                            state.moveDown(id: item.id, isFolder: item.isFolder)
                                        }
                                        
                                        Divider()
                                        
                                        // Change group folder sub-menu
                                        Menu("Move to Folder") {
                                            Button("Root Level") {
                                                if item.isFolder {
                                                    state.moveFolder(id: item.id, toFolderId: nil)
                                                } else {
                                                    state.moveLayer(id: item.id, toFolderId: nil)
                                                }
                                            }
                                            ForEach(state.layerFolders.filter { $0.id != item.id }) { folder in
                                                Button(folder.name) {
                                                    if item.isFolder {
                                                        state.moveFolder(id: item.id, toFolderId: folder.id)
                                                    } else {
                                                        state.moveLayer(id: item.id, toFolderId: folder.id)
                                                    }
                                                }
                                            }
                                        }
                                        
                                        // Layer merging (MAS-147): merge-down
                                        // when a layer sits below, and merge the
                                        // whole multi-selection into its bottom.
                                        if !item.isFolder && (state.layerBelow(item.id) != nil || (state.activeLayerIds.count >= 2 && state.activeLayerIds.contains(item.id))) {
                                            Divider()
                                            if state.layerBelow(item.id) != nil {
                                                Button("Merge with Below") {
                                                    state.mergeLayerDown(id: item.id)
                                                }
                                            }
                                            if state.activeLayerIds.count >= 2 && state.activeLayerIds.contains(item.id) {
                                                Button("Merge Selected Layers") {
                                                    state.mergeSelectedLayers()
                                                }
                                            }
                                        }

                                        if !item.isFolder {
                                            Divider()
                                            let isC = state.layers.first(where: { $0.id == item.id })?.isConstruction == true
                                            Button(isC ? "Make Normal Layer" : "Make Construction") {
                                                state.setLayerConstruction(item.id, !isC)
                                            }
                                        }

                                        Divider()

                                        Button("Delete", role: .destructive) {
                                            if item.isFolder {
                                                state.deleteFolder(id: item.id)
                                            } else {
                                                state.deleteLayer(id: item.id)
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 9))
                                            .foregroundColor(Color.text_secondary)
                                            .frame(width: 14, height: 14)
                                    }
                                    .menuStyle(BorderlessButtonMenuStyle())
                                    .menuIndicator(.hidden)
                                    .frame(width: 16)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(!item.isFolder && state.activeLayerIds.contains(item.id) ? Color.accent.opacity(0.12) : Color.clear)
                                .cornerRadius(3)
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    TapGesture(count: 1).onEnded {
                                        if !item.isFolder {
                                            // Clicking a layer selects all of its geometry (MAS-105).
                                            state.selectAllInLayer(layerId: item.id)
                                        }
                                    }
                                )
                                .onDrag {
                                    NSItemProvider(object: item.id as NSString)
                                }
                                .onDrop(of: [.text], delegate: LayerDropDelegate(item: item, state: state))
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    // Animate drag-to-reorder reflow so rows glide into place
                    // rather than teleporting (MAS-60).
                    .animation(.spring(response: 0.3, dampingFraction: 0.82),
                               value: state.layers.map { $0.id } + state.layerFolders.map { $0.id })
                }
            }
        }
        // Full-panel with a margin, not a boxed sub-panel (MAS-60).
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var importSettingsSection: some View {
        if state.currentTool == .select {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundColor(Color.accent)
                    Text("IMPORT SETTINGS")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }
                .padding(.bottom, 4)
                
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Consolidate SVG Strokes", isOn: $state.consolidateSvgStrokes)
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_primary)
                        .toggleStyle(.checkbox)

                    // SVG import thickness (MAS-146 quick win) — previously had no
                    // control though the value was already sent to the importer.
                    HStack {
                        Text("Import Thickness (mm)")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        Spacer()
                        TextField("Thickness", value: $state.svgImportThickness, format: .number)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding(4)
                            .frame(width: 70)
                            .background(Color.bg_input)
                            .cornerRadius(4)
                            .foregroundColor(Color.text_primary)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                    }

                    // SVG Fill Mode (MAS-146): preserve filled regions as HATCH.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SVG Fill Mode")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        Picker("", selection: $state.svgFillMode) {
                            Text("Strokes only").tag("strokes")
                            Text("Preserve fills").tag("preserve")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .help("Strokes only converts every shape to an outline. Preserve fills imports filled SVG shapes as filled regions.")
                    }
                }
            }
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }
}

extension ContentView {
    /// True when the active tool / selection actually has options to show, so the
    /// collapsible card only appears when there's something in it (MAS-114).
    private var hasActiveToolOptions: Bool {
        switch state.currentTool {
        case .offset, .addThickness, .cleanup, .addHoles, .sketchRectangle, .sketchText,
             .sketchLine, .sketchCircle, .fillet, .chamfer, .paperFolding,
             .patterning, .move, .convertLines, .mirror, .select, .dimension, .scale,
             .sketchPolygon, .templateInsert, .boxStitch, .mandala, .boxJoint,
             .goldenGuide, .jigExport:
            return true
        default:
            return false
        }
    }

    /// Active tool options — full-panel, always open, no collapse chevron and no
    /// boxed sub-boundary (per user direction, superseding the earlier MAS-114
    /// collapsible card). The per-tool option views fill the panel directly.
    @ViewBuilder
    var activeToolOptionsPanel: some View {
        if hasActiveToolOptions {
            activeToolOptions
                .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var referenceImageSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "photo").foregroundColor(Color.accent)
                Text("REFERENCE IMAGE")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary)
                    .tracking(0.5)
                Spacer()
            }
            .padding(.bottom, 4)
            
            if let layer = state.activeLayer {
                VStack(alignment: .leading, spacing: 10) {
                    // Lock Toggle & Visibility Toggle
                    HStack {
                        Toggle("Locked", isOn: Binding(
                            get: { layer.locked },
                            set: { state.updateActiveLayerTransform(locked: $0) }
                        ))
                        .font(PlasticityFont.label)
                        
                        Spacer()
                        
                        Button(action: {
                            if let idx = state.layers.firstIndex(where: { $0.id == layer.id }) {
                                state.layers[idx].visible.toggle()
                            }
                        }) {
                            Label(layer.visible ? "Visible" : "Hidden", systemImage: layer.visible ? "eye" : "eye.slash")
                                .font(PlasticityFont.label)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    // Opacity Slider
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Opacity")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", layer.refImageOpacity * 100))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color.text_primary)
                        }
                        Slider(value: Binding(
                            get: { layer.refImageOpacity },
                            set: { state.updateActiveLayerTransform(opacity: $0) }
                        ), in: 0.0...1.0)
                    }
                    
                    // Depth Segmented Control (Front/Back)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Depth")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        Picker("", selection: Binding(
                            get: { layer.refImageDepth },
                            set: { state.updateActiveLayerTransform(depth: $0) }
                        )) {
                            Text("Front").tag("front")
                            Text("Back").tag("back")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .labelsHidden()
                    }
                    
                    // Edit Transform Button
                    Button(action: {
                        state.backupActiveLayerTransform()
                        state.isEditingRefImageTransform.toggle()
                    }) {
                        Text(state.isEditingRefImageTransform ? "Finish Transform" : "Edit Transform")
                            .font(PlasticityFont.body)
                            .foregroundColor(Color.text_primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.accent.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Calibration Section
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Calibration")
                            .font(PlasticityFont.header)
                            .foregroundColor(Color.text_primary)
                            .padding(.top, 4)
                        
                        Text("Enter target distance, click Calibrate, then click 2 points on the image.")
                            .font(.system(size: 10))
                            .foregroundColor(Color.text_secondary)
                        
                        HStack {
                            Text("Distance (mm)")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            TextField("Distance", value: $state.calibrationDistance, format: .number)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 60)
                        }
                        
                        Button(action: {
                            state.calibrationPoints.removeAll()
                            state.isCalibrationActive.toggle()
                        }) {
                            Text(state.isCalibrationActive ? "Cancel Calibration" : "Calibrate Image")
                                .font(PlasticityFont.body)
                                .foregroundColor(Color.text_primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(state.isCalibrationActive ? Color.status_err.opacity(0.15) : Color.accent.opacity(0.15))
                                .cornerRadius(4)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    Divider()
                    
                    // Background removal — available directly from the image panel,
                    // not just inside the trace flow (MAS-157).
                    Button(action: {
                        if state.activeLayerBackgroundRemoved {
                            state.restoreActiveLayerBackground()
                        } else {
                            state.removeActiveLayerBackground()
                        }
                    }) {
                        Label(state.activeLayerBackgroundRemoved ? "Restore Background" : "Remove Background",
                              systemImage: state.activeLayerBackgroundRemoved ? "arrow.uturn.backward" : "scissors")
                            .font(PlasticityFont.body)
                            .foregroundColor(Color.text_primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.accent.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Trace Image Button
                    Button(action: {
                        state.isTracingRefImage = true
                        state.isEditingRefImageTransform = false
                        state.updateTracePreview()
                    }) {
                        Text("Trace Image (Vectorize)")
                            .font(PlasticityFont.body)
                            .foregroundColor(Color.text_primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.status_ok.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var imageVectorizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "wand.and.stars").foregroundColor(Color.accent)
                Text("IMAGE TRACING")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary)
                    .tracking(0.5)
                Spacer()
            }
            .padding(.bottom, 4)
            
            Text("Adjust thresholds for auto-vectorization. Previews are drawn in cyan.")
                .font(.system(size: 10))
                .foregroundColor(Color.text_secondary)
                .padding(.bottom, 4)
            
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Silhouette Tracing (Backgroundless)", isOn: Binding(
                    get: { state.backgroundlessMode },
                    set: { state.backgroundlessMode = $0; state.updateTracePreview() }
                ))
                .toggleStyle(.checkbox)
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_primary)
                .help("Trace the silhouette of non-transparent areas only")

                Toggle("Remove Background (rembg)", isOn: Binding(
                    get: { state.removeBackgroundMode },
                    set: { newVal in
                        state.removeBackgroundMode = newVal
                        // Apply the removal to the live image so the user sees the
                        // result, not just the trace (MAS-157). Unchecking restores it.
                        if newVal { state.removeActiveLayerBackground() }
                        else { state.restoreActiveLayerBackground() }
                        state.updateTracePreview()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_primary)
                .help("Remove the image background (rembg) so you can see the cut-out before tracing")

                // The cut-out persists after tracing/deselecting; this brings the
                // original image back on demand (MAS-157).
                if state.activeLayerBackgroundRemoved {
                    Button(action: { state.restoreActiveLayerBackground() }) {
                        Label("Restore Background", systemImage: "arrow.uturn.backward")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Color.accent.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                // Trim empty transparent borders from images as they're imported.
                // Moved here from the global header — it's an image setting (was
                // "Crop Transparent Margins" in the top toolbar).
                Toggle("Crop Transparent Margins", isOn: $state.autocropBackgroundlessImage)
                    .toggleStyle(.checkbox)
                    .font(PlasticityFont.label)
                    .foregroundColor(Color.text_primary)
                    .help("When importing an image, trim the empty transparent border so the artwork fills the frame")

                Divider()
                    .padding(.vertical, 4)

                // Threshold Slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Threshold")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        Spacer()
                        Text(String(format: "%.0f", state.traceThreshold))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.text_primary)
                    }
                    Slider(value: $state.traceThreshold, in: 0...255, onEditingChanged: { editing in
                        if !editing {
                            state.updateTracePreview()
                        }
                    })
                }
                
                // Tolerance Slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Tolerance/Detail")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        Spacer()
                        Text(String(format: "%.0f", state.traceTolerance))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.text_primary)
                    }
                    Slider(value: $state.traceTolerance, in: 1...100, onEditingChanged: { editing in
                        if !editing {
                            state.updateTracePreview()
                        }
                    })
                    Text("Use Left/Right arrows to adjust by 1.")
                        .font(.system(size: 8))
                        .foregroundColor(Color.text_muted)
                }
                
                // Corner Smoothness
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Corner Smoothness")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        Spacer()
                        Text(String(format: "%.0f", state.traceCornerSmoothness))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.text_primary)
                    }
                    Slider(value: $state.traceCornerSmoothness, in: 0...100, onEditingChanged: { editing in
                        if !editing {
                            state.updateTracePreview()
                        }
                    })
                }
                
                // Path Optimization
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Path Optimization")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_secondary)
                        Spacer()
                        Text(String(format: "%.0f", state.tracePathOptimization))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.text_primary)
                    }
                    Slider(value: $state.tracePathOptimization, in: 0...100, onEditingChanged: { editing in
                        if !editing {
                            state.updateTracePreview()
                        }
                    })
                }
                
                Divider()
                
                // When a PSD import queued several raster layers, one settings
                // pass vectorizes them all together (MAS-141).
                let psdBatch = state.psdVectorizeBatchLayerIds.count
                if psdBatch > 0 {
                    Text("These settings will be applied to all \(psdBatch) raster layer\(psdBatch == 1 ? "" : "s") from the PSD.")
                        .font(.system(size: 9))
                        .foregroundColor(Color.text_muted)
                }

                // Action buttons
                HStack(spacing: 8) {
                    Button(action: {
                        state.isTracingRefImage = false
                        state.tracePreviewEntities = []
                        state.psdVectorizeBatchLayerIds = []
                    }) {
                        Text("Cancel")
                            .font(PlasticityFont.body)
                            .foregroundColor(Color.text_primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.status_err.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: {
                        if psdBatch > 0 {
                            state.commitPSDVectorizeAll()
                        } else {
                            state.commitTrace()
                        }
                    }) {
                        Text(psdBatch > 0 ? "Vectorize All Layers" : "Generate Vectors")
                            .font(PlasticityFont.body)
                            .foregroundColor(Color.text_primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.status_ok.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var activeToolOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let activeL = state.activeLayer, activeL.isReferenceImageLayer {
                if state.isTracingRefImage {
                    imageVectorizationSection
                } else {
                    referenceImageSettingsSection
                }
            } else if state.currentTool == .offset {
                activeToolDetailsSection
            } else if state.currentTool == .addThickness {
                activeToolDetailsSection
            } else if state.currentTool == .cleanup {
                activeToolDetailsSection
            } else if state.currentTool == .addHoles {
                holesSewingSection
            } else if state.currentTool == .sketchRectangle {
                activeToolDetailsSection
            } else if state.currentTool == .sketchText {
                textPlacingSection
            } else if state.currentTool == .sketchLine || state.currentTool == .sketchCircle {
                activeToolDetailsSection
            } else if state.currentTool == .fillet || state.currentTool == .chamfer {
                filletSection
            } else if state.currentTool == .paperFolding {
                paperFoldingSection
            } else if state.currentTool == .patterning {
                patterningSection
            } else if state.currentTool == .move {
                moveSection
            } else if state.currentTool == .convertLines {
                convertLinesSection
            } else if state.currentTool == .dimension {
                dimensionToolSection
            } else if state.currentTool == .scale {
                scaleToolSection
            } else if state.currentTool == .sketchPolygon {
                polygonToolSection
            } else if state.currentTool == .mirror {
                mirrorSection
            } else if state.currentTool == .templateInsert {
                templateInsertSection
            } else if state.currentTool == .boxStitch {
                boxStitchSection
            } else if state.currentTool == .mandala {
                mandalaSection
            } else if state.currentTool == .boxJoint {
                boxJointSection
            } else if state.currentTool == .goldenGuide {
                goldenGuideSection
            } else if state.currentTool == .jigExport {
                jigExportSection
            } else if state.currentTool == .select {
                selectionSection
                if !state.selectedHandles.isEmpty {
                    leatherFillSection
                }
                textPropertiesSection
                dimensionEditorSection
                // Editing an existing converted-line group inline (MAS-58).
                if state.selectedConvertedGroupId != nil {
                    convertLinesSection
                }
            }
        }
    }

    // MARK: - LeatherCraft-parity tool panels

    private func toolHeader(_ icon: String, _ title: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(Color.accent)
            Text(title).font(PlasticityFont.header).foregroundColor(Color.text_primary).tracking(0.5)
            Spacer()
        }
    }

    private func numberField(_ label: String, _ binding: Binding<Double>) -> some View {
        HStack {
            Text(label).font(PlasticityFont.label).foregroundColor(Color.text_primary)
            Spacer()
            TextField("", value: binding, format: .number)
                .textFieldStyle(PlainTextFieldStyle()).padding(4).frame(width: 72)
                .background(Color.bg_input).cornerRadius(4)
                .foregroundColor(Color.text_primary)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
        }
    }

    private func toolButtons(ok: String, okAction: @escaping () -> Void) -> some View {
        HStack {
            Button(ok) { okAction() }
                .buttonStyle(.borderedProminent)
            Button("Cancel") { state.currentTool = .select }
                .buttonStyle(.bordered)
            Spacer()
        }
    }

    /// Insert Template — searchable, categorised gallery. Tap a card to drop it on
    /// the TEMPLATE layer at the origin.
    private var templateInsertSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolHeader("square.on.square.dashed", "TEMPLATES")
            Text("Tap a template to insert it (centred at the origin) on the TEMPLATE layer.")
                .font(.system(size: 10)).foregroundColor(Color.text_secondary)
            ForEach(TemplateStore.shared.categories, id: \.self) { cat in
                VStack(alignment: .leading, spacing: 4) {
                    Text(cat.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color.text_secondary)
                    ForEach(TemplateStore.shared.templates(in: cat)) { t in
                        Button { state.insertTemplate(t) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.name).font(PlasticityFont.label).foregroundColor(Color.text_primary)
                                    Text(t.dimensionLabel).font(.system(size: 9)).foregroundColor(Color.text_secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle").foregroundColor(Color.accent)
                            }
                            .padding(6)
                            .background(Color.bg_input)
                            .cornerRadius(5)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(t.note ?? "")
                    }
                }
            }
            Divider()
            Button("Done") { state.currentTool = .select }.buttonStyle(.bordered)
        }
    }

    /// Box Stitch Helper — equalise hole counts across the two selected panels.
    private var boxStitchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolHeader("rectangle.connected.to.line.below", "BOX STITCH")
            Text("Select two mating paths, then re-prick both with an equal hole count so the seams line up. Uses the active pricking iron.")
                .font(.system(size: 10)).foregroundColor(Color.text_secondary)
            HStack {
                Text("Match").font(PlasticityFont.label).foregroundColor(Color.text_primary)
                Spacer()
                Picker("", selection: $state.boxStitchStrategy) {
                    Text("Average").tag("average")
                    Text("Match A").tag("a")
                    Text("Match B").tag("b")
                }.labelsHidden().frame(width: 150)
            }
            Text("\(state.selectedHandles.count) selected (need 2)")
                .font(.system(size: 9)).foregroundColor(Color.text_secondary)
            toolButtons(ok: "Re-prick Both") { state.applyBoxStitch(exitAfterApply: true) }
        }
    }

    /// Mandala — radial / dihedral symmetry of the selected seed.
    private var mandalaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolHeader("circle.hexagongrid", "MANDALA")
            Text("Replicates the selected seed around the origin. Mirror adds reflected copies (kaleidoscope).")
                .font(.system(size: 10)).foregroundColor(Color.text_secondary)
            Stepper("Segments: \(state.mandalaSegments)", value: $state.mandalaSegments, in: 2...64)
                .font(PlasticityFont.label)
            Toggle("Mirror (dihedral)", isOn: $state.mandalaMirror).font(PlasticityFont.label)
            Text("\(state.selectedHandles.count) seed object(s) selected")
                .font(.system(size: 9)).foregroundColor(Color.text_secondary)
            toolButtons(ok: "Bake") { state.applyMandala(exitAfterApply: true) }
        }
    }

    /// Box Joint Maker — interlocking finger joint + mate, sized numerically.
    private var boxJointSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolHeader("puzzlepiece", "BOX JOINT")
            Text("Select a straight edge (a line, or a shape — its longest side is used), then create an interlocking finger joint along it.")
                .font(.system(size: 10)).foregroundColor(Color.text_secondary)
            Text("\(state.selectedHandles.count) selected")
                .font(.system(size: 9)).foregroundColor(Color.text_secondary)
            numberField("Finger width (mm)", $state.boxJointFingerWidth)
            numberField("Depth (mm)", $state.boxJointDepth)
            numberField("Kerf (mm)", $state.boxJointKerf)
            Toggle("Generate mating edge", isOn: $state.boxJointMate).font(PlasticityFont.label)
            toolButtons(ok: "Create") { state.applyBoxJoint(exitAfterApply: true) }
        }
    }

    /// Golden Ratio guides — spiral / phi rectangle / centre line.
    private var goldenGuideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolHeader("hurricane", "GOLDEN RATIO")
            Picker("", selection: $state.goldenKind) {
                Text("Spiral").tag("spiral")
                Text("Rectangle").tag("rectangle")
                Text("Centre Line").tag("centerline")
            }.pickerStyle(SegmentedPickerStyle()).labelsHidden()
            Text("Proportion guide on a construction layer (orange, never exported).")
                .font(.system(size: 10)).foregroundColor(Color.text_secondary)

            Toggle("Fit to selection", isOn: $state.goldenFitSelection)
                .font(PlasticityFont.label)
                .help("Size the guide to the selected geometry's bounding box")
            if !state.goldenFitSelection || state.selectionBoundingBox() == nil {
                numberField("Width (mm)", $state.goldenWidth)
                if state.goldenKind == "centerline" {
                    numberField("Length (mm)", $state.goldenHeight)
                } else {
                    numberField("Height (mm)", $state.goldenHeight)
                }
            }

            if state.goldenKind == "spiral" {
                HStack {
                    Text("Coil").font(PlasticityFont.label).foregroundColor(Color.text_primary)
                    Spacer()
                    Picker("", selection: $state.goldenHandedness) {
                        Text("CCW").tag("ccw")
                        Text("CW").tag("cw")
                    }.pickerStyle(SegmentedPickerStyle()).labelsHidden().frame(width: 110)
                }
                Stepper("Turns: \(String(format: "%.1f", state.goldenTurns))",
                        value: $state.goldenTurns, in: 0.5...8.0, step: 0.5)
                    .font(PlasticityFont.label)
                Toggle("Show golden rectangle", isOn: $state.goldenShowRect)
                    .font(PlasticityFont.label)
            }
            if state.goldenKind == "rectangle" {
                Stepper("Subdivisions: \(state.goldenSubdivisions)",
                        value: $state.goldenSubdivisions, in: 1...12)
                    .font(PlasticityFont.label)
            }
            toolButtons(ok: "Create") { state.applyGolden(exitAfterApply: true) }
        }
    }

    /// 3D Pattern / Jig — extrude selected closed regions to a binary STL.
    private var jigExportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolHeader("cube.transparent", "3D PATTERN / JIG")
            Text("Extrude the selected closed regions to a 3D-printable STL.")
                .font(.system(size: 10)).foregroundColor(Color.text_secondary)
            HStack {
                Text("Mode").font(PlasticityFont.label).foregroundColor(Color.text_primary)
                Spacer()
                Picker("", selection: $state.jigMode) {
                    Text("Solid pattern").tag("solid")
                    Text("Stitch template").tag("stitch_template")
                    Text("Corner jig").tag("corner_jig")
                }.labelsHidden().frame(width: 150)
            }
            numberField("Thickness (mm)", $state.jigThickness)
            Text("\(state.selectedHandles.count) region(s) selected")
                .font(.system(size: 9)).foregroundColor(Color.text_secondary)

            // Live isometric preview of the extruded mesh.
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.bg_input)
                jigPreviewCanvas
                if state.isComputingJigPreview {
                    ProgressView().scaleEffect(0.6)
                } else if state.jigPreviewTris.isEmpty {
                    Text("Select regions and press Preview")
                        .font(.system(size: 9)).foregroundColor(Color.text_muted)
                }
            }
            .frame(height: 150)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.border_strong, lineWidth: 1))
            if state.jigPreviewTriCount > 0 {
                Text("\(state.jigPreviewTriCount) triangles")
                    .font(.system(size: 9)).foregroundColor(Color.text_secondary)
            }

            HStack {
                Button("Preview") { state.refreshJigPreview() }.buttonStyle(.bordered)
                Button("Export STL…") { state.exportJig(exitAfterApply: true) }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { state.currentTool = .select }.buttonStyle(.bordered)
                Spacer()
            }
            .onAppear { state.refreshJigPreview() }
            .onChange(of: state.jigMode) { _ in state.refreshJigPreview() }
            .onChange(of: state.jigThickness) { _ in state.refreshJigPreview() }
            .onChange(of: state.selectedHandles) { _ in state.refreshJigPreview() }
        }
    }

    /// Isometric wireframe of the extruded jig mesh (state.jigPreviewVerts/Tris).
    private var jigPreviewCanvas: some View {
        Canvas { ctx, size in
            let v = state.jigPreviewVerts
            let t = state.jigPreviewTris
            let nVerts = v.count / 3
            guard nVerts >= 3, t.count >= 3 else { return }
            // isometric projection (x right-down, y left-down, z up)
            var proj = [CGPoint](repeating: .zero, count: nVerts)
            var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            for i in 0..<nVerts {
                let x = v[3 * i], y = v[3 * i + 1], z = v[3 * i + 2]
                let px = (x - y) * 0.8660254
                let py = (x + y) * 0.5 - z
                proj[i] = CGPoint(x: px, y: py)
                minX = min(minX, px); maxX = max(maxX, px)
                minY = min(minY, py); maxY = max(maxY, py)
            }
            let spanX = max(1e-6, maxX - minX), spanY = max(1e-6, maxY - minY)
            let pad: CGFloat = 10
            let scale = min((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanY)
            let offX = (size.width - spanX * scale) / 2
            let offY = (size.height - spanY * scale) / 2
            func scr(_ idx: Int) -> CGPoint {
                let p = proj[idx]
                return CGPoint(x: offX + (p.x - minX) * scale,
                               y: size.height - (offY + (p.y - minY) * scale)) // flip Y up
            }
            var wire = SwiftUI.Path()
            var i = 0
            while i + 2 < t.count {
                let a = t[i], b = t[i + 1], c = t[i + 2]
                if a < nVerts && b < nVerts && c < nVerts {
                    let pa = scr(a), pb = scr(b), pc = scr(c)
                    wire.move(to: pa); wire.addLine(to: pb)
                    wire.addLine(to: pc); wire.closeSubpath()
                }
                i += 3
            }
            ctx.fill(wire, with: .color(Color.accent.opacity(0.10)))
            ctx.stroke(wire, with: .color(Color.accent.opacity(0.55)), lineWidth: 0.5)
        }
        .padding(2)
    }

    /// Leather Simulator — assign a preview-only material fill to the selection.
    private var leatherFillSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolHeader("square.fill.on.square.fill", "LEATHER")
            Text("Preview fill for closed shapes (visual only — export stays vector).")
                .font(.system(size: 10)).foregroundColor(Color.text_secondary)
            HStack(spacing: 6) {
                ForEach(AppState.leatherSwatches, id: \.id) { sw in
                    Button { state.setLeatherFill(sw.id) } label: {
                        Circle()
                            .fill(AppState.leatherSwatchColor(sw.id) ?? Color.gray)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.border_strong, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(sw.name)
                }
                Button { state.setLeatherFill(nil) } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(Color.text_secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Clear leather fill")
            }
        }
    }

    /// POLYGON tool options (MAS-118): the sides count for the next polygon.
    private var polygonToolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "hexagon").foregroundColor(Color.accent)
                Text("POLYGON")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary).tracking(0.5)
                Spacer()
            }
            Text("Drag from the center to set radius and rotation.")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)

            HStack {
                Text("Sides")
                    .font(PlasticityFont.label)
                    .foregroundColor(Color.text_secondary)
                Spacer()
                Stepper(value: Binding(
                    get: { state.polygonSides },
                    set: { state.polygonSides = max(3, min(64, $0)) }
                ), in: 3...64) {
                    Text("\(state.polygonSides)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.text_primary)
                        .frame(minWidth: 24)
                }
            }
        }
    }

    /// SCALE tool options (MAS-128): pivot mode, factor entry, and a scale-point
    /// picker. Drag the on-canvas handle for a live scale, or type an exact factor.
    private var scaleToolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundColor(Color.accent)
                Text("SCALE")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary).tracking(0.5)
                Spacer()
            }
            Text("Select geometry, then drag the handle or enter a factor.")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)

            Text("Scale From")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)
            Picker("", selection: Binding(
                get: { state.scaleFromCenter },
                set: { useCenter in
                    state.scaleFromCenter = useCenter
                    if useCenter { state.scalePivotModel = nil; state.pickingScalePivot = false }
                }
            )) {
                Text("Center").tag(true)
                Text("Point").tag(false)
            }
            .pickerStyle(SegmentedPickerStyle())
            .help("Scale around the selection's own center, or a point you pick.")

            if !state.scaleFromCenter {
                Button {
                    state.pickingScalePivot = true
                } label: {
                    Label(state.scalePivotModel == nil ? "Pick Scale Point…" : "Re-pick Scale Point…",
                          systemImage: "scope")
                }
                .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                .help("Click a point on the canvas to scale around")
                if state.pickingScalePivot {
                    Text("Click a point on the canvas…")
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.accent)
                }
            }

            Text("Factor")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)
            TextField("1.0", value: $state.scaleFactor, format: .number)
                .textFieldStyle(PlainTextFieldStyle())
                .padding(6)
                .background(Color.bg_input)
                .cornerRadius(4)
                .foregroundColor(Color.text_primary)
                .font(PlasticityFont.body)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                // Enter commits the staged/typed factor and returns to Select,
                // the way other tools confirm (MAS-111).
                .onSubmit {
                    state.confirmScaleAndExit()
                }

            Button("Apply Scale") {
                state.confirmScaleAndExit()
            }
            .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty && state.scaleFactor > 0))
            .disabled(state.selectedHandles.isEmpty || state.scaleFactor <= 0)
        }
    }

    /// DIMENSION tool options (MAS-110): a short hint plus the live sketch
    /// parameter table so the user can reference variables in formulas.
    private var dimensionToolSection: some View {
        let params = state.dimensionEngine.params
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "ruler.fill").foregroundColor(Color.accent)
                Text("DIMENSION")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary).tracking(0.5)
                Spacer()
            }
            Text("Click a line for length, a circle for radius, or two points for a distance. Type a value or formula and press Enter.")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)
            Text("Formulas: 20*2, d1*0.5+10, sqrt(d2^2+d3^2). Units: 50, 2.54cm, 1 inch.")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_muted)

            if !params.isEmpty {
                Divider().background(Color.border_subtle)
                Text("PARAMETERS")
                    .font(PlasticityFont.label)
                    .foregroundColor(Color.text_secondary).tracking(0.5)
                ForEach(params) { p in
                    HStack(spacing: 6) {
                        Text(p.id)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(p.driven ? Color.text_muted : Color.accent)
                        Text(p.isFormula ? "= \(p.expression)" : "")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color.text_secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: p.driven ? "(%.2f)" : "%.2f", p.value))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.text_primary)
                    }
                }
            }
        }
    }

    /// CONVERT LINES tool options + inline editor for a selected converted group
    /// (MAS-58). Picks the style and per-style parameters, then applies.
    private var convertLinesSection: some View {
        let editingGroup = state.selectedConvertedGroupId
        let style = state.convertLineStyle
        let keys = AppState.convertLineParamKeys[style] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "scribble").foregroundColor(Color.accent)
                Text("CONVERT LINES")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary).tracking(0.5)
                Spacer()
            }
            Picker("Style", selection: Binding(
                get: { state.convertLineStyle },
                set: { newStyle in
                    state.convertLineStyle = newStyle
                    if let gid = editingGroup { state.reconvertGroup(gid, style: newStyle, settings: state.convertLineSettings[newStyle]) }
                }
            )) {
                ForEach(AppState.convertLineStyles, id: \.self) { s in
                    Text(s.capitalized).tag(s)
                }
            }
            .pickerStyle(.menu)

            LinePatternPreview(style: style, settings: state.convertLineSettings[style] ?? [:])
                .padding(.vertical, 4)

            ForEach(keys, id: \.self) { key in
                HStack {
                    Text(convertParamLabel(key))
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_secondary)
                    Spacer()
                    TextField("", value: convertParamBinding(key), format: .number)
                        .textFieldStyle(PlainTextFieldStyle())
                        .padding(4)
                        .frame(width: 60)
                        .background(Color.bg_input)
                        .cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                }
            }

            if let gid = editingGroup {
                Button("Update Lines") {
                    state.reconvertGroup(gid, style: style, settings: state.convertLineSettings[style])
                }
                .buttonStyle(PlasticityButtonStyle(isEnabled: true))
            } else {
                Button("Convert Selection") {
                    state.convertSelectedLines(style: style, settings: state.convertLineSettings[style] ?? [:])
                }
                .buttonStyle(PlasticityButtonStyle(isEnabled: state.selectionHasConvertibleLines))
                .disabled(!state.selectionHasConvertibleLines)
                .help("Replace the selected straight lines with the chosen style")
            }
        }
    }

    private func convertParamBinding(_ key: String) -> Binding<Double> {
        Binding(
            get: { state.convertLineSettings[state.convertLineStyle]?[key] ?? 0 },
            set: { state.convertLineSettings[state.convertLineStyle, default: [:]][key] = $0 }
        )
    }

    private func convertParamLabel(_ key: String) -> String {
        switch key {
        case "dash_length": return "Dash Length (mm)"
        case "gap": return "Gap (mm)"
        case "spacing": return "Spacing (mm)"
        case "dot_radius": return "Dot Radius (mm)"
        case "wavelength": return "Wavelength (mm)"
        case "amplitude": return "Amplitude (mm)"
        case "samples_per_wave": return "Samples / Wave"
        case "tilt": return "Tilt (°)"
        case "size": return "Size (mm)"
        default: return key.capitalized
        }
    }

    /// MOVE tool options (MAS-80): create-copy, point-to-point, scaling.
    private var moveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").foregroundColor(Color.accent)
                Text("MOVE")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary).tracking(0.5)
                Spacer()
            }
            Text("Drag the gizmo to move/rotate. Use the options below for precise moves.")
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)

            Toggle("Create copy (move duplicates)", isOn: $state.moveCreateCopy)
                .font(PlasticityFont.label)

            Divider().background(Color.border_subtle)

            Text("POINT TO POINT")
                .font(PlasticityFont.label).fontWeight(.bold).foregroundColor(Color.accent)
            Button(state.moveP2PActive ? (state.moveP2PFrom == nil ? "Click source point…" : "Click destination…") : "Start Point-to-Point") {
                state.moveP2PActive.toggle()
                state.moveP2PFrom = nil
            }
            .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
            .disabled(state.selectedHandles.isEmpty)

            Divider().background(Color.border_subtle)

            Text("SCALE")
                .font(PlasticityFont.label).fontWeight(.bold).foregroundColor(Color.accent)
            Toggle("From center (off = corner)", isOn: $state.moveScaleFromCenter)
                .font(PlasticityFont.label)
            HStack {
                Text("Factor").font(PlasticityFont.label).foregroundColor(Color.text_secondary)
                Spacer()
                TextField("", value: $state.moveScaleFactor, format: .number)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(4).frame(width: 60)
                    .background(Color.bg_input).cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
            }
            Button("Apply Scale") { state.scaleSelected(factor: state.moveScaleFactor) }
                .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty && state.moveScaleFactor > 0))
                .disabled(state.selectedHandles.isEmpty || state.moveScaleFactor <= 0)
        }
    }

    /// MIRROR tool options (MAS-55).
    private var mirrorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "flip.horizontal").foregroundColor(Color.accent)
                Text("MIRROR")
                    .font(PlasticityFont.header)
                    .foregroundColor(Color.text_primary).tracking(0.5)
                Spacer()
            }
            // Selection mode (MAS-119): Objects (pick geometry) vs Mirror Line (pick axis).
            Picker("", selection: $state.mirrorLineMode) {
                Text("Objects").tag(false)
                Text("Mirror Line").tag(true)
            }
            .pickerStyle(SegmentedPickerStyle())
            .help("Objects: click shapes to mirror.  Mirror Line: click a line (or two points) for the axis.")

            // Objects select box (count + clear).
            HStack {
                Text("Objects: \(state.selectedHandles.count)")
                    .font(PlasticityFont.label).foregroundColor(Color.text_secondary)
                Spacer()
                if !state.selectedHandles.isEmpty {
                    Button { state.selectedHandles.removeAll() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(Color.text_muted)
                    }.buttonStyle(PlainButtonStyle()).help("Clear objects")
                }
            }
            // Mirror line select box.
            HStack {
                Text(state.mirrorAxisEnd != nil ? "Mirror line: set" : "Mirror line: —")
                    .font(PlasticityFont.label)
                    .foregroundColor(state.mirrorAxisEnd != nil ? Color.accent : Color.text_secondary)
                Spacer()
                if state.mirrorAxisStart != nil {
                    Button { state.mirrorAxisStart = nil; state.mirrorAxisEnd = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(Color.text_muted)
                    }.buttonStyle(PlainButtonStyle()).help("Clear mirror line")
                }
            }

            Toggle("Mirror (flip) copy", isOn: $state.mirrorFlip)
                .font(PlasticityFont.label)
            Toggle("Keep live link", isOn: $state.mirrorKeepLink)
                .font(PlasticityFont.label)
            Text(state.mirrorStageHint)
                .font(PlasticityFont.label)
                .foregroundColor(Color.text_secondary)
            HStack(spacing: 8) {
                Button("OK") { state.confirmMirror() }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: state.mirrorAxisEnd != nil && !state.selectedHandles.isEmpty))
                    .disabled(state.mirrorAxisEnd == nil || state.selectedHandles.isEmpty)
                Button("Cancel") { state.resetMirrorTool() }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: true))
            }
        }
    }
}

extension ContentView {
    private var leftToolbar: some View {
        VStack(spacing: 4) {
            ScrollViewReader { scrollProxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    Spacer().frame(height: 12)
                    // Mode Toggle Buttons
                    ModeButton(mode: .twoD, systemName: "square.on.square", help: "2D Editor", state: state)
                    ModeButton(mode: .threeD, systemName: "cube", help: "3D STEP Importer", state: state)
                    ModeButton(mode: .construct, systemName: "shippingbox", help: "Construct — fold & stitch panels into the 3D object", state: state)
                    ModeButton(mode: .batch, systemName: "square.grid.2x2", help: "Batch Mode", state: state)
                    
                    Divider()
                        .background(Color.border_subtle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    
                    if state.activeMode == .twoD {
                        // Main tools, grouped into functional zones with dividers
                        // (MAS-117) and reflowed into N columns as the sidebar is
                        // widened (MAS-131). Each button is still Command-draggable
                        // to reorder / move groups (MAS-99).
                        let mainItems = layout.items(in: .main)
                        let cols = max(1, Int(leftToolbarWidth / 44))
                        let gridCols = Array(repeating: GridItem(.fixed(44), spacing: 0), count: cols)
                        let zones: [ToolbarZone] = [.selection, .modify, .precision, .creation]
                        ForEach(Array(zones.enumerated()), id: \.element.rawValue) { zi, zone in
                            let zoneItems = mainItems.filter { $0.zone == zone }
                            if !zoneItems.isEmpty {
                                if zi > 0 {
                                    Divider()
                                        .background(Color.border_subtle)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 2)
                                }
                                LazyVGrid(columns: gridCols, spacing: 0) {
                                    ForEach(zoneItems) { def in
                                        OrganizableToolButton(def: def, state: state, layout: layout)
                                            .id(def.id)
                                    }
                                }
                            }
                        }

                        // Shapes — opens a flyout grid of sketch tools (MAS-93). The
                        // icon is also a drop target: ⌘-dragging a shape tool onto it
                        // moves the tool into Shapes (MAS-99).
                        let isShapeActive = layout.items(in: .shapes).contains { def in
                            if case .tool(let t) = def.kind { return t == state.currentTool }
                            return false
                        }
                        Button(action: {
                            showShapes.toggle()
                        }) {
                            Image(systemName: "triangle")
                                .font(.system(size: 14))
                                .frame(width: 24, height: 24)
                                .padding(10)
                                .overlay(alignment: .trailing) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 7, weight: .bold))
                                        .padding(.trailing, 2)
                                        .opacity(0.7)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .background(isShapeActive ? Color.bg_selected : (isShapesHovered ? Color.accent.opacity(0.08) : Color.clear))
                        .foregroundColor(isShapeActive ? Color.accent : (isShapesHovered ? Color.accent_hover : Color.text_secondary))
                        .id("__shapes__")
                        .tutorialAnchor(.shapesFlyout)
                        .help("Shapes Sketching  (⌘-drop a shape tool here)")
                        .onHover { hover in
                            isShapesHovered = hover
                        }
                        .onDrop(of: [UTType.text], isTargeted: $isShapesHovered) { providers in
                            handleToolbarDrop(providers) { id in
                                if layout.canPlace(id, in: .shapes) { layout.move(id, to: .shapes) }
                            }
                        }
                        .popover(isPresented: $showShapes, arrowEdge: .trailing) {
                            OrganizableToolGrid(state: state, layout: layout, container: .shapes,
                                                onActivate: { showShapes = false })
                                .padding(10)
                        }

                        Divider()
                            .background(Color.border_subtle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)

                        // "Other Tools" utilities flyout (MAS-66 / MAS-117). ⌘-dropping
                        // a tool onto the ••• icon moves it into this group (MAS-99).
                        Button(action: { showMoreTools.toggle() }) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14))
                                .frame(width: 24, height: 24)
                                .padding(10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .background(isMoreToolsHovered ? Color.accent.opacity(0.08) : Color.clear)
                        .foregroundColor(isMoreToolsHovered ? Color.accent_hover : Color.text_secondary)
                        .id("__extra__")
                        .tutorialAnchor(.extraFlyout)
                        .help("More tools  (⌘-drop a tool here)")
                        .onHover { isMoreToolsHovered = $0 }
                        .onDrop(of: [UTType.text], isTargeted: $isMoreToolsHovered) { providers in
                            handleToolbarDrop(providers) { id in
                                if layout.canPlace(id, in: .extra) { layout.move(id, to: .extra) }
                            }
                        }
                        .popover(isPresented: $showMoreTools, arrowEdge: .trailing) {
                            OrganizableToolGrid(state: state, layout: layout, container: .extra,
                                                onActivate: { showMoreTools = false })
                                .padding(10)
                        }
                    } else if state.activeMode == .threeD {
                        // 3D tools live in this same leftmost sidebar (like 2D),
                        // not a separate strip inside the 3D editor.
                        let moveActive = state.bodyMoveToolActive
                        let planeActive = state.isPlaneSelectionActive
                        threeDToolButton(icon: "cursorarrow", active: !moveActive && !planeActive,
                                         help: "Select — orbit / select faces (no active tool)") {
                            if state.bodyMoveToolActive { state.toggleBodyMoveTool() }
                            if state.isPlaneSelectionActive { state.cancelPlaneSelection() }
                        }
                        threeDToolButton(icon: "move.3d", active: moveActive,
                                         help: "Move — select a body and translate it") {
                            if state.isPlaneSelectionActive { state.cancelPlaneSelection() }
                            if !state.bodyMoveToolActive { state.toggleBodyMoveTool() }
                        }
                        threeDToolButton(icon: "square.dashed", active: planeActive,
                                         help: "Plane — define a projection plane") {
                            if state.bodyMoveToolActive { state.toggleBodyMoveTool() }
                            if !state.isPlaneSelectionActive { state.startPlaneSelection() }
                        }
                    } else if state.activeMode == .construct {
                        // Construct tools share this leftmost sidebar, like 2D/3D —
                        // but labelled (icon + name), since users couldn't tell the
                        // assembly tools apart from icons alone.
                        ForEach(ConstructTool.available) { tool in
                            constructToolButton(tool)
                        }
                    }

                    Spacer()
                }
            }
            // Scroll the current tutorial step's tool into view before spotlighting.
            .onChange(of: tutorial.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    scrollProxy.scrollTo(target, anchor: .center)
                }
            }
            }
        }
        .frame(width: leftToolbarWidth)
        .background(Color.bg_panel)
        .border(Color.border_subtle, width: 1)
        .overlay(alignment: .trailing) {
            // Drag the trailing edge to widen; tools reflow into more columns. The
            // default 48 is the minimum (can't go narrower) (MAS-131).
            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture()
                        .onChanged { val in
                            leftToolbarWidth = min(232, max(48, leftToolbarWidth + val.translation.width))
                        }
                        .onEnded { _ in
                            // Snap to a whole number of 44px columns past the 48 base.
                            let cols = max(1, Int((leftToolbarWidth + 4) / 44))
                            leftToolbarWidth = cols <= 1 ? 48 : CGFloat(cols) * 44
                        }
                )
        }
    }

    /// One 3D-mode tool button for the leftmost sidebar, styled to match the 2D
    /// tool buttons (full-width hit area, accent highlight when active).
    private func threeDToolButton(icon: String, active: Bool, help: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(active ? Color.bg_selected : Color.clear)
        .foregroundColor(active ? Color.accent : Color.text_secondary)
        .help(help)
    }

    /// Construct tool button — icon **and** name stacked, so the assembly tools
    /// are legible at the default narrow rail width (the icons alone were a
    /// guessing game). Falls back to the same hover-help as elsewhere.
    private func constructToolButton(_ tool: ConstructTool) -> some View {
        let active = state.constructTool == tool
        return Button { state.setConstructTool(tool) } label: {
            VStack(spacing: 3) {
                Image(systemName: tool.icon).font(.system(size: 15))
                Text(tool.label).font(.system(size: 8.5)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(active ? Color.bg_selected : Color.clear)
        .foregroundColor(active ? Color.accent : Color.text_secondary)
        .help(constructToolHelp(tool))
    }

    private func constructToolHelp(_ tool: ConstructTool) -> String {
        switch tool {
        case .select: return "Select — orbit and pick folds"
        case .move:   return "Move — click a panel, then move / rotate / scale it (pose only)"
        case .fold:   return "Fold — drag a flap to fold it (snaps to 15/45/90°, ⇧ for free)"
        case .crease: return "Crease — click two points on a panel to add a fold line"
        case .ground: return "Ground — click a panel to pin it to the ground plane"
        case .stitch: return "Stitch — click one hole chain, then another, to sew them"
        case .glue:   return "Glue — click two panels to weld their meeting edges (glue tabs)"
        }
    }

    @ViewBuilder
    private var twoDEditorView: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let editingItem = state.activeEditingBatchItem {
                    HStack {
                        Button(action: {
                            if let activeURL = state.currentFilePath {
                                try? FileManager.default.removeItem(at: editingItem.fileURL)
                                try? FileManager.default.copyItem(at: activeURL, to: editingItem.fileURL)
                            }
                            
                            let tempDir = state.sessionTempDirectory.appendingPathComponent("batch")
                            let svgURL = tempDir.appendingPathComponent("\(UUID().uuidString).svg")
                            Task {
                                do {
                                    _ = try await PythonBridge.shared.run(
                                        module: "dxf_ops",
                                        op: "export_svg",
                                        args: ["input": editingItem.fileURL.path, "output": svgURL.path]
                                    )
                                    let svgStr = (try? String(contentsOf: svgURL, encoding: .utf8)) ?? ""
                                    try? FileManager.default.removeItem(at: svgURL)
                                    
                                    let listResult = try await PythonBridge.shared.run(
                                        module: "dxf_ops",
                                        op: "list_entities",
                                        args: ["input": editingItem.fileURL.path]
                                    )
                                    var itemsEnts: [DXFEntity] = []
                                    if let data = listResult["data"] as? [String: Any],
                                       let jsonEntities = data["entities"] as? [[String: Any]] {
                                        let jsonData = try JSONSerialization.data(withJSONObject: jsonEntities)
                                        itemsEnts = try JSONDecoder().decode([DXFEntity].self, from: jsonData)
                                    }
                                    
                                    await MainActor.run {
                                        if let idx = state.batchItems.firstIndex(where: { $0.id == editingItem.id }) {
                                            state.batchItems[idx].svgContent = svgStr
                                            state.batchItems[idx].entities = itemsEnts
                                        }
                                        state.activeEditingBatchItem = nil
                                        state.activeMode = .batch
                                    }
                                } catch {}
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                Text("Save & Return to Batch")
                            }
                            .foregroundColor(Color.accent)
                            .font(PlasticityFont.body.weight(.medium))
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        Spacer()
                        
                        Text("Editing: \(editingItem.originalName)")
                            .font(PlasticityFont.body.weight(.semibold))
                            .foregroundColor(Color.text_primary)
                        
                        Spacer()
                        Color.clear.frame(width: 150, height: 1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.bg_panel)
                    .border(width: 1, edges: [.bottom], color: Color.border_subtle)
                }
                

                
                // Main 2D Viewport
                ZStack {
                    // A blank/empty document is a first-class, editable canvas
                    // (MAS-8 / MAS-9 / MAS-49): show the canvas whenever a working
                    // document exists, not only once geometry has been rendered.
                    // The drop-zone is a fallback for the no-document state only.
                    if state.currentFilePath != nil || state.svgContent != nil || state.refImage != nil {
                        DxfCanvasView(state: state)
                    } else {
                        // Empty State Viewport (Plasticity Style)
                        VStack(spacing: 12) {
                            Image(systemName: "plus.square.dashed")
                                .font(.system(size: 32))
                                .foregroundColor(Color.text_muted)
                            
                            Text("DRAG & DROP DXF / STEP / SVG / STCH")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_secondary)
                                .tracking(0.5)
                            
                            Button("SELECT FILE") {
                                importFile()
                            }
                            .buttonStyle(BorderedButtonStyle())
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.bg_base)
                    }
                    
                    // Live Process Loader Overlay
                    if showSlowLoader {
                        ZStack {
                            Color.black.opacity(0.3)
                            VStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: Color.accent))
                                Text("Processing...")
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_secondary)
                            }
                            .padding(12)
                            .background(Color.bg_panel)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.border_strong, lineWidth: 1)
                            )
                        }
                    }
                    
                    // Floating error banner
                    if let error = state.errorMessage {
                        VStack {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(Color.status_err)
                                Text(error)
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_primary)
                                Spacer()
                                Button(action: { state.errorMessage = nil }) {
                                    Image(systemName: "xmark")
                                        .foregroundColor(Color.text_secondary)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(10)
                            .background(Color.bg_panel)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.status_err, lineWidth: 1)
                            )
                            .padding()
                            Spacer()
                        }
                    }
                }
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: nil) { providers, location in
                    collectDroppedURLs(providers) { urls in
                        if !urls.isEmpty { state.importFiles(urls, dropAt: location) }
                    }
                    return true
                }
            }
            .frame(maxWidth: .infinity)
            
            // Right Panel — drag the left edge to resize its width (MAS-131).
            HStack(spacing: 0) {
                // Resize grabber on the leading edge.
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .overlay(Rectangle().fill(Color.border_subtle).frame(width: 1), alignment: .leading)
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { val in
                                // Drag left → wider. Clamp to a sane range; content
                                // scales to fit, text stays the same size (MAS-131).
                                rightPanelWidth = min(520, max(200, rightPanelWidth - val.translation.width))
                            }
                    )

                VStack(alignment: .leading, spacing: 0) {
                    VSplitView(
                        top: VStack(spacing: 0) {
                            ScrollView {
                                activeToolOptionsPanel
                                    .padding(14)
                            }
                            // Keep the Sewing-Holes apply action pinned and always
                            // reachable, no matter how many options are expanded.
                            if state.currentTool == .addHoles {
                                holesApplyFooter
                            }
                        },
                        bottom: ScrollView {
                            layersSection
                                .padding(14)
                                .tutorialAnchor(.layersPanel)
                        },
                        topHeight: $leftSidebarTopHeight,
                        minTopHeight: 100,
                        minBottomHeight: 100,
                        defaultTopFraction: 2.0 / 3.0
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: rightPanelWidth)
            .background(Color.bg_panel)
        }
    }

    @ViewBuilder
    private var threeDImporterView: some View {
        VStack(spacing: 0) {
            ZStack {
                if state.stepJsonContent != nil {
                    ThreeDModeView(state: state)
                } else {
                    // Empty State Viewport (Plasticity Style)
                    VStack(spacing: 12) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 32))
                            .foregroundColor(Color.text_muted)
                        
                        Text("DRAG & DROP DXF / STEP / SVG / STCH")
                            .font(PlasticityFont.header)
                            .foregroundColor(Color.text_secondary)
                            .tracking(0.5)
                        
                        Button("SELECT FILE") {
                            importFile()
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.bg_base)
                }
                
                // Live Process Loader Overlay
                if showSlowLoader {
                    ZStack {
                        Color.black.opacity(0.3)
                        VStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: Color.accent))
                            Text("Processing...")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                        }
                        .padding(12)
                        .background(Color.bg_panel)
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.border_strong, lineWidth: 1)
                        )
                    }
                }
                
                // Floating error banner
                if let error = state.errorMessage {
                    VStack {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(Color.status_err)
                            Text(error)
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_primary)
                            Spacer()
                            Button(action: { state.errorMessage = nil }) {
                                Image(systemName: "xmark")
                                    .foregroundColor(Color.text_secondary)
                                }
                                .buttonStyle(PlainButtonStyle())
                        }
                        .padding(10)
                        .background(Color.bg_panel)
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.status_err, lineWidth: 1)
                        )
                        .padding()
                        Spacer()
                    }
                }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], isTargeted: nil) { providers, location in
                collectDroppedURLs(providers) { urls in
                    if !urls.isEmpty { state.importFiles(urls, dropAt: location) }
                }
                return true
            }
        }
        .frame(maxWidth: .infinity)
    }



    @ViewBuilder
    private var logAndStatusBarView: some View {
        VStack(spacing: 0) {
            if state.isLogTrayExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if state.logEntries.isEmpty {
                            Text("No logs yet")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_muted)
                                .padding(12)
                        } else {
                            ForEach(state.logEntries) { entry in
                                HStack {
                                    Text(entry.timestamp, style: .time)
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_muted)
                                        .frame(width: 80, alignment: .leading)
                                    
                                    Text(entry.action.uppercased())
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.accent)
                                        .frame(width: 150, alignment: .leading)
                                    
                                    Text(entry.details)
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_primary)
                                    
                                    if let layer = entry.layerAffected {
                                        Text("(\(layer))")
                                            .font(PlasticityFont.label)
                                            .foregroundColor(Color.text_muted)
                                    }
                                    
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(height: 120)
                .background(Color.bg_panel)
                .border(Color.border_subtle, width: 1)
            }
        }
    }
}

/// Resolves *every* dragged file into a `[URL]`, then delivers them on the main
/// queue. Uses `public.file-url` item loading — reliable for file drops, unlike
/// `loadObject(ofClass: URL.self)`, which silently resolved only one provider and
/// was the real "only one file imports" bug (MAS-13). Waits for all providers.
func collectDroppedURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            defer { group.leave() }
            var resolved: URL? = nil
            if let data = item as? Data {
                resolved = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                resolved = u
            }
            if let u = resolved {
                lock.lock(); urls.append(u); lock.unlock()
            }
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

struct VSplitView<Top: View, Bottom: View>: View {
    let top: Top
    let bottom: Bottom
    @Binding var topHeight: CGFloat
    let minTopHeight: CGFloat
    let minBottomHeight: CGFloat
    /// Fraction of the available height the top pane should occupy the first time
    /// the split is laid out (MAS-157: layers panel defaults to ~1/3, leaving the
    /// rest for the active-tool options). nil keeps the supplied `topHeight`.
    var defaultTopFraction: CGFloat? = nil

    @State private var isHoveringDivider = false
    @State private var didApplyDefault = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                top
                    .frame(height: max(minTopHeight, min(topHeight, geo.size.height - minBottomHeight)))
                
                Rectangle()
                    .fill(isHoveringDivider ? Color.accent : Color.border_subtle)
                    .frame(height: 5)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHoveringDivider = hovering
                        if hovering {
                            NSCursor.resizeUpDown.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { val in
                                let newHeight = topHeight + val.translation.height
                                topHeight = max(minTopHeight, min(newHeight, geo.size.height - minBottomHeight))
                            }
                    )
                
                bottom
                    .frame(maxHeight: .infinity)
            }
            .onAppear {
                if let frac = defaultTopFraction, !didApplyDefault, geo.size.height > 0 {
                    topHeight = max(minTopHeight, min(geo.size.height * frac, geo.size.height - minBottomHeight))
                    didApplyDefault = true
                }
            }
            .onChange(of: geo.size.height) { h in
                if let frac = defaultTopFraction, !didApplyDefault, h > 0 {
                    topHeight = max(minTopHeight, min(h * frac, h - minBottomHeight))
                    didApplyDefault = true
                }
            }
        }
    }
}

class DragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragNSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct LayerDropDelegate: DropDelegate {
    let item: AppState.LayerHierarchicalItem
    let state: AppState
    
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { data, error in
            guard let data = data as? Data,
                  let sourceId = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                state.reorderLayerOrFolder(sourceId: sourceId, targetId: item.id)
            }
        }
        return true
    }
}

struct LinePatternPreview: View {
    let style: String
    let settings: [String: Double]
    
    private func getSetting(_ key: String, default val: Double) -> Double {
        settings[key] ?? val
    }
    
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let centerY = h / 2.0
            
            // 1 mm = 4 points scale
            let scale: CGFloat = 4.0
            let xStart: CGFloat = 8.0
            let xEnd: CGFloat = w - 8.0
            let L = xEnd - xStart
            
            guard L > 0 else { return }
            
            switch style {
            case "dashed":
                let dash = CGFloat(max(0.1, getSetting("dash_length", default: 4.0))) * scale
                let gap = CGFloat(max(0.1, getSetting("gap", default: 3.0))) * scale
                let path = Path { p in
                    var t: CGFloat = 0.0
                    while t < L {
                        let segmentEnd = min(t + dash, L)
                        p.move(to: CGPoint(x: xStart + t, y: centerY))
                        p.addLine(to: CGPoint(x: xStart + segmentEnd, y: centerY))
                        t += max(2.0, dash + gap)
                    }
                }
                context.stroke(path, with: .color(.accent), lineWidth: 1.5)
                
            case "dotted":
                let spacing = CGFloat(max(0.2, getSetting("spacing", default: 3.0))) * scale
                let r = CGFloat(max(0.05, getSetting("dot_radius", default: 0.5))) * scale
                let n = max(1, Int(round(Double(L / spacing))))
                for k in 0...n {
                    let t = L * CGFloat(k) / CGFloat(n)
                    let center = CGPoint(x: xStart + t, y: centerY)
                    let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(.accent))
                }
                
            case "square":
                let spacing = CGFloat(max(0.3, getSetting("spacing", default: 4.0))) * scale
                let sizeVal = CGFloat(max(0.1, getSetting("size", default: 1.5))) * scale
                let s = sizeVal / 2.0
                let n = max(1, Int(round(Double(L / spacing))))
                for k in 0...n {
                    let t = L * CGFloat(k) / CGFloat(n)
                    let cx = xStart + t
                    let cy = centerY
                    let rect = CGRect(x: cx - s, y: cy - s, width: sizeVal, height: sizeVal)
                    context.stroke(Path(rect), with: .color(.accent), lineWidth: 1.5)
                }
                
            case "triangle":
                let spacing = CGFloat(max(0.3, getSetting("spacing", default: 5.0))) * scale
                let s = CGFloat(max(0.1, getSetting("size", default: 2.0))) * scale
                let n = max(1, Int(round(Double(L / spacing))))
                for k in 0...n {
                    let t = L * CGFloat(k) / CGFloat(n)
                    let bx = xStart + t
                    let by = centerY
                    let tip = CGPoint(x: bx, y: by - s)
                    let left = CGPoint(x: bx - s / 2.0, y: by)
                    let right = CGPoint(x: bx + s / 2.0, y: by)
                    let path = Path { p in
                        p.move(to: left)
                        p.addLine(to: right)
                        p.addLine(to: tip)
                        p.closeSubpath()
                    }
                    context.stroke(path, with: .color(.accent), lineWidth: 1.5)
                }
                
            case "zigzag":
                let wl = CGFloat(max(0.5, getSetting("wavelength", default: 6.0))) * scale
                let amp = CGFloat(getSetting("amplitude", default: 2.0)) * scale
                let n = max(2, Int(round(Double(L / (wl / 2.0)))))
                let path = Path { p in
                    for k in 0...n {
                        let t = L * CGFloat(k) / CGFloat(n)
                        var off = (k % 2 == 1) ? amp : -amp
                        if k == 0 || k == n {
                            off = 0.0
                        }
                        let pt = CGPoint(x: xStart + t, y: centerY + off)
                        if k == 0 {
                            p.move(to: pt)
                        } else {
                            p.addLine(to: pt)
                        }
                    }
                }
                context.stroke(path, with: .color(.accent), lineWidth: 1.5)
                
            case "wave":
                let wl = CGFloat(max(0.5, getSetting("wavelength", default: 6.0))) * scale
                let amp = CGFloat(getSetting("amplitude", default: 2.0)) * scale
                let spw = max(4, Int(getSetting("samples_per_wave", default: 12.0)))
                let n = max(spw, Int(round(Double(L / wl * CGFloat(spw)))))
                let path = Path { p in
                    for k in 0...n {
                        let t = L * CGFloat(k) / CGFloat(n)
                        let t_mm = Double(t / scale)
                        let wl_mm = getSetting("wavelength", default: 6.0)
                        let off = amp * CGFloat(sin(2.0 * Double.pi * t_mm / wl_mm))
                        let pt = CGPoint(x: xStart + t, y: centerY + off)
                        if k == 0 {
                            p.move(to: pt)
                        } else {
                            p.addLine(to: pt)
                        }
                    }
                }
                context.stroke(path, with: .color(.accent), lineWidth: 1.5)
                
            case "striped":
                let dash = CGFloat(max(0.1, getSetting("dash_length", default: 3.0))) * scale
                let gap = CGFloat(max(0.1, getSetting("gap", default: 3.0))) * scale
                let tilt = CGFloat(getSetting("tilt", default: 45.0)) * .pi / 180.0
                let sdx = cos(tilt)
                let sdy = sin(tilt)
                let half = dash / 2.0
                let path = Path { p in
                    var t: CGFloat = 0.0
                    while t < L {
                        let mx = xStart + t
                        let my = centerY
                        let p1 = CGPoint(x: mx - sdx * half, y: my - sdy * half)
                        let p2 = CGPoint(x: mx + sdx * half, y: my + sdy * half)
                        p.move(to: p1)
                        p.addLine(to: p2)
                        t += max(2.0, gap)
                    }
                }
                context.stroke(path, with: .color(.accent), lineWidth: 1.5)
                
            default:
                let path = Path { p in
                    p.move(to: CGPoint(x: xStart, y: centerY))
                    p.addLine(to: CGPoint(x: xEnd, y: centerY))
                }
                context.stroke(path, with: .color(.accent), lineWidth: 1.5)
            }
        }
        .frame(height: 48)
        .background(Color.bg_input)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.border_strong, lineWidth: 1)
        )
    }
}
/// Dropdown font picker that lists every installed family and **previews the
/// hovered font live** on the text being styled (MAS-134). Selecting commits the
/// choice; moving off a row (or closing the popover) reverts the preview. Used in
/// place of a plain `Picker` so per-row hover is observable.
struct FontPickerField: View {
    @Binding var selection: String           // "" == System Default
    var onHoverFont: (String?) -> Void

    @State private var show = false
    @State private var query = ""

    /// Every font family installed on the device, sorted. Resolved once.
    static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    private var displayName: String { selection.isEmpty ? "System Default" : selection }

    private var filtered: [String] {
        query.isEmpty ? Self.families
                      : Self.families.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 6) {
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(Color.text_primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(Color.text_secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color.bg_input)
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $show, arrowEdge: .leading) {
            VStack(spacing: 6) {
                TextField("Search fonts…", text: $query)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        fontRow("System Default", value: "")
                        ForEach(filtered, id: \.self) { fam in
                            fontRow(fam, value: fam)
                        }
                    }
                }
                .frame(width: 240, height: 320)
            }
            .padding(8)
            .onDisappear { onHoverFont(nil) }
        }
    }

    @ViewBuilder
    private func fontRow(_ label: String, value: String) -> some View {
        let isSel = selection == value
        Text(label)
            .font(DxfCanvasView.resolveTextFont(
                family: value.isEmpty ? nil : value, size: 13, bold: false, italic: false))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSel ? Color.accent.opacity(0.22) : Color.clear)
            .foregroundColor(isSel ? Color.accent : Color.text_primary)
            .contentShape(Rectangle())
            .onHover { hovering in onHoverFont(hovering ? value : nil) }
            .onTapGesture {
                selection = value
                onHoverFont(nil)
                show = false
            }
    }
}

/// One-off Export Options panel (MAS-156) — styled like Settings. Holds its own
/// options (not persisted); the Export button shows a destination save panel and
/// exports once with these settings.
struct ExportOptionsPanel: View {
    let state: AppState
    @State private var opts = ExportOptions()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.up").foregroundColor(.accentColor)
                Text("Export Options").font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()

            Form {
                Section {
                    Picker("Format", selection: $opts.format) {
                        ForEach(ExportOptions.formats, id: \.self) { f in
                            Text(ExportOptions.label(f)).tag(f)
                        }
                    }
                }

                if opts.format == "svg" {
                    Section("SVG") {
                        Stepper("Decimal Precision: \(opts.svgPrecision)", value: $opts.svgPrecision, in: 0...6)
                        HStack {
                            Text("Stroke Width (mm)")
                            Spacer()
                            TextField("", value: $opts.svgStrokeWidth, format: .number)
                                .frame(width: 70).multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                } else if opts.format == "dxf" {
                    Section("DXF") {
                        Picker("File Version", selection: $opts.dxfVersion) {
                            ForEach(ExportOptions.dxfVersions, id: \.self) { Text($0).tag($0) }
                        }
                    }
                } else if opts.format == "png" {
                    Section("PNG") {
                        HStack {
                            Text("Resolution — longest edge (px)")
                            Spacer()
                            TextField("", value: $opts.pngLongestEdge, format: .number)
                                .frame(width: 80).multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                        }
                        Toggle("Transparent Background", isOn: $opts.pngTransparent)
                    }
                } else if opts.format == "pdf" {
                    Section("PDF") {
                        Text("Vector PDF of the current drawing.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }

                Section("Content") {
                    Toggle("Export Selected Only", isOn: $opts.selectedOnly)
                    Toggle("Export Measurement Lines", isOn: $opts.measurementLines)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") {
                    let chosen = opts
                    dismiss()
                    // Let the sheet close before the save panel opens.
                    DispatchQueue.main.async { state.runExport(options: chosen) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.currentFilePath == nil)
            }
            .padding(16)
        }
        .frame(width: 460, height: 430)
    }
}

// MARK: - Onboarding (batch 4): first-run tutorial + per-mode intros

extension Notification.Name {
    /// Posted from Settings ▸ General to replay the guided tutorial.
    static let pathstitchReplayTutorial = Notification.Name("PathstitchReplayTutorial")
    /// Posted from Settings ▸ General to re-arm the per-mode intro popups.
    static let pathstitchResetIntros = Notification.Name("PathstitchResetIntros")
}

/// Bundles the first-run tutorial + per-mode intro overlays and their triggers
/// into one modifier. Keeping this out of `ContentView.body` keeps that (very
/// large) expression within the Swift type-checker's budget.
struct OnboardingModifier: ViewModifier {
    var state: AppState
    var tutorial: TutorialController

    @AppStorage("onboarding.tutorialDone") private var tutorialDone = false
    @AppStorage("onboarding.seenIntro.twoD") private var seenIntro2D = false
    @AppStorage("onboarding.seenIntro.threeD") private var seenIntro3D = false
    @AppStorage("onboarding.seenIntro.batch") private var seenIntroBatch = false
    @AppStorage("onboarding.seenIntro.construct") private var seenIntroConstruct = false
    @State private var modeIntro: AppMode? = nil
    @State private var modeIntroDontShowAgain = true
    /// Document snapshot captured when the current step began, so auto-advance can
    /// judge what the user changed during the step.
    @State private var stepBaseline: TutorialBaseline? = nil

    func body(content: Content) -> some View {
        content
            // Glowing ring around the tool/panel the current step points at.
            .overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let s = tutorial.step,
                       let rect = spotlightRect(step: s, anchors: anchors, proxy: proxy) {
                        SpotlightRing(rect: rect)
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay {
                if let step = tutorial.step {
                    TutorialOverlay(
                        step: Binding(get: { step }, set: { tutorial.step = $0 }),
                        onFinish: { finishTutorial() }
                    )
                }
            }
            .overlay {
                if let mode = modeIntro {
                    ModeIntroCard(
                        mode: mode,
                        dontShowAgain: $modeIntroDontShowAgain,
                        onOK: {
                            if modeIntroDontShowAgain { markIntroSeen(mode) }
                            modeIntro = nil
                            modeIntroDontShowAgain = true
                        }
                    )
                }
            }
            .onAppear { startOnboardingIfNeeded() }
            .onChange(of: state.activeMode) { _, newMode in maybeShowModeIntro(newMode) }
            // Re-baseline + (re)position the spotlight whenever the step changes.
            .onChange(of: tutorial.step) { _, new in handleStepChange(new) }
            // Auto-advance once the user has done what the step asked.
            .onChange(of: state.entities) { _, _ in checkCompletion() }
            .onChange(of: state.undoStack.count) { _, _ in checkCompletion() }
            // Fires when a fillet/chamfer session is confirmed or cancelled.
            .onChange(of: state.isCornerSessionActive) { _, _ in checkCompletion() }
            .onReceive(NotificationCenter.default.publisher(for: .pathstitchReplayTutorial)) { _ in
                modeIntro = nil
                tutorial.step = 0
            }
            .onReceive(NotificationCenter.default.publisher(for: .pathstitchResetIntros)) { _ in
                seenIntro2D = false; seenIntro3D = false; seenIntroBatch = false; seenIntroConstruct = false
            }
    }

    // MARK: Spotlight resolution

    /// The on-screen rect to ring for `step`, resolving a tool to whichever element
    /// currently hosts it (sidebar button, or the Shapes/More flyout button).
    private func spotlightRect(step: Int,
                               anchors: [TutorialHighlight: Anchor<CGRect>],
                               proxy: GeometryProxy) -> CGRect? {
        guard step >= 0, step < pathstitchTutorialSteps.count,
              let target = pathstitchTutorialSteps[step].spotlight,
              let highlight = resolveHighlight(target, anchors: anchors),
              let anchor = anchors[highlight] else { return nil }
        return proxy[anchor]
    }

    private func resolveHighlight(_ target: SpotlightTarget,
                                  anchors: [TutorialHighlight: Anchor<CGRect>]) -> TutorialHighlight? {
        switch target {
        case .layersPanel:
            return anchors[.layersPanel] != nil ? .layersPanel : nil
        case .tool(let tool):
            if anchors[.tool(tool)] != nil { return .tool(tool) }
            guard let id = tutorialToolItemId(tool) else { return nil }
            switch ToolbarLayout.shared.container(of: id) {
            case .shapes: return anchors[.shapesFlyout] != nil ? .shapesFlyout : nil
            case .extra:  return anchors[.extraFlyout] != nil ? .extraFlyout : nil
            default:      return nil
            }
        }
    }

    /// The toolbar `ScrollViewReader` id to scroll to so `step`'s tool is visible.
    private func scrollTargetId(for step: Int) -> String? {
        guard step >= 0, step < pathstitchTutorialSteps.count,
              case .tool(let tool)? = pathstitchTutorialSteps[step].spotlight,
              let id = tutorialToolItemId(tool) else { return nil }
        switch ToolbarLayout.shared.container(of: id) {
        case .main:   return id
        case .shapes: return "__shapes__"
        case .extra:  return "__extra__"
        case .none:   return nil
        }
    }

    // MARK: Step lifecycle

    private func handleStepChange(_ new: Int?) {
        guard let s = new else { tutorial.scrollTarget = nil; return }
        stepBaseline = TutorialBaseline(state)
        tutorial.scrollTarget = scrollTargetId(for: s)
    }

    private func checkCompletion() {
        guard let s = tutorial.step,
              s >= 0, s < pathstitchTutorialSteps.count,
              let baseline = stepBaseline,
              let isDone = pathstitchTutorialSteps[s].isComplete,
              isDone(state, baseline) else { return }
        advance(from: s)
    }

    /// Move on a beat after the action so the user sees their shape register.
    private func advance(from step: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard tutorial.step == step else { return }   // user already moved on
            if step >= pathstitchTutorialSteps.count - 1 {
                finishTutorial()
            } else {
                withAnimation(.easeInOut(duration: 0.25)) { tutorial.step = step + 1 }
            }
        }
    }

    private func finishTutorial() {
        tutorial.step = nil
        tutorial.scrollTarget = nil
        tutorialDone = true
        maybeShowModeIntro(state.activeMode)
    }

    private func startOnboardingIfNeeded() {
        if !tutorialDone {
            tutorial.step = 0
            seenIntro2D = true   // the tutorial already covers 2D
        } else {
            maybeShowModeIntro(state.activeMode)
        }
    }

    private func maybeShowModeIntro(_ mode: AppMode) {
        guard tutorial.step == nil, modeIntro == nil else { return }
        switch mode {
        case .twoD:   if !seenIntro2D    { modeIntro = .twoD }
        case .threeD: if !seenIntro3D    { modeIntro = .threeD }
        case .batch:  if !seenIntroBatch { modeIntro = .batch }
        case .construct: if !seenIntroConstruct { modeIntro = .construct }
        }
    }

    private func markIntroSeen(_ mode: AppMode) {
        switch mode {
        case .twoD:   seenIntro2D = true
        case .threeD: seenIntro3D = true
        case .batch:  seenIntroBatch = true
        case .construct: seenIntroConstruct = true
        }
    }
}

/// One step of the first-run guided tutorial.
struct TutorialStep {
    let title: String
    let body: String
    /// A short directional cue toward the relevant UI region (nil for none).
    let hint: String?
    /// The tool/panel to spotlight while this step is showing (nil = none).
    var spotlight: SpotlightTarget? = nil
    /// Returns true once the user has done what the step asks, judged against the
    /// baseline captured when the step began. nil ⇒ advance only via the Next
    /// button (intro / outro steps).
    var isComplete: ((AppState, TutorialBaseline) -> Bool)? = nil
}

let pathstitchTutorialSteps: [TutorialStep] = [
    .init(title: "Welcome to Pathstitch",
          body: "Let's make your first part in about a minute. Pathstitch turns drawings and 3D models into clean patterns that are ready to cut, score, or stitch.",
          hint: nil),
    .init(title: "1 · Draw a rectangle",
          body: "Open the highlighted Shapes tool, pick Rectangle, then drag on the canvas. After you drag it out, press Enter to confirm the shape. Shapes stay fully editable — you can tweak size and corners any time.",
          hint: nil,
          spotlight: .tool(.sketchRectangle),
          isComplete: { s, b in TutorialBaseline.polylines(in: s) > b.polylineCount }),
    .init(title: "2 · Add a circle",
          body: "Grab the highlighted Circle tool and drag out a circle beside your rectangle, then press Enter to confirm it. Use the Scale tool or type exact values to size things precisely.",
          hint: nil,
          spotlight: .tool(.sketchCircle),
          isComplete: { s, b in TutorialBaseline.circles(in: s) > b.circleCount }),
    .init(title: "3 · Round a corner with Fillet",
          body: "Select the highlighted Fillet tool, click a corner of the rectangle, then drag the orange arrow (or type a radius) and press Enter to confirm. Chamfer works the same way for an angled cut.",
          hint: nil,
          spotlight: .tool(.fillet),
          // Only advance once a fillet is actually applied AND the corner session is
          // confirmed (Enter / leaving the tool) — not on the preview that appears
          // the instant the tool is entered on a selected shape.
          isComplete: { s, b in
              !s.isCornerSessionActive && TutorialBaseline.filletedCorners(in: s) > b.filletedCorners
          }),
    .init(title: "4 · Layers organize your cuts",
          body: "The highlighted Layers panel groups geometry — for example separate cut, score, and engrave layers — so each exports the way your machine expects.",
          hint: nil,
          spotlight: .layersPanel),
    .init(title: "You're ready!",
          body: "That's the whole loop: draw → edit → organize → export. You can replay this tour anytime from Settings ▸ General ▸ Replay Tutorial.",
          hint: nil),
]

/// The first-run guided tutorial: a compact, non-blocking floating card stepped
/// with Back / Skip / Next. It dims the canvas only lightly so the user can still
/// see (and try) what each step describes — and most steps advance on their own
/// once the action is done.
struct TutorialOverlay: View {
    @Binding var step: Int
    let onFinish: () -> Void

    private var current: TutorialStep { pathstitchTutorialSteps[min(max(step, 0), pathstitchTutorialSteps.count - 1)] }
    private var isLast: Bool { step >= pathstitchTutorialSteps.count - 1 }
    /// Actionable steps wait for the user and advance automatically.
    private var waitsForAction: Bool { current.isComplete != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.12).ignoresSafeArea().allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Getting Started")
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.accent)
                    Spacer()
                    Button("Skip") { onFinish() }
                        .buttonStyle(PlainButtonStyle())
                        .foregroundColor(Color.text_muted)
                        .font(PlasticityFont.label)
                }
                .padding(.bottom, 8)

                Text(current.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.text_primary)
                    .padding(.bottom, 4)
                Text(current.body)
                    .font(PlasticityFont.body)
                    .foregroundColor(Color.text_secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint = current.hint {
                    Text(hint)
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.accent)
                        .padding(.top, 8)
                }

                if waitsForAction {
                    WaitingForActionCue()
                        .padding(.top, 8)
                }

                HStack(spacing: 8) {
                    // Step progress dots.
                    HStack(spacing: 5) {
                        ForEach(0..<pathstitchTutorialSteps.count, id: \.self) { i in
                            Circle()
                                .fill(i == step ? Color.accent : Color.text_muted.opacity(0.4))
                                .frame(width: 6, height: 6)
                        }
                    }
                    Spacer()
                    if step > 0 {
                        Button("Back") { step -= 1 }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                    }
                    // Actionable steps advance themselves; the button just lets the
                    // user skip ahead if they'd rather not try it.
                    Button(isLast ? "Done" : (waitsForAction ? "Skip step" : "Next")) {
                        if isLast { onFinish() } else { step += 1 }
                    }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 16)
            }
            .padding(18)
            .frame(width: 420)
            .background(Color.bg_panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.border_strong, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
            .padding(.bottom, 80)
        }
    }
}

/// A small pulsing "your turn" cue shown on steps that auto-advance.
private struct WaitingForActionCue: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.accent)
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.0 : 0.55)
                .opacity(pulse ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text("Your turn — I'll continue once you've done it.")
                .font(PlasticityFont.label)
                .foregroundColor(Color.accent)
        }
        .onAppear { pulse = true }
    }
}

/// One-time "what you can do here" card shown the first time each mode is opened.
/// Short, focused, with a default-on "Don't show again" checkbox and an OK button.
struct ModeIntroCard: View {
    let mode: AppMode
    @Binding var dontShowAgain: Bool
    let onOK: () -> Void

    private var info: (icon: String, title: String, bullets: [String]) {
        switch mode {
        case .twoD:
            return ("square.on.circle", "2D Design",
                    ["Draw and edit shapes with the tools on the left — rectangles, circles, lines, text, and the pen.",
                     "Fillet/chamfer corners, offset profiles, add sewing holes, and pattern geometry.",
                     "Organize cuts with the Layers panel, then export to DXF or SVG."])
        case .threeD:
            return ("cube", "3D Import & Unfold",
                    ["Drop in one or more STEP files — they load into a single workspace and space themselves apart.",
                     "Use Move and Plane from the left tool strip; pick faces, then unfold to flat patterns.",
                     "Send the resulting flat net back to 2D to finish and export."])
        case .batch:
            return ("square.grid.2x2", "Batch",
                    ["Drop in many files at once to process them together with shared settings.",
                     "Great for running the same export or operation across a whole folder of parts."])
        case .construct:
            return ("shippingbox", "Construct — Assembly",
                    ["Fold your flat panels into the real 3D object: pick a Ground panel, then fold along fold lines (draw them on a FOLD layer in 2D).",
                     "Leather is inextensible here — it bends but never stretches, so what you see is what will actually sew together.",
                     "Edit the 2D sketch and Rebuild to re-fold live. Stitching seams together comes next."])
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: info.icon)
                        .font(.system(size: 18))
                        .foregroundColor(Color.accent)
                    Text(info.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color.text_primary)
                }
                ForEach(Array(info.bullets.enumerated()), id: \.offset) { _, b in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Color.accent).frame(width: 5, height: 5).padding(.top, 6)
                        Text(b)
                            .font(PlasticityFont.body)
                            .foregroundColor(Color.text_secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().padding(.vertical, 2)
                HStack {
                    Toggle(isOn: $dontShowAgain) { Text("Don't show again").font(PlasticityFont.label) }
                        .toggleStyle(.checkbox)
                        .foregroundColor(Color.text_secondary)
                    Spacer()
                    Button("OK") { onOK() }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
            .background(Color.bg_panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.border_strong, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 28, y: 10)
        }
    }
}
