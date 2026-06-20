import AppKit
import SwiftUI

/// Custom "About Pathstitch" window (MAS-149, MAS-142). Replaces the standard
/// AppKit about panel so we can surface the support link and — once Sparkle is
/// wired in — the version / check-for-updates controls in one place.
struct AboutView: View {
    @ObservedObject private var updater = UpdaterManager.shared

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)

            VStack(spacing: 4) {
                Text("Pathstitch")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.text_primary)

                Text(build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))")
                    .font(.system(size: 11))
                    .foregroundColor(.text_secondary)
            }

            Text("A native macOS CAD/CAM studio for leathercraft,\npattern making, and sewing.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundColor(.text_secondary)

            Divider().padding(.horizontal, 40)

            // Software update (MAS-142). The button and toggle both drive the
            // same Sparkle updater, so they always stay in sync.
            VStack(spacing: 8) {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Text("Check for Updates…")
                        .font(.system(size: 12, weight: .medium))
                }
                .disabled(!updater.canCheckForUpdates)

                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecks($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundColor(.text_secondary)
            }

            Divider().padding(.horizontal, 40)

            VStack(spacing: 6) {
                Text("Built with ❤️ by Mason Chen")
                    .font(.system(size: 11))
                    .foregroundColor(.text_secondary)

                Button {
                    if let url = URL(string: "https://buymeacoffee.com/masonchen") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 11))
                        Text("Buy me a coffee")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.accent)
                }
                .buttonStyle(.plain)
                .help("https://buymeacoffee.com/masonchen")
            }
        }
        .padding(28)
        .frame(width: 320)
        .background(Color.bg_base)
    }
}

class AboutWindowController: NSWindowController {
    convenience init() {
        let hostingController = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        window.title = "About Pathstitch"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .pathstitchWindowBackground
        window.setContentSize(NSSize(width: 320, height: 460))
        self.init(window: window)
        window.center()
    }
}
