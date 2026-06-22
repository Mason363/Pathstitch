import SwiftUI
import AppKit

// MARK: - NSEvent → KeyCombo

extension KeyCombo {
    /// Builds a combo from a raw key event, mapping special keys to tokens.
    init?(event: NSEvent) {
        var key: String? = nil
        switch event.keyCode {
        case 53: key = "escape"
        case 51: key = "delete"
        case 117: key = "deleteForward"
        case 36, 76: key = "return"
        case 48: key = "tab"
        case 49: key = "space"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        default:
            if let chars = event.charactersIgnoringModifiers?.lowercased(),
               let c = chars.first, c.isLetter || c.isNumber || "`-=[]\\;',./".contains(c) {
                key = String(c)
            }
        }
        guard let resolved = key else { return nil }
        let f = event.modifierFlags
        self.init(key: resolved,
                  command: f.contains(.command),
                  shift: f.contains(.shift),
                  option: f.contains(.option),
                  control: f.contains(.control))
    }
}

// MARK: - Key recorder (AppKit first-responder capture)

private struct KeyRecorder: NSViewRepresentable {
    var onCapture: (KeyCombo) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onCapture = onCapture
        v.onCancel = onCancel
        return v
    }
    func updateNSView(_ nsView: CaptureView, context: Context) {
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    }

    final class CaptureView: NSView {
        var onCapture: ((KeyCombo) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?(); return }   // Esc cancels recording
            if let combo = KeyCombo(event: event) { onCapture?(combo) }
            else { NSSound.beep() }
        }
        // Capture combos that the responder chain would treat as equivalents.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if let combo = KeyCombo(event: event) { onCapture?(combo); return true }
            return false
        }
    }
}

// MARK: - Preferences window (MAS-72)

/// The dedicated Preferences/Settings panel (⌘,). Tabs: General (theme, icon,
/// import), Shortcuts (fully customizable keybinds), and About.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPrefsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsPrefsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AboutPrefsTab()
                .tabItem { Label("About", systemImage: "heart") }
        }
        .frame(width: 580, height: 560)
    }
}

private struct GeneralPrefsTab: View {
    @AppStorage(SettingsKeys.theme) private var themeRaw = AppTheme.dark.rawValue
    @AppStorage(SettingsKeys.icon) private var iconChoice = "auto"

    // Per-format Finder preview toggles (MAS-155). Stored in the shared app-group
    // suite so the QuickLook extensions read the same flags; default on.
    private static let qlStore = UserDefaults(suiteName: "group.com.chen.Pathstitch")
    @AppStorage("quicklook.preview.enabled.dxf",  store: qlStore) private var previewDXF = true
    @AppStorage("quicklook.preview.enabled.step", store: qlStore) private var previewSTEP = true
    @AppStorage("quicklook.preview.enabled.stch", store: qlStore) private var previewSTCH = true

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { t in Text(t.label).tag(t.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: themeRaw) { _ in
                    // Re-theme the entire app (all windows) immediately (MAS-72).
                    ThemeManager.apply(AppTheme(rawValue: themeRaw))
                }

                Picker("App Icon", selection: $iconChoice) {
                    Text("Automatic").tag("auto")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: iconChoice) { _ in AppIconManager.refresh() }
            }

            Section("Import") {
                Toggle("Consolidate SVG Strokes", isOn: Binding(
                    get: { NSApp.activeAppState?.consolidateSvgStrokes ?? false },
                    set: { NSApp.activeAppState?.consolidateSvgStrokes = $0 }
                ))
            }

