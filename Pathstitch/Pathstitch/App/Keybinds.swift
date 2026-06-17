import SwiftUI
import AppKit

// MARK: - Key combo

/// A serializable key combination: a base key token plus modifier flags.
/// The base key is a lowercased single character ("v", "z") or a special token
/// ("escape", "delete", "deleteForward", "return", "tab", "space"). (MAS-72)
struct KeyCombo: Codable, Equatable, Hashable {
    var key: String
    var command: Bool = false
    var shift: Bool = false
    var option: Bool = false
    var control: Bool = false

    var modifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    /// SwiftUI key equivalent, or nil if the token is unrepresentable.
    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "escape": return .escape
        case "delete": return .delete
        case "deleteForward": return .deleteForward
        case "return": return .return
        case "tab": return .tab
        case "space": return .space
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        default:
            if key.count == 1, let c = key.first { return KeyEquivalent(c) }
            return nil
        }
    }

    /// Human-readable representation, e.g. "⌘⇧Z", "V", "⎋".
    var displayString: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        s += Self.keyGlyph(key)
        return s
    }

    static func keyGlyph(_ key: String) -> String {
        switch key {
        case "escape": return "⎋"
        case "delete": return "⌫"
        case "deleteForward": return "⌦"
        case "return": return "⏎"
        case "tab": return "⇥"
        case "space": return "␣"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return key.uppercased()
        }
    }

    /// True when two combos collide (same key + same modifiers).
    func conflicts(with other: KeyCombo) -> Bool {
        key == other.key && command == other.command && shift == other.shift
            && option == other.option && control == other.control
    }
}

// MARK: - Command registry

/// A bindable command surfaced in the keybind editor (MAS-72) and the search
/// palette (MAS-53). `action` runs the command against the active document.
struct AppCommand: Identifiable {
    let id: String
    let title: String
    let icon: String          // SF Symbol, or "" for a generic dot
    let category: String
    let defaultCombo: KeyCombo
    let isToggle: Bool
    let action: @MainActor (AppState) -> Void

    /// Whether the command is meaningful in the app's current state. Used to
    /// dim/disable rows in the search palette.
    let isEnabled: @MainActor (AppState) -> Bool

    init(id: String, title: String, icon: String, category: String,
         defaultCombo: KeyCombo, isToggle: Bool = false,
         isEnabled: @escaping @MainActor (AppState) -> Bool = { _ in true },
         action: @escaping @MainActor (AppState) -> Void) {
        self.id = id
        self.title = title
        self.icon = icon
        self.category = category
        self.defaultCombo = defaultCombo
        self.isToggle = isToggle
        self.isEnabled = isEnabled
        self.action = action
    }
}

