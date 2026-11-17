import Foundation

public enum RefreshTrigger: Sendable {
    case launch
    case scheduled
    case popoverOpened
    case manual
}

/// Per-subscription refresh bookkeeping.
public struct RefreshState: Hashable, Sendable {
    public var lastAttempt: Date?
    public var consecutiveFailures = 0
    /// Provider-requested quiet period (`retry-after`).
    public var blockedUntil: Date?
    public var inFlight = false

    public init() {}
}

/// U-12 refresh cadence, as pure functions of state and time.
public enum RefreshPolicy {
    /// Error back-off when the provider gives no `retry-after`: 5 → 10 → 30 min.
    public static let backoff: [TimeInterval] = [5 * 60, 10 * 60, 30 * 60]
    /// Manual refreshes are limited to one per minute per source.
    public static let manualMinimumGap: TimeInterval = 60
    /// Slow down on battery or Low Power Mode.
    public static let batteryMultiplier = 2.0

    public static func nextDue(
        harness: Harness,
        state: RefreshState,
        snapshot: UsageSnapshot?,
        onBattery: Bool
    ) -> Date {
        nextDue(cadence: harness.cadence, state: state, snapshot: snapshot, onBattery: onBattery)
    }

    public static func nextDue(
        cadence: UsageCadence,
        state: RefreshState,
        snapshot: UsageSnapshot?,
        onBattery: Bool
    ) -> Date {
        guard let last = state.lastAttempt else { return .distantPast }
        let interval = cadence.refreshInterval * (onBattery ? batteryMultiplier : 1)
        var due: Date
        if state.consecutiveFailures > 0 {
            due = last.addingTimeInterval(max(interval, backoff[min(state.consecutiveFailures, backoff.count) - 1]))
        } else {
            due = last.addingTimeInterval(interval)
            // Refresh right after a window resets, so a limited row clears promptly.
            if let reset = snapshot?.windows.compactMap(\.resetsAt).filter({ $0 > last }).min() {
                due = min(due, reset.addingTimeInterval(5))
            }
        }
        if let blocked = state.blockedUntil { due = max(due, blocked) }
        return due
    }

    public static func shouldRefresh(
        harness: Harness,
        state: RefreshState,
        snapshot: UsageSnapshot?,
        trigger: RefreshTrigger,
        now: Date,
        onBattery: Bool
    ) -> Bool {
        shouldRefresh(cadence: harness.cadence, state: state, snapshot: snapshot, trigger: trigger, now: now, onBattery: onBattery)
    }

    public static func shouldRefresh(
        cadence: UsageCadence,
        state: RefreshState,
        snapshot: UsageSnapshot?,
        trigger: RefreshTrigger,
        now: Date,
        onBattery: Bool
    ) -> Bool {
        if state.inFlight { return false }
        if let blocked = state.blockedUntil, now < blocked { return false }
        let sinceAttempt = state.lastAttempt.map { now.timeIntervalSince($0) } ?? .infinity
        switch trigger {
        case .launch:
            return true
        case .manual:
            return sinceAttempt >= manualMinimumGap
        case .popoverOpened:
            if state.consecutiveFailures > 0 {
                return now >= nextDue(cadence: cadence, state: state, snapshot: snapshot, onBattery: onBattery)
            }
            let dataAge = snapshot.map { now.timeIntervalSince($0.fetchedAt) } ?? .infinity
            return dataAge >= cadence.popoverStaleness && sinceAttempt >= min(cadence.popoverStaleness, manualMinimumGap)
        case .scheduled:
            return now >= nextDue(cadence: cadence, state: state, snapshot: snapshot, onBattery: onBattery)
        }
    }

    /// How fresh harness-cached data must be to skip a live read for this trigger.
    public static func acceptableCacheAge(harness: Harness, trigger: RefreshTrigger) -> TimeInterval {
        acceptableCacheAge(cadence: harness.cadence, trigger: trigger)
    }

    public static func acceptableCacheAge(cadence: UsageCadence, trigger: RefreshTrigger) -> TimeInterval {
        switch trigger {
        case .launch, .scheduled: cadence.refreshInterval
        case .popoverOpened, .manual: cadence.popoverStaleness
        }
    }

    /// Fold a report into state: success clears back-off; failure counts up and honours `retry-after`.
    public static func record(_ report: UsageReport, into state: inout RefreshState, at now: Date) {
        state.inFlight = false
        state.lastAttempt = now
        guard let issue = report.issue else {
            state.consecutiveFailures = 0
            state.blockedUntil = nil
            return
        }
        if issue.shouldBackOff { state.consecutiveFailures += 1 }
        if let retryAfter = issue.retryAfter {
            state.blockedUntil = now.addingTimeInterval(retryAfter)
        }
    }
}
