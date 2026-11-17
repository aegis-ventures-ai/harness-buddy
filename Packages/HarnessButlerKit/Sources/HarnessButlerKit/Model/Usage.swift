import Foundation

/// A rate-limit bucket with a reset time, e.g. Claude's 5-hour session or Codex's weekly window.
public struct UsageWindow: Codable, Hashable, Sendable, Identifiable {
    /// Stable key within one subscription, e.g. `session`, `weekly_all`, `weekly_scoped:Fable`, `codex:primary`.
    public var id: String
    /// Short label, e.g. "5-hour session", "weekly · all models".
    public var label: String
    /// Percent of the window used. Can exceed 100.
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Window length, used for pace. `nil` when the provider doesn't say and it can't be inferred.
    public var duration: TimeInterval?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?, duration: TimeInterval?) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.duration = duration
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }

    public var startsAt: Date? {
        guard let resetsAt, let duration else { return nil }
        return resetsAt.addingTimeInterval(-duration)
    }

    /// The window as it looks at `now`: once `resetsAt` has passed the old percentage is meaningless,
    /// so it reads as freshly reset (0% used, next reset unknown).
    public func current(at now: Date) -> UsageWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        var copy = self
        copy.usedPercent = 0
        if let duration {
            // Assume back-to-back windows; good enough until the next live read.
            var next = resetsAt
            while next <= now { next = next.addingTimeInterval(duration) }
            copy.resetsAt = next
        } else {
            copy.resetsAt = nil
        }
        return copy
    }
}

/// Extra/overage credits reported alongside the windows (U-6).
public struct UsageCredits: Codable, Hashable, Sendable {
    public var usedMinor: Int
    public var limitMinor: Int?
    public var currency: String
    public var exponent: Int

    public init(usedMinor: Int, limitMinor: Int?, currency: String, exponent: Int) {
        self.usedMinor = usedMinor
        self.limitMinor = limitMinor
        self.currency = currency
        self.exponent = exponent
    }
}

/// Where a snapshot came from.
public enum UsageSource: String, Codable, Sendable {
    /// Read live from the provider (network or harness process).
    case live
    /// Read from a cache the harness keeps on disk (e.g. Claude's `.claude.json`).
    case harnessCache
}

/// Everything known about one subscription's usage at a point in time.
public struct UsageSnapshot: Codable, Hashable, Sendable {
    public var windows: [UsageWindow]
    public var planName: String?
    public var credits: UsageCredits?
    /// When the underlying data was fetched (for a harness cache, when the harness fetched it).
    public var fetchedAt: Date
    public var source: UsageSource
    /// Month-to-date spend, for API subscriptions (U-7).
    public var spend: APISpend?

    public init(windows: [UsageWindow], planName: String?, credits: UsageCredits? = nil, fetchedAt: Date, source: UsageSource, spend: APISpend? = nil) {
        self.windows = windows
        self.planName = planName
        self.credits = credits
        self.fetchedAt = fetchedAt
        self.source = source
        self.spend = spend
    }

    public func current(at now: Date) -> UsageSnapshot {
        var copy = self
        copy.windows = windows.map { $0.current(at: now) }
        return copy
    }
}

/// Why a refresh did not produce fresh data. Each case maps to a row state in the popover.
public enum UsageIssue: Error, Hashable, Sendable {
    /// The harness binary couldn't be found or launched.
    case harnessMissing(Harness)
    /// No login in this home directory.
    case signedOut(hint: String)
    /// A login exists but its token is expired or was rejected; the harness must refresh it.
    case tokenExpired(hint: String)
    /// The provider asked us to slow down.
    case rateLimited(retryAfter: TimeInterval?)
    /// Network or provider failure.
    case unavailable(String)
    /// This harness version doesn't expose usage the way we read it.
    case unsupported(String)

    public var message: String {
        switch self {
        case .harnessMissing(let harness): "\(harness.displayName) isn't installed"
        case .signedOut(let hint): "Signed out. \(hint)"
        case .tokenExpired(let hint): "Login expired. \(hint)"
        case .rateLimited: "Provider is rate-limiting usage reads"
        case .unavailable(let detail): detail
        case .unsupported(let detail): detail
        }
    }

    /// Whether the scheduler should back off (5 → 10 → 30 min) after this issue.
    /// An expired token doesn't: the provider gates on the credential changing, which is cheap to check.
    public var shouldBackOff: Bool {
        if case .tokenExpired = self { return false }
        return true
    }

    /// A provider-requested retry delay, if any.
    public var retryAfter: TimeInterval? {
        if case .rateLimited(let retryAfter) = self { return retryAfter }
        return nil
    }
}

/// What one fetch returns: fresh data, an issue, or both (e.g. a cached snapshot plus "login expired").
public struct UsageReport: Sendable {
    public var snapshot: UsageSnapshot?
    public var issue: UsageIssue?

    public init(snapshot: UsageSnapshot?, issue: UsageIssue? = nil) {
        self.snapshot = snapshot
        self.issue = issue
    }

    public static func failure(_ issue: UsageIssue) -> UsageReport { UsageReport(snapshot: nil, issue: issue) }
}
