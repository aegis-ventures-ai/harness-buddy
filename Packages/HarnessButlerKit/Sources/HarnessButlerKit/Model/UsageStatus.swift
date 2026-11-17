import Foundation

/// Usage versus time elapsed in a window.
public struct Pace: Hashable, Sendable {
    /// Fraction of the window that has elapsed, 0...1.
    public var elapsedFraction: Double
    /// `usedPercent - elapsed%`. Positive = ahead of a linear burn (bad); negative = behind (good).
    public var deltaPercent: Double
    /// Linear projection of `usedPercent` at reset.
    public var projectedUsedPercent: Double

    /// Where the pace marker sits on a bar measured in *remaining* percent.
    public var expectedRemainingPercent: Double { max(0, 100 - elapsedFraction * 100) }
}

/// Status of one window or a whole subscription (U-8).
public enum UsageStatus: Int, Comparable, Sendable, CaseIterable {
    case onTrack = 0
    case atRisk = 1
    case limited = 2

    public static func < (lhs: UsageStatus, rhs: UsageStatus) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum UsageRules {
    /// Don't call a window at risk until this much of it has elapsed (decision 11).
    public static let atRiskGuardFraction = 0.10

    public static func pace(of window: UsageWindow, at now: Date) -> Pace? {
        guard let start = window.startsAt, let duration = window.duration, duration > 0 else { return nil }
        let elapsed = now.timeIntervalSince(start) / duration
        guard elapsed > 0, elapsed <= 1 else { return nil }
        return Pace(
            elapsedFraction: elapsed,
            deltaPercent: window.usedPercent - elapsed * 100,
            projectedUsedPercent: window.usedPercent / elapsed
        )
    }

    /// U-8: limited at 100% used; at risk when the linear projection reaches 100% before reset,
    /// evaluated only once 10% of the window has elapsed.
    public static func status(of window: UsageWindow, at now: Date) -> UsageStatus {
        if window.usedPercent >= 100 { return .limited }
        guard let pace = pace(of: window, at: now), pace.elapsedFraction >= atRiskGuardFraction else { return .onTrack }
        return pace.projectedUsedPercent >= 100 ? .atRisk : .onTrack
    }

    /// The worst status across windows.
    public static func status(of snapshot: UsageSnapshot, at now: Date) -> UsageStatus {
        snapshot.windows.map { status(of: $0, at: now) }.max() ?? .onTrack
    }

    /// M-2 worst-of: the index of the most constrained item (worst status, then least remaining in
    /// its headline window). Fresh data wins over stale; items without a window are skipped.
    public static func mostConstrained(_ items: [(snapshot: UsageSnapshot?, isStale: Bool)], at now: Date) -> Int? {
        let ranked = items.enumerated().compactMap { index, item -> (index: Int, window: UsageWindow, status: UsageStatus, stale: Bool)? in
            guard let snapshot = item.snapshot?.current(at: now), let window = headlineWindow(of: snapshot, at: now) else { return nil }
            return (index, window, status(of: window, at: now), item.isStale)
        }
        return ranked.min { a, b in
            if a.stale != b.stale { return !a.stale }
            if a.status != b.status { return a.status > b.status }
            if a.window.remainingPercent != b.window.remainingPercent { return a.window.remainingPercent < b.window.remainingPercent }
            return a.index < b.index
        }?.index
    }

    /// M-2 mini bars: the shortest window (e.g. the 5-hour session) on top and the longest
    /// (e.g. weekly) below; one bar when there's only one distinct length.
    public static func miniBarWindows(of snapshot: UsageSnapshot) -> [UsageWindow] {
        let timed = snapshot.windows.filter { $0.duration != nil }
        guard let shortest = timed.min(by: { $0.duration! < $1.duration! }),
              let longest = timed.max(by: { a, b in
                  // Among the longest, prefer the tightest (e.g. weekly · all models over a scoped weekly).
                  a.duration! != b.duration! ? a.duration! < b.duration! : a.remainingPercent > b.remainingPercent
              }) else {
            return Array(snapshot.windows.prefix(1))
        }
        return shortest.duration == longest.duration ? [longest] : [shortest, longest]
    }

    /// The window to headline in compact views: worst status first, then least remaining.
    public static func headlineWindow(of snapshot: UsageSnapshot, at now: Date) -> UsageWindow? {
        snapshot.windows.min { a, b in
            let sa = status(of: a, at: now), sb = status(of: b, at: now)
            if sa != sb { return sa > sb }
            return a.remainingPercent < b.remainingPercent
        }
    }
}