enum AppCommands {
    /// The full, ordered list of bindable commands. Adding a command here makes
    /// it appear automatically in Preferences and the search palette (MAS-72).
    static let all: [AppCommand] = [
        // — Tools —
        .init(id: "tool.select", title: "Select Tool", icon: "cursorarrow", category: "Tools",
              defaultCombo: KeyCombo(key: "v")) { $0.currentTool = .select },
        .init(id: "tool.pan", title: "Pan Tool", icon: "hand.raised", category: "Tools",
              defaultCombo: KeyCombo(key: "h")) { $0.currentTool = .pan },
        .init(id: "tool.move", title: "Move Tool", icon: "arrow.up.and.down.and.arrow.left.and.right", category: "Tools",
              defaultCombo: KeyCombo(key: "w")) { $0.currentTool = .move },
        .init(id: "tool.offset", title: "Offset Tool", icon: "arrow.up.and.down", category: "Tools",
              defaultCombo: KeyCombo(key: "o")) { $0.currentTool = .offset },
        .init(id: "tool.addHoles", title: "Add Holes Tool", icon: "circle.dashed", category: "Tools",
              defaultCombo: KeyCombo(key: "g")) { $0.currentTool = .addHoles },
        .init(id: "tool.cleanup", title: "Join / Cleanup Tool", icon: "sparkles", category: "Tools",
              defaultCombo: KeyCombo(key: "j")) { $0.currentTool = .cleanup },
        .init(id: "tool.measure", title: "Measure Tool", icon: "ruler", category: "Tools",
              defaultCombo: KeyCombo(key: "m")) { $0.currentTool = .measure },
        .init(id: "tool.dimension", title: "Dimension Tool", icon: "ruler.fill", category: "Tools",
              defaultCombo: KeyCombo(key: "d")) { $0.currentTool = .dimension },
        .init(id: "tool.scale", title: "Scale Tool", icon: "arrow.up.left.and.arrow.down.right", category: "Tools",
              defaultCombo: KeyCombo(key: "")) { $0.currentTool = .scale },
        .init(id: "tool.line", title: "Line Sketch", icon: "line.diagonal", category: "Tools",
              defaultCombo: KeyCombo(key: "l")) { $0.currentTool = .sketchLine },
        .init(id: "tool.circle", title: "Circle Sketch", icon: "circle", category: "Tools",
              defaultCombo: KeyCombo(key: "c")) { $0.currentTool = .sketchCircle },
        .init(id: "tool.rectangle", title: "Rectangle Sketch", icon: "rectangle", category: "Tools",
              defaultCombo: KeyCombo(key: "r")) { $0.currentTool = .sketchRectangle },
        .init(id: "tool.text", title: "Text Sketch", icon: "character.cursor.ibeam", category: "Tools",
              defaultCombo: KeyCombo(key: "t")) { $0.currentTool = .sketchText },
        .init(id: "tool.polygon", title: "Polygon Sketch", icon: "hexagon", category: "Tools",
              defaultCombo: KeyCombo(key: "")) { $0.currentTool = .sketchPolygon },
        .init(id: "tool.pen", title: "Pen Tool", icon: "pencil.tip", category: "Tools",
              defaultCombo: KeyCombo(key: "")) { $0.currentTool = .pen },
        .init(id: "tool.fillet", title: "Fillet Tool", icon: "square", category: "Tools",
              defaultCombo: KeyCombo(key: "k")) { $0.currentTool = .fillet },
        .init(id: "tool.chamfer", title: "Chamfer Tool", icon: "square", category: "Tools",
              defaultCombo: KeyCombo(key: "b")) { $0.currentTool = .chamfer },
        .init(id: "tool.convertLines", title: "Convert Lines Tool", icon: "scribble", category: "Tools",
              defaultCombo: KeyCombo(key: "e")) { $0.currentTool = .convertLines },
        .init(id: "tool.mirror", title: "Mirror Tool", icon: "flip.horizontal", category: "Tools",
              defaultCombo: KeyCombo(key: "i")) { $0.currentTool = .mirror },
        .init(id: "tool.trim", title: "Trim Tool", icon: "scissors.badge.ellipsis", category: "Tools",
              defaultCombo: KeyCombo(key: "")) { $0.currentTool = .trim },
        .init(id: "tool.paperFolding", title: "Paper Folding Tool", icon: "scissors", category: "Tools",
              defaultCombo: KeyCombo(key: "f")) { $0.currentTool = .paperFolding },
        .init(id: "tool.patterning", title: "Patterning Tool", icon: "square.grid.3x3", category: "Tools",
              defaultCombo: KeyCombo(key: "p")) { $0.currentTool = .patterning },

        // — Edit —
        .init(id: "edit.undo", title: "Undo", icon: "arrow.uturn.backward", category: "Edit",
              defaultCombo: KeyCombo(key: "z", command: true)) { $0.undo() },
        .init(id: "edit.redo", title: "Redo", icon: "arrow.uturn.forward", category: "Edit",
              defaultCombo: KeyCombo(key: "z", command: true, shift: true)) { $0.redo() },
        .init(id: "edit.delete", title: "Delete Selection", icon: "trash", category: "Edit",
              defaultCombo: KeyCombo(key: "delete"),
              isEnabled: { !$0.selectedHandles.isEmpty || $0.selectedMeasurement != nil }) { st in
            if st.selectedMeasurement != nil { st.deleteSelectedMeasurement() }
            else { st.deleteSelectedEntities() }
        },
        .init(id: "edit.flipH", title: "Flip Horizontal", icon: "flip.horizontal", category: "Edit",
              defaultCombo: KeyCombo(key: "h", command: true, shift: true),
              isEnabled: { !$0.selectedHandles.isEmpty }) { $0.reflectSelectedEntities(axis: "horizontal") },
        .init(id: "edit.flipV", title: "Flip Vertical", icon: "flip.horizontal.fill", category: "Edit",
              defaultCombo: KeyCombo(key: "j", command: true, shift: true),
              isEnabled: { !$0.selectedHandles.isEmpty }) { $0.reflectSelectedEntities(axis: "vertical") },
        .init(id: "edit.dashLines", title: "Convert Lines to Dashed", icon: "line.diagonal", category: "Edit",
              defaultCombo: KeyCombo(key: "x"),
              isEnabled: { $0.selectionHasConvertibleLines }) { $0.quickConvertSelectedLines(to: "dashed") },

        // — View / Toggles —
        .init(id: "view.grid", title: "Toggle Grid", icon: "grid", category: "View",
              defaultCombo: KeyCombo(key: "g"), isToggle: true) { $0.gridVisible.toggle() },
        .init(id: "view.snap", title: "Toggle Snapping", icon: "magnet", category: "View",
              defaultCombo: KeyCombo(key: "n"), isToggle: true) { $0.snapEnabled.toggle() },
        .init(id: "view.chainSelect", title: "Toggle Chain Selection", icon: "link", category: "View",
              defaultCombo: KeyCombo(key: "a"), isToggle: true) { $0.chainSelectionEnabled.toggle() },

        .init(id: "edit.duplicate", title: "Duplicate Selection", icon: "plus.square.on.square", category: "Edit",
              defaultCombo: KeyCombo(key: "d", command: true),
              isEnabled: { !$0.selectedHandles.isEmpty }) { $0.duplicateSelectedEntities() },

        // — View / Toggles —
        .init(id: "view.zoomFit", title: "Zoom to Fit", icon: "arrow.up.left.and.down.right.magnifyingglass", category: "View",
              defaultCombo: KeyCombo(key: "")) { $0.fitRequestToken += 1 },
        .init(id: "view.toggleLogs", title: "Toggle Log Tray", icon: "list.bullet.rectangle", category: "View",
              defaultCombo: KeyCombo(key: ""), isToggle: true) { $0.isLogTrayExpanded.toggle() },
        .init(id: "view.learnMode", title: "Toggle Learn Mode", icon: "graduationcap", category: "View",
              defaultCombo: KeyCombo(key: ""), isToggle: true) { $0.isLearnModeEnabled.toggle() },
        .init(id: "view.mode2D", title: "Switch to 2D Mode", icon: "square.on.square", category: "View",
              defaultCombo: KeyCombo(key: "")) { $0.activeMode = .twoD },
        .init(id: "view.mode3D", title: "Switch to 3D Mode", icon: "cube", category: "View",
              defaultCombo: KeyCombo(key: "")) { $0.activeMode = .threeD },

        // — File —
        .init(id: "file.new", title: "New File", icon: "doc.badge.plus", category: "File",
              defaultCombo: KeyCombo(key: "")) { _ in WindowManager.shared.createNewDocument(fromWindow: NSApp.keyWindow) },
        .init(id: "file.open", title: "Open Project…", icon: "folder", category: "File",
              defaultCombo: KeyCombo(key: "")) { _ in WindowManager.shared.openProjectWithDialog() },
        .init(id: "file.import", title: "Import…", icon: "square.and.arrow.down", category: "File",
              defaultCombo: KeyCombo(key: "")) { _ in WindowManager.shared.importFileWithDialog() },
        .init(id: "file.save", title: "Save Project", icon: "square.and.arrow.down.fill", category: "File",
              defaultCombo: KeyCombo(key: "")) { st in
            if let current = st.currentProjectPath { st.reconcileThenSave(to: current) }
            else { st.saveProjectWithDialog() }
        },
        .init(id: "file.saveAs", title: "Save Project As…", icon: "square.and.arrow.down.on.square", category: "File",
              defaultCombo: KeyCombo(key: "")) { $0.saveProjectWithDialog() },
        .init(id: "file.export", title: "Export…", icon: "square.and.arrow.up", category: "File",
              defaultCombo: KeyCombo(key: ""),
              isEnabled: { $0.currentFilePath != nil }) { $0.exportWithDialog() },
        .init(id: "file.startScreen", title: "Start Screen", icon: "house", category: "File",
              defaultCombo: KeyCombo(key: "")) { _ in WindowManager.shared.showWelcomeWindow() },
        .init(id: "image.clearRef", title: "Clear Reference Image", icon: "photo.badge.arrow.down", category: "File",
              defaultCombo: KeyCombo(key: ""),
              isEnabled: { $0.refImage != nil }) { st in st.refImage = nil; st.refImageBase64 = nil },

        // — App —
        .init(id: "app.search", title: "Search…", icon: "magnifyingglass", category: "App",
              defaultCombo: KeyCombo(key: "s")) { $0.showSearchPalette = true },
        .init(id: "app.preferences", title: "Preferences…", icon: "gearshape", category: "App",
              defaultCombo: KeyCombo(key: "")) { _ in
            // macOS 14+ renamed the Settings action; fall back for older systems.
            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        },
        .init(id: "app.documentation", title: "Documentation", icon: "questionmark.circle", category: "App",
              defaultCombo: KeyCombo(key: "")) { $0.openDocsToken += 1 },
    ]

