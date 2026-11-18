import AppKit
import Observation
import Sparkle

/// The app's own updates (Sparkle). It reads the appcast attached to the latest GitHub release
/// once a day, and installs only DMGs that carry both our Developer ID signature and an EdDSA
/// signature from the key in `SUPublicEDKey`. Debug builds never check, so a development copy
/// can't replace itself with a release.
@Observable
final class AppUpdater: NSObject {
    /// False in debug builds: the controls are shown but disabled.
    let isAvailable: Bool
    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        #if DEBUG
        isAvailable = false
        #else
        isAvailable = true
        #endif
        super.init()
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        lastCheck = updater.lastUpdateCheckDate
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastCheck = updater.lastUpdateCheckDate }
            },
        ]
    }

    /// Daily background checks (`SUEnableAutomaticChecks`, on by default).
    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            withMutation(keyPath: \.checksAutomatically) { controller?.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    /// Download and install found updates without asking (off by default); they're applied on quit.
    var installsAutomatically: Bool {
        get { access(keyPath: \.installsAutomatically); return controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            withMutation(keyPath: \.installsAutomatically) { controller?.updater.automaticallyDownloadsUpdates = newValue }
        }
    }

    /// "Check for Updates…": shows Sparkle's window with the result, including "up to date".
    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    /// A menubar app has no Dock icon, so a scheduled check that finds an update must still
    /// bring its window forward instead of waiting to be noticed.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate() }
    }
}
