import SwiftUI
import UniformTypeIdentifiers

struct BatchModeView: View {
    @Bindable var state: AppState
    
    @State private var bulkExportFormat = "dxf"
    @State private var bulkExportSelectedOnly = false
    @State private var namingOption: NamingOption = .original
    @State private var customBaseName = "BatchExport"
    
    @State private var isHolesExpanded = true
    @State private var isOffsetExpanded = false
    
    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)
    ]
    
    var body: some View {
        HStack(spacing: 0) {
            // Main Grid Area
            VStack(spacing: 0) {
                if state.batchItems.isEmpty {
                    // Empty state drop zone
                    VStack(spacing: 16) {
                        Image(systemName: "square.grid.2x2.dashed")
                            .font(.system(size: 48))
                            .foregroundColor(Color.text_muted)
                        
                        Text("DRAG & DROP MULTIPLE DXF FILES")
                            .font(PlasticityFont.header)
                            .foregroundColor(Color.text_secondary)
                            .tracking(0.5)
                        
                        Button("SELECT DXF FILES") {
                            selectBatchFiles()
                        }
                        .buttonStyle(BorderedButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.bg_base)
                } else {
                    // Scrollable Grid View
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(state.batchItems) { item in
                                BatchItemCard(state: state, item: item)
                            }
                        }
                        .padding(18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.bg_base)
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
                        state.importFilesToBatch(urls)
                    }
                }
                return true
            }
            
            // Right-hand Bulk Operations & Export Panel
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Header
                        Text("BATCH OPERATIONS")
                            .font(PlasticityFont.header)
                            .foregroundColor(Color.text_primary)
                            .padding(.bottom, 6)
                        
                        // Bulk Sewing Holes Accordion
                        DisclosureGroup(isExpanded: $isHolesExpanded) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Hole Diameter")
                                    Spacer()
                                    TextField("", value: $state.holeDiameter, format: .number)
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .frame(width: 50)
                                        .padding(4)
                                        .background(Color.bg_input)
                                        .cornerRadius(4)
                                        .multilineTextAlignment(.trailing)
                                }
                                
                                HStack {
                                    Text("Hole Spacing")
                                    Spacer()
                                    TextField("", value: $state.holeSpacing, format: .number)
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .frame(width: 50)
                                        .padding(4)
                                        .background(Color.bg_input)
                                        .cornerRadius(4)
                                        .multilineTextAlignment(.trailing)
                                }
                                
                                HStack {
                                    Text("Offset Dist.")
                                    Spacer()
                                    TextField("", value: $state.holeOffsetDistance, format: .number)
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .frame(width: 50)
                                        .padding(4)
                                        .background(Color.bg_input)
                                        .cornerRadius(4)
                                        .multilineTextAlignment(.trailing)
                                }
                                
                                Picker("Pattern", selection: $state.holePattern) {
                                    Text("Single").tag("single")
                                    Text("Saddle").tag("saddle")
                                }
                                
                                Button("Apply Holes to Selected") {
                                    state.massApplySewingHoles()
                                }
                                .buttonStyle(PlasticityButtonStyle(isEnabled: !state.batchItems.filter { $0.isSelected }.isEmpty))
                                .disabled(state.batchItems.filter { $0.isSelected }.isEmpty)
                                .padding(.top, 4)
                            }
                            .font(PlasticityFont.body)
                            .padding(.vertical, 4)
                        } label: {
                            HStack {
                                Image(systemName: "circle.dashed")
                                    .foregroundColor(Color.accent)
                                Text("BULK SEWING HOLES")
                                    .font(PlasticityFont.header)
                                    .foregroundColor(Color.text_primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { isHolesExpanded.toggle() }
                        }
                        
                        // Bulk Offset Accordion
                        DisclosureGroup(isExpanded: $isOffsetExpanded) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Offset Dist.")
                                    Spacer()
                                    TextField("", value: $state.offsetDistance, format: .number)
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .frame(width: 50)
                                        .padding(4)
                                        .background(Color.bg_input)
                                        .cornerRadius(4)
                                        .multilineTextAlignment(.trailing)
                                }
                                
                                Picker("Side", selection: $state.offsetSide) {
                                    Text("Left / Out").tag("left")
                                    Text("Right / In").tag("right")
                                }
                                
                                Button("Apply Offset to Selected") {
                                    state.massApplyOffset()
                                }
                                .buttonStyle(PlasticityButtonStyle(isEnabled: !state.batchItems.filter { $0.isSelected }.isEmpty))
                                .disabled(state.batchItems.filter { $0.isSelected }.isEmpty)
                                .padding(.top, 4)
                            }
                            .font(PlasticityFont.body)
                            .padding(.vertical, 4)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.and.down")
                                    .foregroundColor(Color.accent)
                                Text("BULK OFFSET")
                                    .font(PlasticityFont.header)
                                    .foregroundColor(Color.text_primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { isOffsetExpanded.toggle() }
                        }
                    }
                    .padding(14)
                }
                
                // Bottom-anchored Bulk Export panel
                Divider().background(Color.border_subtle)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("BULK EXPORT")
                        .font(PlasticityFont.header)
                        .foregroundColor(Color.text_primary)
                    
                    Picker("Format", selection: $bulkExportFormat) {
                        Text("DXF (.dxf)").tag("dxf")
                        Text("SVG (.svg)").tag("svg")
                        Text("PDF (.pdf)").tag("pdf")
                        Text("PNG (.png)").tag("png")
                    }
                    .pickerStyle(DefaultPickerStyle())
                    
                    Toggle("Export Selected Only", isOn: $bulkExportSelectedOnly)
                        .font(PlasticityFont.label)
                        .foregroundColor(Color.text_primary)
                        .toggleStyle(.checkbox)
                    
                    Picker("Naming", selection: $namingOption) {
                        Text("Original Names").tag(NamingOption.original)
                        Text("Custom Name + Index").tag(NamingOption.customIndex)
                    }
                    .pickerStyle(DefaultPickerStyle())
                    
                    if namingOption == .customIndex {
                        TextField("Folder & Base name", text: $customBaseName)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding(6)
                            .background(Color.bg_input)
                            .cornerRadius(4)
                            .foregroundColor(Color.text_primary)
                            .font(PlasticityFont.body)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border_strong, lineWidth: 1))
                    }
                    
                    Button("Export Batch...") {
                        runBatchExportPanel()
                    }
                    .buttonStyle(PlasticityButtonStyle(isEnabled: !state.batchItems.isEmpty))
                    .disabled(state.batchItems.isEmpty)
                    .padding(.top, 4)
                }
                .padding(12)
                .background(Color.bg_panel)
            }
            .frame(width: 240)
            .background(Color.bg_panel)
            .border(width: 1, edges: [.leading], color: Color.border_subtle)
        }
    }
    
    private func selectBatchFiles() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [UTType(filenameExtension: "dxf")].compactMap { $0 }
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        if openPanel.runModal() == .OK {
            state.importFilesToBatch(openPanel.urls)
        }
    }
    
    private func runBatchExportPanel() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Export Destination"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        
        if openPanel.runModal() == .OK, let folderURL = openPanel.url {
            state.exportBatch(
                toFolder: folderURL,
                namingOption: namingOption,
                customName: customBaseName,
                exportSelectedOnly: bulkExportSelectedOnly,
                format: bulkExportFormat
            )
        }
    }
}

