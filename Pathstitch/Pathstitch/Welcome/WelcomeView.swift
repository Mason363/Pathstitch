import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct WelcomeView: View {
    @State private var state = WelcomeState()
    
    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar: 120px
            VStack(spacing: 20) {
                // App Icon / Logo & Version
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                    
                    Text("Pathstitch")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.text_primary)
                    
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    Text("v\(version)")
                        .font(.system(size: 10))
                        .foregroundColor(.text_secondary)
                }
                .padding(.top, 32)
                
                Divider()
                    .background(Color.border_subtle)
                    .padding(.horizontal, 12)
                
                // Sidebar Buttons
                VStack(spacing: 8) {
                    SidebarButton(title: "New File", iconName: "doc.badge.plus") {
                        WindowManager.shared.createNewDocument()
                    }
                    
                    SidebarButton(title: "Open File...", iconName: "folder") {
                        WindowManager.shared.openAnyFileWithDialog()
                    }
                }
                .padding(.horizontal, 8)
                
                Spacer()
            }
            .frame(width: 120)
            .background(Color.bg_panel)
            .border(width: 1, edges: [.trailing], color: .border_subtle)
            
            // Right Content Area
            VStack(spacing: 0) {
                // Recent Projects Card List
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent Projects")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.text_primary)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                    
                    if state.recentFiles.isEmpty {
                        // Empty State
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 36))
                                .foregroundColor(.text_secondary)
                            
                            Text("No Recent Projects")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.text_primary)
                            
                            Text("Your recently opened projects will appear here.")
                                .font(.system(size: 10))
                                .foregroundColor(.text_secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            ScrollViewReader { proxy in
                                LazyHStack(spacing: 16) {
                                    ForEach(Array(state.recentFiles.enumerated()), id: \.element.url) { idx, file in
                                        RecentFileCard(
                                            file: file,
                                            isSelected: state.selectedIndex == idx,
                                            state: state
                                        )
                                        .id(idx)
                                    }
                                }
                                .padding(.horizontal, 24)
                                .onChange(of: state.selectedIndex) { _, newValue in
                                    if let index = newValue {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            proxy.scrollTo(index, anchor: .center)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(height: 165)
                        .mask(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.05),
                                    .init(color: .black, location: 0.95),
                                    .init(color: .clear, location: 1)
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    }
                }
                .frame(maxHeight: .infinity)
                
                // Drop Zone (140px fixed height)
                WelcomeDropZone(state: state)
            }
            .background(Color.bg_base)
        }
        .frame(width: 880, height: 560)
        .onDrop(of: [.fileURL], delegate: WelcomeDropDelegate(state: state))
        .onAppear {
            state.refreshRecents()
        }
        .onReceive(NotificationCenter.default.publisher(for: .welcomeSelectNext)) { _ in
            state.selectNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .welcomeSelectPrevious)) { _ in
            state.selectPrevious()
        }
        .onReceive(NotificationCenter.default.publisher(for: .welcomeOpenSelected)) { _ in
            state.openSelected()
        }
    }
}

struct SidebarButton: View {
    let title: String
    let iconName: String
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(isHovered ? Color.bg_hover : Color.clear)
            .foregroundColor(isHovered ? .accent : .text_primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct RecentFileCard: View {
    let file: RecentFile
    let isSelected: Bool
    let state: WelcomeState
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail container
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.bg_panel)
                
                if let thumb = file.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Text("STCH")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.text_muted)
                }
                
                // Hover veil
                Color.black.opacity(isHovered ? 0.15 : 0.0)
                    .animation(.easeInOut(duration: 0.2), value: isHovered)
                
                // Missing badge / veil
                if !file.isAvailable {
                    Color.black.opacity(0.6)
                    Text("Missing")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.status_err.opacity(0.85))
                        .cornerRadius(4)
                }
            }
            .frame(width: 150, height: 110)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accent : (isHovered ? Color.border_strong : Color.border_subtle), lineWidth: isSelected ? 2.0 : 1.0)
            )
            .overlay(alignment: .topTrailing) {
                // Three-dot menu in the thumbnail's top-right corner (MAS-139).
                Menu {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    Button(role: .destructive) {
                        state.removeFromRecents(file)
                    } label: {
                        Label("Remove from Recent Projects", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(6)
                .opacity(isHovered ? 1.0 : 0.0)
                .help("More…")
            }
            .shadow(color: Color.black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 6 : 2, x: 0, y: 3)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
            
            // Details
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? .accent : .text_primary)
                    .lineLimit(1)
                
                Text(formatDate(file.modifiedDate))
                    .font(.system(size: 9))
                    .foregroundColor(.text_secondary)
            }
            .padding(.horizontal, 4)
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .onTapGesture {
            if let idx = state.recentFiles.firstIndex(where: { $0.url == file.url }) {
                state.selectedIndex = idx
            }
        }
        .onTapGesture(count: 2) {
            if file.isAvailable {
                WindowManager.shared.openDocument(url: file.url)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Open") {
                if file.isAvailable {
                    WindowManager.shared.openDocument(url: file.url)
                }
            }
            .disabled(!file.isAvailable)
            
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }

            Button("Remove from Recent Projects") {
                state.removeFromRecents(file)
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct WelcomeDropZone: View {
    @Bindable var state: WelcomeState
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(state.isDraggingOver ? Color.bg_selected : Color.bg_panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(state.isDraggingOver ? Color.accent : Color.border_subtle, style: StrokeStyle(lineWidth: 1, dash: state.isDraggingOver ? [] : [4]))
                )
            
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 28))
                    .foregroundColor(state.isDraggingOver ? .accent : .text_secondary)
                
                Text(state.isDraggingOver ? "Release to open in Pathstitch" : "Drop files to open")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(state.isDraggingOver ? .accent : .text_primary)
                
                Text("Supports .stch, .dxf, .step, .stl, .svg, .pdf, images")
                    .font(.system(size: 10))
                    .foregroundColor(.text_secondary)
            }
        }
        .frame(height: 140)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

struct WelcomeDropDelegate: DropDelegate {
    let state: WelcomeState
    
    func performDrop(info: DropInfo) -> Bool {
        state.isDraggingOver = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        // Collect ALL dropped files (the old code took only `.first`, so dropping
        // several onto the welcome screen opened only one — MAS-13).
        collectDroppedURLs(providers) { urls in
            guard !urls.isEmpty else { return }
            WindowManager.shared.openFilesDistributing(urls)
        }
        return true
    }
    
    func dropEntered(info: DropInfo) {
        state.isDraggingOver = true
    }
    
    func dropExited(info: DropInfo) {
        state.isDraggingOver = false
    }
}
