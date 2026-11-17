import AppKit
import HarnessButlerKit
import UserNotifications

/// §4.5: threshold alerts (default 80% and 95% used, per window) and "window reset" alerts for
/// limited subscriptions. Opt-in; permission is requested only when the user turns it on.
///
/// Every new snapshot goes through the ledger even while notifications are off, so turning them on
/// doesn't replay old crossings. The ledger lives in `usage-alerts.json` (0600).
final class UsageNotifier {
    private let store: UsageStore
    private var ledger: UsageAlertLedger
    private var wasEnabled = AppSettings.notifyUsage
    private let ledgerURL: URL

    init(store: UsageStore, ledgerURL: URL = UsageNotifier.standardLedgerURL) {
        self.store = store
        self.ledgerURL = ledgerURL
        ledger = (try? Data(contentsOf: ledgerURL)).flatMap { try? JSONDecoder().decode(UsageAlertLedger.self, from: $0) } ?? UsageAlertLedger()
        store.onSnapshot = { [weak self] subscription, snapshot in self?.process(snapshot, for: subscription) }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    static var standardLedgerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "HarnessButler/usage-alerts.json")
    }

    private func settingsChanged() {
        let enabled = AppSettings.notifyUsage
        guard enabled != wasEnabled else { return }
        wasEnabled = enabled
        guard enabled else { return }
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            UserDefaults.standard.set(!granted, forKey: AppSettings.notificationsDeniedKey)
            if !granted { AppSettings.notifyUsage = false }
        }
    }

    func process(_ snapshot: UsageSnapshot, for subscription: Subscription) {
        let before = ledger
        let alerts = ledger.evaluate(snapshot, for: subscription, preferences: AppSettings.alertPreferences(for: subscription.id), now: .now)
        let known = Set(store.subscriptions.map(\.id))
        for id in Set(ledger.subscriptionIDs).subtracting(known) { ledger.forget(id) }
        if ledger != before { save() }
        guard AppSettings.notifyUsage, !alerts.isEmpty else { return }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
            for alert in alerts { post(alert) }
        }
    }

    private func post(_ alert: UsageAlert) {
        let text = alert.text(now: .now)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.threadIdentifier = "usage-\(alert.subscriptionID.uuidString)"
        content.userInfo = ["subscription": alert.subscriptionID.uuidString]
        if case .threshold(let threshold) = alert.kind, threshold >= 95 || alert.usedPercent >= 100 { content.sound = .default }
        let suffix = switch alert.kind {
        case .threshold(let threshold): "t\(Int(threshold))"
        case .reset: "reset"
        }
        // Same window + kind replaces an older banner instead of stacking.
        let request = UNNotificationRequest(identifier: "usage-\(alert.subscriptionID.uuidString)-\(alert.windowID)-\(suffix)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        let fm = FileManager.default
        try? fm.createPrivateDirectory(at: ledgerURL.deletingLastPathComponent())
        try? data.write(to: ledgerURL, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path(percentEncoded: false))
    }
}