            Section("Finder Previews") {
                Toggle("DXF files (.dxf)", isOn: $previewDXF)
                Toggle("STEP files (.step, .stp)", isOn: $previewSTEP)
                Toggle("Pathstitch files (.stch)", isOn: $previewSTCH)
                Text("Show Quick Look previews and thumbnails in Finder for each format. Turn one off to let Finder use its default — Pathstitch stays out of the way for that file type.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("Toolbar") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tool Layout")
                        Text("Restore the sidebar, Shapes, and More-tools groups to their defaults.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Reset Toolbar") { ToolbarLayout.shared.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct ShortcutsPrefsTab: View {
    private let keybinds = KeybindStore.shared
    @State private var recordingId: String? = nil
    @State private var pendingConflict: PendingConflict? = nil

    struct PendingConflict: Identifiable {
        let id = UUID()
        let combo: KeyCombo
        let targetId: String
        let conflictTitle: String
    }

    private var categories: [String] {
        var seen: [String] = []
        for c in AppCommands.all where !seen.contains(c.category) { seen.append(c.category) }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(categories, id: \.self) { cat in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cat.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.text_secondary)
                                .padding(.bottom, 2)
                            ForEach(AppCommands.all.filter { $0.category == cat }) { cmd in
                                row(for: cmd)
                            }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Press a shortcut to rebind. Esc cancels. Conflicts prompt before overriding.")
                    .font(.system(size: 11))
                    .foregroundColor(.text_secondary)
                Spacer()
                Button("Reset All") { keybinds.resetAll(); recordingId = nil }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .alert(item: $pendingConflict) { conflict in
            Alert(
                title: Text("Shortcut In Use"),
                message: Text("“\(conflict.combo.displayString)” is already assigned to \(conflict.conflictTitle). Override it?"),
                primaryButton: .destructive(Text("Override")) {
                    keybinds.setCombo(conflict.combo, for: conflict.targetId)
                    recordingId = nil
                },
                secondaryButton: .cancel { recordingId = nil }
            )
        }
    }

    @ViewBuilder
    private func row(for cmd: AppCommand) -> some View {
        let combo = keybinds.combo(for: cmd.id)
        HStack {
            Image(systemName: cmd.icon.isEmpty ? "circle" : cmd.icon)
                .frame(width: 18)
                .foregroundColor(.text_secondary)
            Text(cmd.title)
                .font(.system(size: 13))
            Spacer()

            if recordingId == cmd.id {
                ZStack {
                    Text("Press keys…")
                        .font(.system(size: 12))
                        .foregroundColor(.accent)
                    KeyRecorder(
                        onCapture: { newCombo in attemptBind(newCombo, to: cmd.id) },
                        onCancel: { recordingId = nil }
                    )
                    .frame(width: 1, height: 1)
                }
                .frame(width: 110, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).stroke(Color.accent, lineWidth: 1))
            } else {
                Button {
                    recordingId = cmd.id
                } label: {
                    Text(combo.key.isEmpty ? "Unbound" : combo.displayString)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(combo.key.isEmpty ? .text_muted : .text_primary)
                        .frame(width: 90, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.bg_input))
                }
                .buttonStyle(.plain)
            }

            Button {
                keybinds.reset(id: cmd.id)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.text_secondary)
            .help("Reset to default")
        }
        .padding(.vertical, 3)
    }

    private func attemptBind(_ combo: KeyCombo, to id: String) {
        // No-op if unchanged.
        if keybinds.combo(for: id) == combo { recordingId = nil; return }
        if let conflict = keybinds.conflictingCommand(for: combo, excluding: id) {
            pendingConflict = PendingConflict(combo: combo, targetId: id, conflictTitle: conflict.title)
        } else {
            keybinds.setCombo(combo, for: id)
            recordingId = nil
        }
    }
}

private struct AboutPrefsTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "scissors")
                .font(.system(size: 44))
                .foregroundColor(.accent)
            Text("Pathstitch")
                .font(.system(size: 22, weight: .semibold))
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("Version \(version)")
                    .font(.system(size: 12))
                    .foregroundColor(.text_secondary)
            }
            Spacer()
            Text("Built with ❤️ by Mason Chen")
                .font(.system(size: 13))
                .foregroundColor(.text_secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App icon selection (MAS-72)

enum AppIconManager {
    /// The logo variant the user's icon choice resolves to right now ("auto"
    /// follows system appearance). Single source of truth so every in-app logo
    /// (welcome, About, alert icons) stays in sync with Settings ▸ App Icon
    /// (MAS-150).
    static func currentIcon() -> NSImage? {
        let choice = UserDefaults.standard.string(forKey: SettingsKeys.icon) ?? "auto"
        let useDark: Bool
        switch choice {
        case "light": useDark = false
        case "dark": useDark = true
        default:
            useDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        return NSImage(named: useDark ? "AppIconDark" : "AppIconLight")
    }

    /// Applies the user's icon choice to the dock/app icon.
    static func refresh() {
        NSApp.applicationIconImage = currentIcon()
    }
}
