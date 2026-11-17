import Foundation

/// H-6: remembers which update versions were already announced, so each harness version
/// notifies at most once (across launches; the app persists this in UserDefaults).
public struct UpdateNotificationLedger: Codable, Hashable, Sendable {
    /// Harness raw value → the last version announced.
    public private(set) var notified: [String: String] = [:]

    public init() {}

    public struct Announcement: Hashable, Sendable {
        public var harness: Harness
        public var installed: SemanticVersion?
        public var latest: SemanticVersion
    }

    /// Updates that haven't been announced yet. A version is only announced when it's newer than
    /// the last one announced, so switching to an older channel doesn't notify again.
    public func pending(_ statuses: [Harness: HarnessStatus]) -> [Announcement] {
        Harness.allCases.compactMap { harness in
            guard let status = statuses[harness], status.isUpdateAvailable, let latest = status.latest else { return nil }
            if let last = notified[harness.rawValue].flatMap(SemanticVersion.init), latest <= last { return nil }
            return Announcement(harness: harness, installed: status.installation?.version, latest: latest)
        }
    }

    public mutating func record(_ announcement: Announcement) {
        notified[announcement.harness.rawValue] = announcement.latest.description
    }
}
