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
    /// §4.5: threshold and reset notifications (opt-in).
    static let notifyUsageKey = "notifyUsage"
    /// Per-subscription alert choices, `[uuid: UsageAlertPreferences]` (JSON).
    static let usageAlertPreferencesKey = "usageAlertPreferences"
    /// M-2: menubar display mode.
    static let menuBarModeKey = "menuBarMode"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showUpdateBadgeKey: true,
            notifyUpdatesKey: false,
            notifyUsageKey: false,
            notificationsDeniedKey: false,
        ])
    }

    static var showUpdateBadge: Bool { UserDefaults.standard.bool(forKey: showUpdateBadgeKey) }

    static var notifyUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: notifyUpdatesKey) }
        set { UserDefaults.standard.set(newValue, forKey: notifyUpdatesKey) }
    }

    static var menuBarMode: MenuBarMode {
        UserDefaults.standard.string(forKey: menuBarModeKey).flatMap(MenuBarMode.init(rawValue:)) ?? .percent
    }

    static var notifyUsage: Bool {
        get { UserDefaults.standard.bool(forKey: notifyUsageKey) }
        set { UserDefaults.standard.set(newValue, forKey: notifyUsageKey) }
    }

    static var usageAlertPreferences: [UUID: UsageAlertPreferences] {
        get {
            UserDefaults.standard.data(forKey: usageAlertPreferencesKey)
                .flatMap { try? JSONDecoder().decode([UUID: UsageAlertPreferences].self, from: $0) } ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: usageAlertPreferencesKey) }
    }

    static func alertPreferences(for id: UUID) -> UsageAlertPreferences {
        usageAlertPreferences[id] ?? .standard
    }

    static func setAlertPreferences(_ preferences: UsageAlertPreferences, for id: UUID) {
        var all = usageAlertPreferences
        all[id] = preferences == .standard ? nil : preferences
        usageAlertPreferences = all
    }

    static var notificationLedger: UpdateNotificationLedger {
        get {
            UserDefaults.standard.data(forKey: notificationLedgerKey)
                .flatMap { try? JSONDecoder().decode(UpdateNotificationLedger.self, from: $0) } ?? UpdateNotificationLedger()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: notificationLedgerKey) }
    }
}

/// M-2 menubar display modes.
enum MenuBarMode: String, CaseIterable, Identifiable {
    /// Logo + % left per pinned subscription (default).
    case percent
    /// One ring for the most constrained pinned subscription.
    case worstOf
    /// Logo + two stacked bars (shortest and longest window) per pinned subscription.
    case miniBars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percent: "Percent"
        case .worstOf: "Worst-of"
        case .miniBars: "Mini bars"
        }
    }

    var explanation: String {
        switch self {
        case .percent: "The logo and % left of each pinned subscription's tightest window."
        case .worstOf: "One ring for the most constrained pinned subscription. Smallest footprint; hover for all of them."
        case .miniBars: "Two bars per pinned subscription: the shortest window (e.g. the 5-hour session) on top, the longest (e.g. weekly) below."
        }
    }
}