    static func command(id: String) -> AppCommand? { all.first { $0.id == id } }
}

// MARK: - Store

/// Holds the user's keybind overrides, persisted to UserDefaults. Reads fall
/// back to each command's default. Drives the in-canvas hotkeys (ContentView),
/// the search palette (MAS-53) and the Preferences editor (MAS-72).
@MainActor @Observable
final class KeybindStore {
    static let shared = KeybindStore()

    private let storageKey = "pathstitch.keybinds.v1"
    private(set) var overrides: [String: KeyCombo] = [:]

    private init() { load() }

    func combo(for id: String) -> KeyCombo {
        if let o = overrides[id] { return o }
        return AppCommands.command(id: id)?.defaultCombo ?? KeyCombo(key: "")
    }

    /// The command currently bound to `combo`, excluding `excluding` — used to
    /// warn about duplicates before committing a rebind.
    func conflictingCommand(for combo: KeyCombo, excluding id: String) -> AppCommand? {
        for cmd in AppCommands.all where cmd.id != id {
            if self.combo(for: cmd.id).conflicts(with: combo) { return cmd }
        }
        return nil
    }

    /// Assigns a combo. Caller is responsible for resolving conflicts first;
    /// any prior owner of the same combo is left unbound to avoid duplicates.
    func setCombo(_ combo: KeyCombo, for id: String) {
        if let other = conflictingCommand(for: combo, excluding: id) {
            overrides[other.id] = KeyCombo(key: "")   // clear the loser
        }
        overrides[id] = combo
        save()
    }

    func reset(id: String) {
        overrides.removeValue(forKey: id)
        save()
    }

    func resetAll() {
        overrides.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data)
        else { return }
        overrides = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Theme (MAS-72)

enum SettingsKeys {
    static let theme = "pathstitch.theme"
    static let icon = "pathstitch.iconChoice"   // "auto" | "light" | "dark"
}

/// Single source of truth for applying the user's appearance choice across the
/// WHOLE app — document windows, the Settings panel, the Start screen and the
/// Help window — by setting `NSApp.appearance`. The adaptive Color tokens then
/// resolve to the right palette everywhere (MAS-72).
enum ThemeManager {
    static func currentTheme() -> AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.theme) ?? "") ?? .dark
    }

    @MainActor static func apply(_ theme: AppTheme? = nil) {
        let t = theme ?? currentTheme()
        switch t {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        AppIconManager.refresh()
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
