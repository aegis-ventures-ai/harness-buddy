import Foundation

/// Spend on one UTC day.
public struct DailySpend: Codable, Hashable, Sendable {
    /// UTC midnight starting the day.
    public var day: Date
    public var amount: Double

    public init(day: Date, amount: Double) {
        self.day = day
        self.amount = amount
    }
}

/// Month-to-date spend of an API organization (U-7).
///
/// Both Anthropic and OpenAI bill API usage per UTC calendar month, so the billing month here is the
/// UTC month containing the fetch.
public struct APISpend: Codable, Hashable, Sendable {
    /// ISO currency code; both providers report USD.
    public var currency: String
    public var monthToDate: Double
    /// One entry per UTC day of the month so far that had spend, oldest first.
    public var daily: [DailySpend]
    public var periodStart: Date
    public var periodEnd: Date
    /// Spend after this time may be missing (Anthropic's `data_refreshed_at`; data lags 4–24 h).
    public var dataThrough: Date?

    public init(currency: String = "USD", monthToDate: Double, daily: [DailySpend], periodStart: Date, periodEnd: Date, dataThrough: Date? = nil) {
        self.currency = currency
        self.monthToDate = monthToDate
        self.daily = daily
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.dataThrough = dataThrough
    }

    /// Builds the spend from per-day amounts (any order, duplicates summed).
    public init(currency: String = "USD", days: [Date: Double], month: BillingMonth, dataThrough: Date? = nil) {
        let daily = days.filter { $0.value != 0 }.map { DailySpend(day: $0.key, amount: $0.value) }.sorted { $0.day < $1.day }
        self.init(currency: currency, monthToDate: days.values.reduce(0, +), daily: daily,
                  periodStart: month.start, periodEnd: month.end, dataThrough: dataThrough)
    }

    public var monthLength: TimeInterval { periodEnd.timeIntervalSince(periodStart) }

    /// Days of the month the spend covers. Uses `dataThrough` when the provider says how far its data
    /// goes, so lagging data doesn't drag the rate down, and counts at least one day so the first
    /// hours of a month don't extrapolate wildly.
    public func elapsedDays(at now: Date) -> Double {
        let through = min(dataThrough ?? now, now, periodEnd)
        return max(1, through.timeIntervalSince(periodStart) / 86_400)
    }

    /// Average spend per day so far (U-7 "daily run rate").
    public func dailyRunRate(at now: Date) -> Double {
        monthToDate / elapsedDays(at: now)
    }

    /// Linear projection to the end of the billing month (U-7).
    public func projectedMonthEnd(at now: Date) -> Double {
        let monthDays = monthLength / 86_400
        let elapsed = elapsedDays(at: now)
        guard elapsed < monthDays else { return monthToDate }
        return monthToDate + dailyRunRate(at: now) * (monthDays - elapsed)
    }

    /// The last `count` UTC days ending today, zero-filled (for the 7-day sparkline).
    public func lastDays(_ count: Int, at now: Date) -> [DailySpend] {
        let today = BillingMonth.utcDay(containing: now)
        let byDay = Dictionary(daily.map { ($0.day, $0.amount) }, uniquingKeysWith: +)
        return (0..<count).reversed().map { offset in
            let day = today.addingTimeInterval(-Double(offset) * 86_400)
            return DailySpend(day: day, amount: byDay[day] ?? 0)
        }
    }

    /// The budget as a usage window (U-8), so status, pace, at-risk, alerts and the menubar treat
    /// a budget exactly like a rate-limit window over the billing month.
    public func budgetWindow(_ budget: Double) -> UsageWindow? {
        guard budget > 0, monthLength > 0 else { return nil }
        return UsageWindow(
            id: APISpend.budgetWindowID,
            label: "monthly budget",
            usedPercent: monthToDate / budget * 100,
            resetsAt: periodEnd,
            duration: monthLength
        )
    }

    public static let budgetWindowID = "api:budget"
}

extension UsageSnapshot {
    /// The snapshot with its budget window matching `budget` (added, updated or removed).
    /// Applied when a report arrives and whenever the user edits the budget, without a refetch.
    public func applyingBudget(_ budget: Double?) -> UsageSnapshot {
        var copy = self
        copy.windows.removeAll { $0.id == APISpend.budgetWindowID }
        if let spend, let budget, let window = spend.budgetWindow(budget) {
            copy.windows.append(window)
        }
        return copy
    }
}

/// A UTC calendar month.
public struct BillingMonth: Hashable, Sendable {
    public var start: Date
    public var end: Date

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    public static func containing(_ date: Date) -> BillingMonth {
        let calendar = utc
        let start = calendar.dateInterval(of: .month, for: date)!.start
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return BillingMonth(start: start, end: end)
    }

    public static func utcDay(containing date: Date) -> Date {
        utc.startOfDay(for: date)
    }
}
