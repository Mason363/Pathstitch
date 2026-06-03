import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var state = AppState()
    @State private var showExportDialog = false
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Toolbar (48px wide)
            VStack(spacing: 4) {
                ForEach(TwoDTool.allCases, id: \.self) { tool in
                    Button(action: {
                        state.currentTool = tool
                        if tool != .measure {
                            state.measureStartPoint = nil
                            state.measureEndPoint = nil
                            state.measuredDistanceMm = nil
                        }
                    }) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 14))
                            .frame(width: 24, height: 24)
                            .padding(10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(state.currentTool == tool ? Color.bg_selected : Color.clear)
                    .foregroundColor(state.currentTool == tool ? Color.accent : Color.text_secondary)
                    .help(tool.rawValue)
                }
                
                Spacer()
                
                // Add Import File Button at bottom of left toolbar
                Button(action: {
                    importDxf()
                }) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14))
                        .frame(width: 24, height: 24)
                        .padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(Color.text_secondary)
                .help("Import DXF File")
            }
            .frame(width: 48)
            .background(Color.bg_panel)
            .border(Color.border_subtle, width: 1)
            
            // Viewport & Status Bar
            VStack(spacing: 0) {
                // Main Viewport
                ZStack {
                    if state.svgContent != nil {
                        DxfCanvasView(state: state)
                    } else {
                        // Empty State Viewport (Plasticity Style)
                        VStack(spacing: 12) {
                            Image(systemName: "plus.square.dashed")
                                .font(.system(size: 32))
                                .foregroundColor(Color.text_muted)
                            
                            Text("DRAG & DROP DXF")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_secondary)
                                .tracking(0.5)
                            
                            Button("SELECT DXF FILE") {
                                importDxf()
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
                    guard let item = providers.first else { return false }
                    _ = item.loadObject(ofClass: URL.self) { url, _ in
                        if let fileUrl = url {
                            DispatchQueue.main.async {
                                state.loadFile(url: fileUrl)
                            }
                        }
                    }
                    return true
                }
                
                // Bottom Status Bar (24px tall)
                HStack {
                    Text(state.activeMode == .twoD ? "MODE: 2D DXF EDITOR" : "MODE: 3D STEP IMPORTER")
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
            .frame(maxWidth: .infinity)
            
            // Right Panel (240px wide)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Section 1: Selection
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SELECTION")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_secondary)
                                .tracking(0.5)
                            
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
                            }
                            
                            Divider().background(Color.border_subtle)
                        }
                        
                        // Section 2: Operations
                        VStack(alignment: .leading, spacing: 10) {
                            Text("OPERATIONS")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_secondary)
                                .tracking(0.5)
                            
                            if state.currentTool == .offset {
                                VStack(alignment: .leading, spacing: 8) {
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
                                }
                            } else if state.currentTool == .addHoles {
                                VStack(alignment: .leading, spacing: 8) {
                                    Group {
                                        Text("Offset Distance (mm)")
                                        TextField("Offset", value: $state.holeOffsetDistance, format: .number)
                                        
                                        Text("Hole Diameter (mm)")
                                        TextField("Diameter", value: $state.holeDiameter, format: .number)
                                        
                                        Text("Hole Spacing (mm)")
                                        TextField("Spacing", value: $state.holeSpacing, format: .number)
                                    }
                                    .font(PlasticityFont.label)
                                    .foregroundColor(Color.text_secondary)
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
                                    Picker("", selection: $state.holeSide) {
                                        Text("Left").tag("left")
                                        Text("Right").tag("right")
                                    }
                                    .pickerStyle(SegmentedPickerStyle())
                                    
                                    Text("Stitch Pattern")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_secondary)
                                    Picker("", selection: $state.holePattern) {
                                        Text("Single").tag("single")
                                        Text("Saddle").tag("saddle")
                                    }
                                    .pickerStyle(SegmentedPickerStyle())
                                    
                                    if state.holePattern == "saddle" {
                                        Text("Row Spacing (mm)")
                                            .font(PlasticityFont.label)
                                            .foregroundColor(Color.text_secondary)
                                        TextField("Row Spacing", value: $state.holeRowSpacing, format: .number)
                                            .textFieldStyle(PlainTextFieldStyle())
                                            .padding(6)
                                            .background(Color.bg_input)
                                            .cornerRadius(4)
                                            .foregroundColor(Color.text_primary)
                                            .font(PlasticityFont.body)
                                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                                    }
                                    
                                    Text("Corner Behavior")
                                        .font(PlasticityFont.label)
                                        .foregroundColor(Color.text_secondary)
                                    Picker("", selection: $state.holeCornerBehavior) {
                                        Text("Skip Corner").tag("skip")
                                        Text("Wrap Corner").tag("wrap")
                                    }
                                    .pickerStyle(SegmentedPickerStyle())
                                    
                                    Button("Apply Sewing Holes") {
                                        state.applySewingHoles()
                                    }
                                    .buttonStyle(PlasticityButtonStyle(isEnabled: !state.selectedHandles.isEmpty))
                                    .disabled(state.selectedHandles.isEmpty)
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
                            } else {
                                Text("Select an operation tool on left")
                                    .font(PlasticityFont.body)
                                    .foregroundColor(Color.text_muted)
                                    .padding(.vertical, 4)
                            }
                            
                            Divider().background(Color.border_subtle)
                        }
                        
                        // Section 3: Layers
                        VStack(alignment: .leading, spacing: 6) {
                            Text("LAYERS")
                                .font(PlasticityFont.header)
                                .foregroundColor(Color.text_secondary)
                                .tracking(0.5)
                            
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
                            
                            Divider().background(Color.border_subtle)
                        }
                    }
                    .padding(14)
                }
                
                Spacer()
                
                // Section 4: Export Panel (Fixed at Bottom of Sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Text("EXPORT OPTIONS")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_secondary)
                        .tracking(0.5)
                    
                    Button("Export Final DXF") {
                        showExportDialog = true
                    }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: state.currentFilePath != nil))
                    .disabled(state.currentFilePath == nil)
                }
                .padding(14)
                .background(Color.bg_panel)
                .border(Color.border_subtle, width: 1)
            }
            .frame(width: 240)
            .background(Color.bg_panel)
            .border(Color.border_subtle, width: 1)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color.bg_base)
        .font(PlasticityFont.body)
        .preferredColorScheme(.dark)
        // Bind hotkeys
        .background(
            Button("") { state.currentTool = .select }
                .keyboardShortcut("v", modifiers: [])
        )
        .background(
            Button("") { state.currentTool = .chainSelect }
                .keyboardShortcut("a", modifiers: [])
        )
        .background(
            Button("") { state.currentTool = .pan }
                .keyboardShortcut("h", modifiers: [])
        )
        .background(
            Button("") { state.currentTool = .offset }
                .keyboardShortcut("o", modifiers: [])
        )
        .background(
            Button("") { state.currentTool = .addHoles }
                .keyboardShortcut("s", modifiers: [])
        )
        .background(
            Button("") { state.currentTool = .cleanup }
                .keyboardShortcut("j", modifiers: [])
        )
        .background(
            Button("") { state.currentTool = .measure }
                .keyboardShortcut("m", modifiers: [])
        )
        .background(
            Button("") { state.selectedHandles.removeAll() }
                .keyboardShortcut(.escape, modifiers: [])
        )
        .fileExporter(isPresented: $showExportDialog, document: DXFExportDocument(fileURL: state.currentFilePath), contentType: .item, defaultFilename: "pathstitch_export.dxf") { result in
            switch result {
            case .success(let url):
                state.exportFinalDXF(to: url)
            case .failure(let error):
                state.errorMessage = "Export selection error: \(error.localizedDescription)"
            }
        }
    }
    
    private func importDxf() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [UTType(filenameExtension: "dxf")!].compactMap { $0 }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                state.loadFile(url: url)
            }
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

// Plasticity style buttons
struct PlasticityButtonStyle: ButtonStyle {
    var isEnabled: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PlasticityFont.body)
            .fontWeight(.medium)
            .foregroundColor(isEnabled ? Color.text_primary : Color.text_muted)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(isEnabled ? (configuration.isPressed ? Color.accent_hover : Color.accent) : Color.bg_input)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isEnabled ? Color.clear : Color.border_strong, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}
