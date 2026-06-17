import AppKit
import SwiftUI

extension Notification.Name {
    static let welcomeSelectNext = Notification.Name("welcomeSelectNext")
    static let welcomeSelectPrevious = Notification.Name("welcomeSelectPrevious")
    static let welcomeOpenSelected = Notification.Name("welcomeOpenSelected")
}

class WelcomeWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // Escape key minimizes (a soft dismiss that keeps the app running).
            if event.keyCode == 53 {
                self.miniaturize(nil)
                return
            }
            // Cmd + W closes the window. Routed through performClose so the
            // delegate's windowWillClose runs — quitting the app if this is the
            // last window (MAS-138).
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
                self.performClose(nil)
                return
            }
            // Left Arrow
            if event.keyCode == 123 {
                NotificationCenter.default.post(name: .welcomeSelectPrevious, object: nil)
                return
            }
            // Right Arrow
            if event.keyCode == 124 {
                NotificationCenter.default.post(name: .welcomeSelectNext, object: nil)
                return
            }
            // Enter/Return
            if event.keyCode == 36 {
                NotificationCenter.default.post(name: .welcomeOpenSelected, object: nil)
                return
            }
        }
        super.sendEvent(event)
    }
}

class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let welcomeView = WelcomeView()
        let hostingController = NSHostingController(rootView: welcomeView)
        let window = WelcomeWindow(contentViewController: hostingController)

        window.setContentSize(NSSize(width: 880, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .pathstitchWindowBackground   // adaptive (MAS-72)

        self.init(window: window)
        window.delegate = self
        window.center()
    }

    /// Closing the welcome window when no document workspace is open quits the
    /// app — leaving a running-but-windowless app would be confusing (MAS-138).
    /// When a project is opened, `hideWelcomeWindow()` closes this window while a
    /// document window already exists, so the app stays alive.
    func windowWillClose(_ notification: Notification) {
        if !WindowManager.shared.hasOpenDocumentWindows {
            NSApp.terminate(nil)
        }
    }
}

