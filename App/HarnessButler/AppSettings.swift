import Foundation

/// App preferences in UserDefaults (no secrets).
enum AppSettings {
    /// M-4: show a dot on the menubar item when a harness update is available.
    static let showUpdateBadgeKey = "showUpdateBadge"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [showUpdateBadgeKey: true])
    }

    static var showUpdateBadge: Bool { UserDefaults.standard.bool(forKey: showUpdateBadgeKey) }
}
