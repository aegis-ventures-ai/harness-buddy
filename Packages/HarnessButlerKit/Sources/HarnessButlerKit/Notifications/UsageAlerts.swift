import Foundation

/// Per-subscription notification choices (§4.5; the detail view's "notify when used" chips).
public struct UsageAlertPreferences: Codable, Hashable, Sendable {
    /// Percent-used thresholds, per window. Default 80% and 95%.
    public var thresholds: [Double]
    /// Notify when a limited window resets.
    public var notifyOnReset: Bool

    public init(thresholds: [Double] = UsageAlertPreferences.defaultThresholds, notifyOnReset: Bool = true) {
        self.thresholds = thresholds
        self.notifyOnReset = notifyOnReset
    }

    public static let defaultThresholds: [Double] = [80, 95]
    public static let standard = UsageAlertPreferences()
}

/// Something worth telling the user about one window.
public struct UsageAlert: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `threshold` was crossed (the highest newly crossed one); `usedPercent` may be higher.
        case threshold(Double)
        /// The window was limited and has reset.
        case reset
    }

    public var kind: Kind
    public var subscriptionID: UUID
    public var subscriptionName: String
    public var windowID: String
    public var windowLabel: String
    public var usedPercent: Double
    public var resetsAt: Date?

    /// Notification title and body.
    public func text(now: Date) -> (title: String, body: String) {
        let resets = resetsAt.map { " It resets \($0.formatted(.relative(presentation: .named, unitsStyle: .wide)))." } ?? ""
        switch kind {
        case .reset:
            return ("\(subscriptionName): \(windowLabel) has reset", "You can use it again.")
        case .threshold where usedPercent >= 100:
            return ("\(subscriptionName) is limited", "The \(windowLabel) window is used up.\(resets)")
        case .threshold(let threshold):
            let shown = max(threshold, usedPercent.rounded(.down))
            return ("\(subscriptionName): \(Int(shown))% of \(windowLabel) used", "\(Int(max(0, 100 - usedPercent).rounded()))% left.\(resets)")
        }
    }
}

/// §4.5: decides which threshold and reset alerts to send, at most once per window period.
/// Pure state, persisted by the app, so alerts don't repeat across launches.
public struct UsageAlertLedger: Codable, Hashable, Sendable {
    struct WindowState: Codable, Hashable, Sendable {
        /// `resetsAt` of the period this state is about.
        var period: Date?
        var lastUsed: Double
        /// The highest threshold already announced in this period (0 = none).
        var announced: Double
        var wasLimited: Bool
    }

    /// "subscription-uuid|window-id" → state.
    var windows: [String: WindowState] = [:]

    public init() {}

    /// Two readings belong to different periods when their reset times differ by more than this
    /// (reset times jitter by seconds between reads).
    static let periodTolerance: TimeInterval = 30 * 60

    /// Feeds one new snapshot in and returns the alerts it triggers. Always call it, even with
    /// notifications off, so turning them on doesn't replay old crossings.
    public mutating func evaluate(_ snapshot: UsageSnapshot, for subscription: Subscription,
                                  preferences: UsageAlertPreferences, now: Date) -> [UsageAlert] {
        // Old data (e.g. a harness cache from hours ago) isn't news.
        guard now.timeIntervalSince(snapshot.fetchedAt) <= subscription.cadence.staleAfter else { return [] }
        var alerts: [UsageAlert] = []
        for window in snapshot.current(at: now).windows {
            let key = subscription.id.uuidString + "|" + window.id
            func alert(_ kind: UsageAlert.Kind) -> UsageAlert {
                UsageAlert(kind: kind, subscriptionID: subscription.id, subscriptionName: subscription.name, windowID: window.id,
                           windowLabel: window.label, usedPercent: window.usedPercent, resetsAt: window.resetsAt)
            }
            let limited = window.usedPercent >= 100
            var state = windows[key] ?? WindowState(period: window.resetsAt, lastUsed: window.usedPercent, announced: 0, wasLimited: false)
            if windows[key] != nil, Self.isNewPeriod(state, window) {
                if state.wasLimited, !limited, preferences.notifyOnReset { alerts.append(alert(.reset)) }
                state = WindowState(period: window.resetsAt, lastUsed: window.usedPercent, announced: 0, wasLimited: false)
            } else if state.wasLimited, !limited {
                // Same period but no longer limited (e.g. the budget was raised, or the provider reset early).
                if preferences.notifyOnReset { alerts.append(alert(.reset)) }
                state.wasLimited = false
                state.announced = preferences.thresholds.filter { window.usedPercent >= $0 }.max() ?? 0
            }
            if let crossed = preferences.thresholds.filter({ window.usedPercent >= $0 && $0 > state.announced }).max() {
                alerts.append(alert(.threshold(crossed)))
                state.announced = crossed
            } else if limited, !state.wasLimited, state.announced > 0 {
                // Already warned at a lower threshold; still say when it's actually used up.
                alerts.append(alert(.threshold(100)))
            }
            if limited { state.wasLimited = true }
            state.period = window.resetsAt ?? state.period
            state.lastUsed = window.usedPercent
            windows[key] = state
        }
        // Windows that disappeared (e.g. a budget removed) are forgotten.
        let present = Set(snapshot.windows.map { subscription.id.uuidString + "|" + $0.id })
        windows = windows.filter { !$0.key.hasPrefix(subscription.id.uuidString + "|") || present.contains($0.key) }
        return alerts
    }

    static func isNewPeriod(_ state: WindowState, _ window: UsageWindow) -> Bool {
        if let old = state.period, let new = window.resetsAt {
            return abs(new.timeIntervalSince(old)) > periodTolerance
        }
        return window.usedPercent < state.lastUsed - 5
    }

    /// Subscriptions the ledger has state for.
    public var subscriptionIDs: [UUID] {
        Array(Set(windows.keys.compactMap { $0.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) } }))
    }

    /// Drops everything about a removed subscription.
    public mutating func forget(_ subscription: UUID) {
        windows = windows.filter { !$0.key.hasPrefix(subscription.uuidString + "|") }
    }
}