// Mini card representing a single DXF in the grid
struct BatchItemCard: View {
    var state: AppState
    var item: BatchItem
    
    var body: some View {
        VStack(spacing: 0) {
            // Checkbox and delete top overlay bar
            HStack {
                Button(action: {
                    if let idx = state.batchItems.firstIndex(where: { $0.id == item.id }) {
                        state.batchItems[idx].isSelected.toggle()
                    }
                }) {
                    Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(item.isSelected ? Color.accent : Color.text_muted)
                        .font(.system(size: 14))
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                Button(action: {
                    state.batchItems.removeAll { $0.id == item.id }
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(Color.status_err)
                        .font(.system(size: 12))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(6)
            .background(Color.bg_panel)
            
            // DXF geometry Thumbnail Preview
            ZStack {
                Color.white
                
                // SVG rendering if loaded, or draw custom miniature SwiftUI paths
                if !item.entities.isEmpty {
                    BatchThumbnailCanvas(entities: item.entities)
                } else {
                    Text("No Geometry")
                        .font(PlasticityFont.label)
                        .foregroundColor(.gray)
                }
            }
            .frame(height: 120)
            .border(width: 1, edges: [.bottom, .top], color: Color.border_subtle)
            
            // Bottom Action Bar (Filename and Edit button)
            HStack(spacing: 8) {
                Text(item.originalName)
                    .font(PlasticityFont.label)
                    .foregroundColor(Color.text_primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                Button("Edit") {
                    // Enter 2D Editor
                    state.activeEditingBatchItem = item
                    
                    let activeURL = state.ensureActiveDXFFileExists()
                    try? FileManager.default.removeItem(at: activeURL)
                    try? FileManager.default.copyItem(at: item.fileURL, to: activeURL)
                    
                    state.currentFilePath = activeURL
                    state.reloadDXF()
                    state.activeMode = .twoD
                }
                .buttonStyle(LinkButtonStyle())
                .font(.system(size: 10, weight: .bold))
            }
            .padding(6)
            .background(Color.bg_panel)
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(item.isSelected ? Color.accent : Color.border_strong, lineWidth: 1)
        )
    }
}

// Lightweight 2D Thumbnail canvas rendering geometries of a batch item inside its cell
struct BatchThumbnailCanvas: View {
    var entities: [DXFEntity]
    
    var body: some View {
        GeometryReader { geo in
            let bounds = getBounds(entities)
            
            Canvas { context, size in
                let scaleX = (size.width - 16) / max(1.0, bounds.width)
                let scaleY = (size.height - 16) / max(1.0, bounds.height)
                let scale = min(scaleX, scaleY)
                
                let midX = bounds.midX
                let midY = bounds.midY
                
                func mapPt(_ x: Double, _ y: Double) -> CGPoint {
                    let sx = CGFloat(x - midX) * scale + size.width / 2.0
                    let sy = -CGFloat(y - midY) * scale + size.height / 2.0
                    return CGPoint(x: sx, y: sy)
                }
                
                for ent in entities {
                    var path = SwiftUI.Path()
                    if ent.type == "LINE", let s = ent.start, let e = ent.end {
                        path.move(to: mapPt(s[0], s[1]))
                        path.addLine(to: mapPt(e[0], e[1]))
                        context.stroke(path, with: .color(Color.text_primary), lineWidth: 1.2)
                    } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
                        let sc = mapPt(center[0], center[1])
                        let sr = CGFloat(radius) * scale
                        path.addEllipse(in: CGRect(x: sc.x - sr, y: sc.y - sr, width: sr * 2, height: sr * 2))
                        context.stroke(path, with: .color(Color.text_primary), lineWidth: 1.2)
                    } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius,
                              let sa = ent.start_angle, let ea = ent.end_angle {
                        let sc = mapPt(center[0], center[1])
                        let sr = CGFloat(radius) * scale
                        path.addArc(
                            center: sc,
                            radius: sr,
                            startAngle: Angle(degrees: -sa),
                            endAngle: Angle(degrees: -ea),
                            clockwise: true
                        )
                        context.stroke(path, with: .color(Color.text_primary), lineWidth: 1.2)
                    } else if let vertices = ent.vertices {
                        if vertices.count >= 2 {
                            path.move(to: mapPt(vertices[0][0], vertices[0][1]))
                            for i in 1..<vertices.count {
                                path.addLine(to: mapPt(vertices[i][0], vertices[i][1]))
                            }
                            if ent.closed == true {
                                path.closeSubpath()
                            }
                            context.stroke(path, with: .color(Color.text_primary), lineWidth: 1.2)
                        }
                    }
                }
            }
        }
    }
    
    private func getBounds(_ ents: [DXFEntity]) -> CGRect {
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        
        for ent in ents {
            if ent.type == "LINE", let s = ent.start, let e = ent.end {
                minX = min(minX, s[0], e[0])
                maxX = max(maxX, s[0], e[0])
                minY = min(minY, s[1], e[1])
                maxY = max(maxY, s[1], e[1])
            } else if ent.type == "CIRCLE", let center = ent.center, let radius = ent.radius {
                minX = min(minX, center[0] - radius)
                maxX = max(maxX, center[0] + radius)
                minY = min(minY, center[1] - radius)
                maxY = max(maxY, center[1] + radius)
            } else if ent.type == "ARC", let center = ent.center, let radius = ent.radius {
                minX = min(minX, center[0] - radius)
                maxX = max(maxX, center[0] + radius)
                minY = min(minY, center[1] - radius)
                maxY = max(maxY, center[1] + radius)
            } else if let vertices = ent.vertices {
                for v in vertices {
                    if v.count >= 2 {
                        minX = min(minX, v[0])
                        maxX = max(maxX, v[0])
                        minY = min(minY, v[1])
                        maxY = max(maxY, v[1])
                    }
                }
            }
        }
        
        if minX == Double.infinity {
            return CGRect(x: 0, y: 0, width: 100, height: 100)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
