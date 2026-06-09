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
            // Escape key
            if event.keyCode == 53 {
                self.miniaturize(nil)
                return
            }
            // Cmd + W
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
                self.miniaturize(nil)
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

class WelcomeWindowController: NSWindowController {
    convenience init() {
        let welcomeView = WelcomeView()
        let hostingController = NSHostingController(rootView: welcomeView)
        let window = WelcomeWindow(contentViewController: hostingController)
        
        window.setContentSize(NSSize(width: 880, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 13.0/255.0, green: 13.0/255.0, blue: 16.0/255.0, alpha: 1.0) // #0d0d10
        
        self.init(window: window)
        window.center()
    }
}

