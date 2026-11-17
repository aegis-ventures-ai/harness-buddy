import Foundation
import HarnessButlerKit

/// App preferences in UserDefaults (no secrets).
enum AppSettings {
    /// M-4: show a dot on the menubar item when a harness update is available.
    static let showUpdateBadgeKey = "showUpdateBadge"
    /// H-6: post a notification when a harness update becomes available (opt-in).
    static let notifyUpdatesKey = "notifyHarnessUpdates"
    /// Set when macOS refused notification permission, so Settings can explain.
    static let notificationsDeniedKey = "notificationsDenied"
    /// Which update versions were already announced (JSON).
    static let notificationLedgerKey = "updateNotificationLedger"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showUpdateBadgeKey: true,
            notifyUpdatesKey: false,
            notificationsDeniedKey: false,
        ])
    }

    static var showUpdateBadge: Bool { UserDefaults.standard.bool(forKey: showUpdateBadgeKey) }

    static var notifyUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: notifyUpdatesKey) }
        set { UserDefaults.standard.set(newValue, forKey: notifyUpdatesKey) }
    }

    static var notificationLedger: UpdateNotificationLedger {
        get {
            UserDefaults.standard.data(forKey: notificationLedgerKey)
                .flatMap { try? JSONDecoder().decode(UpdateNotificationLedger.self, from: $0) } ?? UpdateNotificationLedger()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: notificationLedgerKey) }
    }
}
