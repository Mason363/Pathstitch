import SwiftUI
import UniformTypeIdentifiers

struct ModeButton: View {
    let mode: AppMode
    let systemName: String
    let help: String
    var state: AppState
    @State private var isHovered = false
    
    var body: some View {
        Button(action: {
            state.activeMode = mode
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
            (isHovered ? Color.status_warn.opacity(0.15) : Color.clear)
        )
        .foregroundColor(
            state.activeMode == mode ? 
            Color.accent : 
            (isHovered ? Color.status_warn : Color.text_secondary)
        )
        .help(help)
        .onHover { hover in
            isHovered = hover
        }
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
            Image(systemName: tool.icon)
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            state.currentTool == tool ? 
            Color.bg_selected : 
            (isHovered ? Color.status_warn.opacity(0.15) : Color.clear)
        )
        .foregroundColor(
            state.currentTool == tool ? 
            Color.accent : 
            (isHovered ? Color.status_warn : Color.text_secondary)
        )
        .help(tool.rawValue)
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
            (isHovered ? Color.status_warn.opacity(0.15) : Color.clear)
        )
        .foregroundColor(
            state.currentTool == tool ? 
            Color.accent : 
            (isHovered ? Color.status_warn : Color.text_muted)
        )
        .help(tool.rawValue)
        .onHover { hover in
            isHovered = hover
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
            (isHovered ? Color.status_warn : Color.text_secondary)
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
    @State private var showExportDialog = false
    @State private var isShapesHovered = false
    @State private var offsetMode = "curve" // "curve" or "bbox"
    @State private var customLayerName: String = ""
    @State private var selectedExistingLayer: String = ""
    @State private var exportFormat: String = "dxf" // "dxf", "svg", "pdf", "png"
    
    @State private var isSelectionExpanded = true
    @State private var isHolesSewingExpanded = false
    @State private var isPaperFoldingExpanded = false
    @State private var isPatterningExpanded = false
    @State private var isTextPlacingExpanded = false
    @State private var isReferenceImageExpanded = false
    @State private var isLayersExpanded = false
    @State private var isImportSettingsExpanded = false
    @State private var isExportSettingsExpanded = false
    @State private var isShapesExpanded = false
    
    @State private var glueTabHeight: Double = 5.0
    @State private var glueTabType: String = "trapezoid" // "trapezoid" or "triangle"
    @State private var glueTabSide: String = "left" // "left" or "right"
    
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
    
    @State private var exportSelectedOnly = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftToolbar
                
                if state.activeMode == .twoD {
                    twoDEditorView
                } else if state.activeMode == .batch {
                    BatchModeView(state: state)
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
        .preferredColorScheme(.dark)
        // Bind hotkeys
        .background(hotkeyBindings)
        .onChange(of: state.selectedHandles) { _ in state.updateLivePreview() }
        .onChange(of: state.currentTool) { _ in state.updateLivePreview() }
        .onChange(of: state.offsetDistance) { _ in state.updateLivePreview() }
        .onChange(of: state.offsetSide) { _ in state.updateLivePreview() }
        .onChange(of: state.holeOffsetDistance) { _ in state.updateLivePreview() }
        .onChange(of: state.holeDiameter) { _ in state.updateLivePreview() }
        .onChange(of: state.holeSpacing) { _ in state.updateLivePreview() }
        .onChange(of: state.holePattern) { _ in state.updateLivePreview() }
        .onChange(of: state.holeCornerBehavior) { _ in state.updateLivePreview() }
        .onChange(of: state.holeSide) { _ in state.updateLivePreview() }
        .onChange(of: state.holeRowSpacing) { _ in state.updateLivePreview() }
        .onChange(of: state.holeEnableVariableSpacing) { _ in state.updateLivePreview() }
        .onChange(of: state.holeEnableProximityFilter) { _ in state.updateLivePreview() }
        .onChange(of: state.holeEnableCornerInterpolation) { _ in state.updateLivePreview() }
        .alert("Enter Text", isPresented: $state.showTextInputDialog) {
            TextField("Text to insert", text: $state.textInputString)
            Button("OK") {
                if let insert = state.pendingTextInsert {
                    state.applyAddText(text: state.textInputString, insert: insert, height: state.pendingTextHeight)
                }
                state.textInputString = "Label"
            }
            Button("Cancel", role: .cancel) {
                state.textInputString = "Label"
            }
        } message: {
            Text("Enter the text to place in the bounding box.")
        }
    }
    
    @ViewBuilder
    private var hotkeyBindings: some View {
        ZStack {
            Button("") { state.currentTool = .select }.keyboardShortcut("v", modifiers: [])
            Button("") { state.chainSelectionEnabled.toggle() }.keyboardShortcut("a", modifiers: [])
            Button("") { state.currentTool = .pan }.keyboardShortcut("h", modifiers: [])
            Button("") { state.currentTool = .offset }.keyboardShortcut("o", modifiers: [])
            Button("") { state.currentTool = .addHoles }.keyboardShortcut("s", modifiers: [])
            Button("") { state.currentTool = .cleanup }.keyboardShortcut("j", modifiers: [])
            Button("") { state.currentTool = .measure }.keyboardShortcut("m", modifiers: [])
            Button("") {
                state.selectedHandles.removeAll()
                state.selectedFaces3D.removeAll()
            }.keyboardShortcut(.escape, modifiers: [])
            Button("") { state.undo() }.keyboardShortcut("z", modifiers: [.command])
            Button("") { state.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") { state.deleteSelectedEntities() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { state.deleteSelectedEntities() }.keyboardShortcut(.deleteForward, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
    
    private func runExportPanel(format: String) {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Drawing"
        savePanel.nameFieldStringValue = "drawing.\(format)"
        savePanel.allowedContentTypes = [UTType(filenameExtension: format)].compactMap { $0 }
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            state.exportFile(to: url, format: format, selectedOnly: exportSelectedOnly)
        }
    }
    
    private func importFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [
            UTType(filenameExtension: "dxf"),
            UTType(filenameExtension: "step"),
            UTType(filenameExtension: "stp"),
            UTType(filenameExtension: "svg"),
            UTType(filenameExtension: "stch")
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
            state.saveProject(to: current)
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
        
        func setup(window: NSWindow, state: AppState) {
            self.window = window
            self.state = state
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
            .background(isEnabled ? (isPressed ? Color.accent_hover : (isHovered ? Color.status_warn.opacity(0.8) : Color.accent)) : Color.bg_input)
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

struct LinkButtonStyle: ButtonStyle {
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isHovered ? Color.status_warn : Color.accent)
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
            DisclosureGroup(isExpanded: $isSelectionExpanded) {
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
                        }
                        .padding(.vertical, 4)
                        
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
                                
                                Button("Assign") {
                                    state.assignSelectedToLayer(customLayerName)
                                    customLayerName = ""
                                    selectedExistingLayer = ""
                                }
                                .buttonStyle(BorderedButtonStyle())
                                .disabled(customLayerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                HStack {
                    Image(systemName: "cursorarrow.and.square.on.square.dashed")
                        .foregroundColor(Color.accent)
                    Text("SELECTION")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    
                    Spacer()
                    
                    Button(action: {
                        state.chainSelectionEnabled.toggle()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                            Text("Chain")
                                .font(PlasticityFont.label)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(state.chainSelectionEnabled ? Color.accent.opacity(0.2) : Color.bg_input)
                        .foregroundColor(state.chainSelectionEnabled ? Color.accent : Color.text_secondary)
                        .cornerRadius(3)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(state.chainSelectionEnabled ? Color.accent : Color.border_strong, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Toggle Chain Selection")
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isSelectionExpanded.toggle()
                }
            }
            .accentColor(Color.accent)
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
        if state.currentTool == .offset || state.currentTool == .cleanup || state.currentTool == .measure || state.currentTool == .sketchLine || state.currentTool == .sketchCircle || state.currentTool == .sketchRectangle || state.currentTool == .sketchText {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ACTIVE TOOL DETAILS")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_secondary)
                        .tracking(0.5)
                    Spacer()
                    Toggle("Learn", isOn: $state.isLearnModeEnabled)
                        .toggleStyle(.checkbox)
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_secondary)
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
                            
                            Text("Side")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            
                            Picker("", selection: $state.offsetSide) {
                                Text("Left").tag("left")
                                Text("Right").tag("right")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            
                            Button("Apply Offset") {
                                state.applyOffset()
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                            .disabled(state.selectedHandles.isEmpty)
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
                            
                            Button("Apply BBox Offset") {
                                state.applyBBoxOffset()
                            }
                            .buttonStyle(PlasticityButtonStyle(isEnabled: true))
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
                        
                        Button("Apply Join/Cleanup") {
                            state.applyCleanup()
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: state.currentFilePath != nil))
                        .disabled(state.currentFilePath == nil)
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
                        }
                    }
                } else if state.currentTool == .sketchLine {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LINE SKETCH TOOL")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.accent)
                        if state.isLearnModeEnabled {
                            Text("Click and drag on the canvas to draw a line segment. Dimensions are automatically measured and saved.")
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
                            Text("Click at center and drag outward to draw a circle. Radius is automatically measured and saved.")
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
                        
                        if state.isLearnModeEnabled {
                            Text("Click and drag corner-to-corner. Corners are filleted using the radius specified above.")
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
                            Text("Click and drag a bounding box on the canvas. When you release, you can type the text to place inside the box.")
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

    @ViewBuilder
    private var holesSewingSection: some View {
        if state.currentTool == .select || state.currentTool == .addHoles {
            DisclosureGroup(isExpanded: $isHolesSewingExpanded) {
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
                    }
                    
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
                    }
                    
                    HStack {
                        Text("Corner Behavior")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_primary)
                        Spacer()
                        Picker("", selection: $state.holeCornerBehavior) {
                            Text("Keep").tag("keep")
                            Text("Step").tag("step")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 120)
                    }
                    
                    HStack {
                        Text("Side")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_primary)
                        Spacer()
                        Picker("", selection: $state.holeSide) {
                            Text("Left").tag("left")
                            Text("Right").tag("right")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 120)
                    }
                    
                    HStack {
                        Text("Row Spacing (mm)")
                            .font(PlasticityFont.label)
                            .foregroundColor(Color.text_primary)
                        Spacer()
                        TextField("Row Spacing", value: $state.holeRowSpacing, format: .number)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding(4)
                            .frame(width: 80)
                            .background(Color.bg_input)
                            .cornerRadius(4)
                            .foregroundColor(Color.text_primary)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                    }
                    
                    Toggle("Variable Spacing", isOn: $state.holeEnableVariableSpacing)
                        .toggleStyle(.checkbox)
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_primary)
                    
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
                            Text("/")
                            TextField("Max", value: $state.holeVariableSpacingMax, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 45)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                        }
                        .padding(.leading, 8)
                    }
                    
                    Toggle("Proximity Filter", isOn: $state.holeEnableProximityFilter)
                        .toggleStyle(.checkbox)
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_primary)
                    
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
                        }
                        .padding(.leading, 8)
                    }
                    
                    Toggle("Line Proximity Filter", isOn: $state.holeEnableLineProximityFilter)
                        .toggleStyle(.checkbox)
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_primary)
                    
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
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding(.vertical, 4)
                
                Button("Apply Sewing Holes") {
                    state.applySewingHoles()
                }
                .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                .disabled(state.selectedHandles.isEmpty)
            } label: {
                HStack {
                    Image(systemName: "circle.dashed")
                        .foregroundColor(Color.accent)
                    Text("HOLES SEWING")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isHolesSewingExpanded.toggle()
                }
            }
            .accentColor(Color.accent)
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var paperFoldingSection: some View {
        if state.currentTool == .select {
            DisclosureGroup(isExpanded: $isPaperFoldingExpanded) {
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
                            TextField("Height", value: $glueTabHeight, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 80)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                        }
                        
                        HStack {
                            Text("Tab Type")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            Picker("", selection: $glueTabType) {
                                Text("Trapezoid").tag("trapezoid")
                                Text("Triangle").tag("triangle")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 140)
                        }
                        
                        HStack {
                            Text("Side")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            Picker("", selection: $glueTabSide) {
                                Text("Left").tag("left")
                                Text("Right").tag("right")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 140)
                        }
                        
                        Button("Apply Glue Tabs") {
                            state.applyGlueTabs(height: glueTabHeight, type: glueTabType, side: glueTabSide)
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                        .disabled(state.selectedHandles.isEmpty)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                HStack {
                    Image(systemName: "scissors")
                        .foregroundColor(Color.accent)
                    Text("PAPER FOLDING")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isPaperFoldingExpanded.toggle()
                }
            }
            .accentColor(Color.accent)
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var patterningSection: some View {
        if state.currentTool == .select {
            DisclosureGroup(isExpanded: $isPatterningExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GRID PATTERN")
                            .font(PlasticityFont.label)
                            .fontWeight(.bold)
                            .foregroundColor(Color.accent)
                        
                        HStack {
                            Text("Columns / Rows")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            TextField("Cols", value: $gridCols, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 45)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                            Text("x")
                            TextField("Rows", value: $gridRows, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 45)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                        }
                        
                        HStack {
                            Text("Spacing Col / Row")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            TextField("Col Sp", value: $gridColSpacing, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 50)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                            Text("/")
                            TextField("Row Sp", value: $gridRowSpacing, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 50)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                        }
                        
                        Button("Apply Grid Pattern") {
                            state.applyPatternGrid(columns: gridCols, rows: gridRows, colSpacing: gridColSpacing, rowSpacing: gridRowSpacing)
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                        .disabled(state.selectedHandles.isEmpty)
                    }
                    
                    Divider().background(Color.border_subtle)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PATH PATTERN")
                            .font(PlasticityFont.label)
                            .fontWeight(.bold)
                            .foregroundColor(Color.accent)
                        
                        HStack {
                            Text("Path Handle")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            TextField("Handle", text: $pathHandle)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 80)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                        }
                        
                        HStack {
                            Text("Spacing (mm)")
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_secondary)
                            Spacer()
                            TextField("Spacing", value: $pathPatternSpacing, format: .number)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(4)
                                .frame(width: 80)
                                .background(Color.bg_input)
                                .cornerRadius(4)
                                .foregroundColor(Color.text_primary)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                        }
                        
                        Button("Apply Path Pattern") {
                            state.applyPatternPath(pathHandle: pathHandle, spacing: pathPatternSpacing)
                        }
                        .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty && !pathHandle.isEmpty))
                        .disabled(state.selectedHandles.isEmpty || pathHandle.isEmpty)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                HStack {
                    Image(systemName: "square.grid.3x3")
                        .foregroundColor(Color.accent)
                    Text("PATTERNING")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isPatterningExpanded.toggle()
                }
            }
            .accentColor(Color.accent)
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var textPlacingSection: some View {
        if state.currentTool == .select || state.currentTool == .sketchText {
            DisclosureGroup(isExpanded: $isTextPlacingExpanded) {
                VStack(alignment: .leading, spacing: 8) {
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
                    }
                    
                    Button("Place Text") {
                        state.applyAddText(text: textString, insert: CGPoint(x: textInsertX, y: textInsertY), height: textHeight)
                    }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: !textString.isEmpty))
                    .disabled(textString.isEmpty)
                }
                .padding(.vertical, 4)
            } label: {
                HStack {
                    Image(systemName: "textformat")
                        .foregroundColor(Color.accent)
                    Text("TEXT PLACING")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isTextPlacingExpanded.toggle()
                }
            }
            .accentColor(Color.accent)
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var referenceImageSection: some View {
        if state.currentTool == .select {
            DisclosureGroup(isExpanded: $isReferenceImageExpanded) {
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
                .padding(.vertical, 4)
            } label: {
                HStack {
                    Image(systemName: "photo")
                        .foregroundColor(Color.accent)
                    Text("REFERENCE IMAGE")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isReferenceImageExpanded.toggle()
                }
            }
            .accentColor(Color.accent)
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var layersSection: some View {
        if state.currentTool == .select {
            DisclosureGroup(isExpanded: $isLayersExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if state.layers.isEmpty {
                        Text("No layers")
                            .font(PlasticityFont.body)
                            .foregroundColor(Color.text_muted)
                            .padding(.vertical, 4)
                    } else {
                        ForEach($state.layers) { $layer in
                            HStack(spacing: 8) {
                                Button(action: {
                                    layer.visible.toggle()
                                }) {
                                    Image(systemName: layer.visible ? "eye" : "eye.slash")
                                        .font(.system(size: 11))
                                        .foregroundColor(layer.visible ? Color.text_primary : Color.text_muted)
                                }
                                .buttonStyle(PlainButtonStyle())
                                
                                Circle()
                                    .fill(layer.color)
                                    .frame(width: 8, height: 8)
                                
                                Text(layer.name)
                                    .font(PlasticityFont.body)
                                    .foregroundColor(layer.visible ? Color.text_primary : Color.text_muted)
                                
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                HStack {
                    Image(systemName: "square.3.layers.3d")
                        .foregroundColor(Color.accent)
                    Text("LAYERS")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isLayersExpanded.toggle()
                }
            }
            .accentColor(Color.accent)
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var importSettingsSection: some View {
        if state.currentTool == .select {
            DisclosureGroup(isExpanded: $isImportSettingsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Consolidate SVG Strokes", isOn: $state.consolidateSvgStrokes)
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_primary)
                        .toggleStyle(.checkbox)
                }
                .padding(.vertical, 4)
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundColor(Color.accent)
                    Text("IMPORT SETTINGS")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                        .tracking(0.5)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isImportSettingsExpanded.toggle()
                }
            }
            .accentColor(Color.accent)
            .padding(8)
            .background(Color.bg_input.opacity(0.4))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_subtle, lineWidth: 1))
        }
    }
}

extension ContentView {
    @ViewBuilder
    private var leftToolbar: some View {
        VStack(spacing: 4) {
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .padding(.vertical, 12)
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    // Mode Toggle Buttons
                    ModeButton(mode: .twoD, systemName: "square.on.square", help: "2D Editor", state: state)
                    ModeButton(mode: .threeD, systemName: "cube", help: "3D STEP Importer", state: state)
                    ModeButton(mode: .batch, systemName: "square.grid.2x2", help: "Batch Mode", state: state)
                    
                    Divider()
                        .background(Color.border_subtle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    
                    if state.activeMode == .twoD {
                        // Show 2D tools only when in 2D mode
                        let mainTools: [TwoDTool] = [.select, .pan, .offset, .addHoles, .cleanup, .measure]
                        ForEach(mainTools, id: \.self) { tool in
                            ToolButton(tool: tool, state: state)
                        }
                        
                        Divider()
                            .background(Color.border_subtle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                        
                        let isShapeActive = state.currentTool == .sketchLine || state.currentTool == .sketchCircle || state.currentTool == .sketchRectangle || state.currentTool == .sketchText
                        Button(action: {
                            isShapesExpanded.toggle()
                        }) {
                            HStack(spacing: 0) {
                                Image(systemName: "triangle")
                                    .font(.system(size: 14))
                                Image(systemName: isShapesExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8))
                                    .padding(.leading, 2)
                            }
                            .frame(width: 28, height: 24)
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .background(isShapeActive ? Color.bg_selected.opacity(0.6) : (isShapesHovered ? Color.status_warn.opacity(0.15) : Color.clear))
                        .foregroundColor(isShapeActive ? Color.accent : (isShapesHovered ? Color.status_warn : Color.text_secondary))
                        .help("Shapes Sketching")
                        .onHover { hover in
                            isShapesHovered = hover
                        }
                        
                        if isShapesExpanded || isShapeActive {
                            VStack(spacing: 2) {
                                let shapeTools: [TwoDTool] = [.sketchLine, .sketchCircle, .sketchRectangle, .sketchText]
                                ForEach(shapeTools, id: \.self) { tool in
                                    ShapeToolButton(tool: tool, state: state)
                                }
                            }
                            .padding(.vertical, 4)
                            .background(Color.bg_panel.opacity(0.5))
                            .cornerRadius(4)
                        }
                    }
                    
                    Spacer()
                    
                    // Project Save/Load Buttons
                    ToolbarHoverButton(systemName: "folder", help: "Open Project (.stch)") {
                        loadProject()
                    }
                    
                    ToolbarHoverButton(systemName: "square.and.arrow.down.on.square", help: "Save Project (.stch)", disabled: state.currentFilePath == nil) {
                        saveProject()
                    }
                    
                    // Add Import File Button at bottom of left toolbar
                    ToolbarHoverButton(systemName: "square.and.arrow.down", help: "Import DXF / STEP / SVG File") {
                        importFile()
                    }
                    
                    // Add Export File Button below Import Button
                    ToolbarHoverButton(systemName: "square.and.arrow.up", help: "Quick Export DXF", disabled: state.currentFilePath == nil) {
                        showExportDialog = true
                    }
                }
            }
        }
        .frame(width: 48)
        .background(Color.bg_panel)
        .border(Color.border_subtle, width: 1)
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
                
                // Top Toolbar (always visible in 2D mode)
                HStack(spacing: 16) {
                    Button(action: {
                        WindowManager.shared.createNewDocument(fromWindow: NSApp.keyWindow)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.badge.plus")
                            Text("New")
                                .font(PlasticityFont.label)
                        }
                        .foregroundColor(Color.text_primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.bg_input)
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("New File (⌘N)")
                    
                    Button(action: {
                        state.canvasScale = 1.0
                        state.canvasOffset = .zero
                    }) {
                        Image(systemName: "house.fill")
                            .foregroundColor(Color.text_primary)
                            .padding(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Recenter View")
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.bg_panel)
                .border(width: 1, edges: [.bottom], color: Color.border_subtle)
                
                // Main 2D Viewport
                ZStack {
                    if state.svgContent != nil || state.refImage != nil {
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
                    if state.isProcessing {
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
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    let group = DispatchGroup()
                    var urls: [URL] = []
                    let lock = NSLock()
                    
                    for provider in providers {
                        group.enter()
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            if let fileUrl = url {
                                lock.lock()
                                urls.append(fileUrl)
                                lock.unlock()
                            }
                            group.leave()
                        }
                    }
                    
                    group.notify(queue: .main) {
                        if !urls.isEmpty {
                            state.importFiles(urls)
                        }
                    }
                    return true
                }
            }
            .frame(maxWidth: .infinity)
            
            // Right Panel (240px wide)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        selectionSection
                        dimensionEditorSection
                        activeToolDetailsSection
                        holesSewingSection
                        paperFoldingSection
                        patterningSection
                        textPlacingSection
                        referenceImageSection
                        layersSection
                        importSettingsSection
                    }
                    .padding(14)
                }
                
                // Bottom-anchored Export Settings (Always visible)
                Divider().background(Color.border_subtle)
                
                VStack(alignment: .leading, spacing: 8) {
                    DisclosureGroup(isExpanded: $isExportSettingsExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $exportFormat) {
                                Text("AutoCAD DXF (.dxf)").tag("dxf")
                                Text("Scalable Vector Graphics (.svg)").tag("svg")
                                Text("Document PDF (.pdf)").tag("pdf")
                                Text("Raster Image (.png)").tag("png")
                            }
                            .pickerStyle(DefaultPickerStyle())
                            .labelsHidden()
                            
                            Toggle("Export Selected Only", isOn: $exportSelectedOnly)
                                .font(PlasticityFont.label)
                                .foregroundColor(Color.text_primary)
                                .toggleStyle(.checkbox)
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(Color.accent)
                            Text("EXPORT SETTINGS")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_primary)
                                .tracking(0.5)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isExportSettingsExpanded.toggle()
                        }
                    }
                    .accentColor(Color.accent)
                    
                    Button("Export...") {
                        runExportPanel(format: exportFormat)
                    }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: state.currentFilePath != nil))
                    .disabled(state.currentFilePath == nil)
                }
                .padding(12)
                .background(Color.bg_panel)
            }
            .frame(width: 240)
            .background(Color.bg_panel)
            .border(Color.border_subtle, width: 1)
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
                if state.isProcessing {
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
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                let group = DispatchGroup()
                var urls: [URL] = []
                let lock = NSLock()
                
                for provider in providers {
                    group.enter()
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let fileUrl = url {
                            lock.lock()
                            urls.append(fileUrl)
                            lock.unlock()
                        }
                        group.leave()
                    }
                }
                
                group.notify(queue: .main) {
                    if !urls.isEmpty {
                        state.importFiles(urls)
                    }
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
            
            HStack {
                Button(action: {
                    state.isLogTrayExpanded.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: state.isLogTrayExpanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10))
                        Text("LOGS (\(state.logEntries.count))")
                            .font(PlasticityFont.label)
                    }
                    .foregroundColor(Color.text_secondary)
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                Text("MODE: \(state.activeMode == .twoD ? "2D DXF EDITOR" : "3D STEP IMPORTER")")
                    .font(PlasticityFont.label)
                    .foregroundColor(Color.accent)
                
                Spacer()
                
                if let fileUrl = state.currentFilePath {
                    Text(fileUrl.lastPathComponent)
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_secondary)
                } else {
                    Text("No file loaded")
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_muted)
                }
            }
            .frame(height: 24)
            .padding(.horizontal, 12)
            .background(Color.bg_panel)
            .border(Color.border_subtle, width: 1)
        }
    }
}