import Foundation
import Combine
import Sparkle

/// Thin wrapper around Sparkle's standard updater so SwiftUI can drive
/// "Check for Updates" and the "check automatically" toggle, and so both the
/// About window and Preferences read/write the same state (MAS-142).
///
/// We start the updater at launch. With `SUEnableAutomaticChecks` left unset in
/// Info.plist, Sparkle shows its built-in permission prompt on the second
/// launch ("Check for updates automatically?" with a decline-forever option);
/// the user's choice is mirrored by `automaticallyChecksForUpdates`, which this
/// object exposes as a two-way binding. Settings live in UserDefaults, so they
/// survive an update that replaces the app bundle.
final class UpdaterManager: ObservableObject {
    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController

    /// True once the updater is ready to check (disables the button otherwise).
    @Published var canCheckForUpdates = false
    /// Mirrors Sparkle's automatic-check setting; both UIs bind to this.
    @Published var automaticallyChecksForUpdates = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: \.canCheckForUpdates, on: self)
            .store(in: &cancellables)
    }

    /// Manually check, showing Sparkle's UI (no-update / up-to-date dialogs).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Two-way binding for the "Automatically check for updates" toggle. Writing
    /// it updates Sparkle (and thus UserDefaults) and the published mirror.
    func setAutomaticallyChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }
}
