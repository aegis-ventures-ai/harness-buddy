import AppKit
import HarnessButlerKit
import UserNotifications

/// H-6: an opt-in notification when a harness update becomes available. Each version is announced
/// once (the ledger persists across launches). Clicking it opens the popover on the harnesses page.
/// It never starts an update.
///
/// Also the app's notification-center delegate: a usage alert (§4.5) opens that subscription's detail.
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let harnesses: HarnessStore
    private let openHarnesses: () -> Void
    private let openSubscription: (UUID) -> Void
    private var wasEnabled = AppSettings.notifyUpdates

    init(harnesses: HarnessStore, openHarnesses: @escaping () -> Void, openSubscription: @escaping (UUID) -> Void) {
        self.harnesses = harnesses
        self.openHarnesses = openHarnesses
        self.openSubscription = openSubscription
        super.init()
        UNUserNotificationCenter.current().delegate = self
        harnesses.onCheckCompleted = { [weak self] in self?.check() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    /// Turning the setting on asks macOS for permission (it only prompts the first time).
    private func settingsChanged() {
        let enabled = AppSettings.notifyUpdates
        guard enabled != wasEnabled else { return }
        wasEnabled = enabled
        guard enabled else { return }
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            UserDefaults.standard.set(!granted, forKey: AppSettings.notificationsDeniedKey)
            if granted {
                check()
            } else {
                AppSettings.notifyUpdates = false
            }
        }
    }

    /// Announce updates that haven't been announced yet.
    func check() {
        guard AppSettings.notifyUpdates else { return }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
            // Read and record without suspending in between so two checks can't announce twice.
            var ledger = AppSettings.notificationLedger
            let pending = ledger.pending(harnesses.statuses)
            guard !pending.isEmpty else { return }
            for announcement in pending { ledger.record(announcement) }
            AppSettings.notificationLedger = ledger
            for announcement in pending { post(announcement) }
        }
    }

    private func post(_ announcement: UpdateNotificationLedger.Announcement) {
        let harness = announcement.harness
        let content = UNMutableNotificationContent()
        content.title = "\(harness.displayName) \(announcement.latest) is available"
        let method = harnesses.status(for: harness).installation?.method.displayName
        content.body = [
            announcement.installed.map { "You have \($0)" + (method.map { " (\($0))" } ?? "") + "." },
            "Click to see what's new and update.",
        ].compactMap(\.self).joined(separator: " ")
        content.threadIdentifier = "harness-updates"
        content.userInfo = ["harness": harness.rawValue]
        let request = UNNotificationRequest(identifier: "update-\(harness.rawValue)-\(announcement.latest)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let subscription = (response.notification.request.content.userInfo["subscription"] as? String).flatMap(UUID.init(uuidString:))
        await open(subscription: subscription)
    }

    private func open(subscription: UUID?) {
        if let subscription { openSubscription(subscription) } else { openHarnesses() }
    }
}
