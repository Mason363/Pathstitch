import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Runs a toolbar item's action: tools switch the active tool, the rest are
/// one-shot operations on the current selection (MAS-99).
@MainActor
func executeToolbarItem(_ def: ToolbarItemDef, state: AppState) {
    switch def.kind {
    case .tool(let t):
        state.currentTool = t
        state.activeMeasureStart = nil
    case .flipH:
        state.reflectSelectedEntities(axis: "horizontal")
    case .flipV:
        state.reflectSelectedEntities(axis: "vertical")
    case .duplicate:
        state.duplicateSelectedEntities()
    }
}

/// Loads the dragged item id (a plain string) from a drop and runs `perform`.
@MainActor
func handleToolbarDrop(_ providers: [NSItemProvider], perform: @escaping (String) -> Void) -> Bool {
    guard let provider = providers.first else { return false }
    provider.loadObject(ofClass: NSString.self) { obj, _ in
        guard let s = obj as? String, !s.isEmpty else { return }
        DispatchQueue.main.async { perform(s) }
    }
    return true
}

/// Whether this item is "active" (its tool is the current tool).
@MainActor
private func isActiveItem(_ def: ToolbarItemDef, state: AppState) -> Bool {
    if case .tool(let t) = def.kind { return state.currentTool == t }
    return false
}

/// Command-drag provider — only starts a real drag while ⌘ is held, so a plain
/// click still just activates the tool (MAS-99).
private func commandDragProvider(_ id: String) -> NSItemProvider {
    if NSEvent.modifierFlags.contains(.command) {
        return NSItemProvider(object: id as NSString)
    }
    return NSItemProvider()   // no registered type ⇒ drop is a no-op
}

/// The right-click "Move to…" menu — a reliable path for every move the spec
/// allows, alongside Command-drag (MAS-99).
@MainActor
@ViewBuilder
private func toolbarMoveMenu(_ def: ToolbarItemDef, layout: ToolbarLayout) -> some View {
    Button("Move to Toolbar") { layout.move(def.id, to: .main) }
    Button("Move to More Tools") { layout.move(def.id, to: .extra) }
    if def.shapesOrigin {
        Button("Move to Shapes") { layout.move(def.id, to: .shapes) }
    }
    Divider()
    Button("Reset Toolbar Layout") { layout.resetToDefaults() }
}

/// Registers a sidebar tool button's frame for the guided tutorial, but only for
/// real tools (the flip/duplicate actions aren't tutorial targets).
private struct ToolButtonTutorialAnchor: ViewModifier {
    let kind: ToolbarItemKind
    func body(content: Content) -> some View {
        if case .tool(let t) = kind {
            content.tutorialAnchor(.tool(t))
        } else {
            content
        }
    }
}

/// An icon-only sidebar tool that can be Command-dragged to reorder or move it to
/// another container, and accepts a drop to position another item before it.
struct OrganizableToolButton: View {
    let def: ToolbarItemDef
    var state: AppState
    var layout: ToolbarLayout
    @State private var isHovered = false
    @State private var isTargeted = false

    var body: some View {
        let active = isActiveItem(def, state: state)
        Button(action: { executeToolbarItem(def, state: state) }) {
            Group {
                if case .tool(let t) = def.kind, t == .fillet || t == .chamfer {
                    CornerGlyph(rounded: t == .fillet)
                        .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: def.icon).font(.system(size: 14))
                }
            }
            .frame(width: 24, height: 24)
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            isTargeted ? Color.accent.opacity(0.25)
            : (active ? Color.bg_selected : (isHovered ? Color.accent.opacity(0.08) : Color.clear))
        )
        .foregroundColor(active ? Color.accent : (isHovered ? Color.accent_hover : Color.text_secondary))
        // Let the guided tutorial spotlight this tool when it lives in the sidebar.
        .modifier(ToolButtonTutorialAnchor(kind: def.kind))
        .help(def.title + "  (⌘-drag to rearrange)")
        .onHover { isHovered = $0 }
        .onDrag { commandDragProvider(def.id) }
        .onDrop(of: [UTType.text], isTargeted: $isTargeted) { providers in
            handleToolbarDrop(providers) { layout.move($0, before: def.id) }
        }
        .contextMenu { toolbarMoveMenu(def, layout: layout) }
    }
}

/// A labeled grid cell used inside the Shapes and More-tools flyouts. Same drag /
/// drop / menu affordances as the sidebar button (MAS-99).
struct OrganizableGridItem: View {
    let def: ToolbarItemDef
    var state: AppState
    var layout: ToolbarLayout
    var enabled: Bool
    /// Called after activation so the flyout can dismiss itself.
    var onActivate: () -> Void
    @State private var isTargeted = false

    var body: some View {
        let active = isActiveItem(def, state: state)
        Button(action: {
            executeToolbarItem(def, state: state)
            onActivate()
        }) {
            VStack(spacing: 4) {
                Image(systemName: def.icon).font(.system(size: 16))
                Text(def.title).font(.system(size: 9)).lineLimit(1)
            }
            .frame(width: 56, height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(isTargeted ? Color.accent.opacity(0.25) : (active ? Color.bg_selected : Color.bg_input.opacity(0.4)))
        .cornerRadius(6)
        .foregroundColor(active ? Color.accent : (enabled ? Color.text_primary : Color.text_muted))
        .disabled(!enabled)
        .help(def.title + "  (⌘-drag to rearrange)")
        .onDrag { commandDragProvider(def.id) }
        .onDrop(of: [UTType.text], isTargeted: $isTargeted) { providers in
            handleToolbarDrop(providers) { layout.move($0, before: def.id) }
        }
        .contextMenu { toolbarMoveMenu(def, layout: layout) }
    }
}

/// A near-square grid of organizable items for the Shapes / More-tools flyouts.
struct OrganizableToolGrid: View {
    var state: AppState
    var layout: ToolbarLayout
    let container: ToolbarContainer
    var onActivate: () -> Void

    private func enabled(_ def: ToolbarItemDef) -> Bool {
        switch def.kind {
        case .flipH, .flipV, .duplicate: return !state.selectedHandles.isEmpty
        case .tool: return true
        }
    }

    var body: some View {
        let items = layout.items(in: container)
        let n = max(items.count, 1)
        var c = 1
        // smallest c with c*c >= n (ceil(sqrt))
        let cols: Int = { while c * c < n { c += 1 }; return c }()
        let columns = Array(repeating: GridItem(.fixed(60), spacing: 8), count: cols)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { def in
                OrganizableGridItem(def: def, state: state, layout: layout,
                                    enabled: enabled(def), onActivate: onActivate)
            }
        }
        // Dropping into the empty area of the grid appends to this container
        // (respecting the Shapes-only constraint).
        .padding(4)
        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
            handleToolbarDrop(providers) { id in
                if layout.canPlace(id, in: container) { layout.move(id, to: container) }
            }
        }
    }
}
