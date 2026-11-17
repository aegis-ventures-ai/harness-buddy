import Foundation
import Testing
@testable import HarnessButlerKit

@Suite struct UsageHistoryTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "hb-history-\(UUID().uuidString)")
    let subscription = UUID()
    let t0 = Date(timeIntervalSince1970: 1_793_491_200)   // 2026-11-01T00:00:00Z

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func snapshot(_ used: Double, at offset: TimeInterval, weekly: Double? = nil) -> UsageSnapshot {
        var windows = [UsageWindow(id: "session", label: "5-hour", usedPercent: used, resetsAt: nil, duration: 5 * 3600)]
        if let weekly { windows.append(UsageWindow(id: "weekly", label: "weekly", usedPercent: weekly, resetsAt: nil, duration: 7 * 86_400)) }
        return UsageSnapshot(windows: windows, planName: "Max", fetchedAt: t0.addingTimeInterval(offset), source: .live)
    }

    @Test func fileIsPrivateAndRecordsSurviveReopen() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "history.sqlite")
        do {
            let history = try UsageHistory(url: url)
            history.record(snapshot(10, at: 0, weekly: 3), for: subscription)
            history.record(snapshot(12, at: 300, weekly: 3.5), for: subscription)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))
        #expect((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let reopened = try UsageHistory(url: url)
        #expect(reopened.samples(subscription: subscription, window: "session", since: .distantPast).map(\.usedPercent) == [10, 12])
        #expect(reopened.sampleCount() == 4)
        // Nothing but IDs, numbers and times is stored.
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("Max".utf8)) == nil)
        #expect(bytes.range(of: Data("5-hour".utf8)) == nil)
    }

    @Test func unchangedReadingsAreThinnedAndDuplicatesIgnored() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try UsageHistory(url: directory.appending(path: "h.sqlite"))
        for minute in stride(from: 0, through: 60, by: 5) {
            history.record(snapshot(20, at: TimeInterval(minute * 60)), for: subscription)
        }
        history.record(snapshot(20, at: 60 * 60), for: subscription)   // same time again
        history.record(snapshot(25, at: 30 * 60), for: subscription)   // older than the last write
        // 0 min, 30 min, 60 min.
        #expect(history.samples(subscription: subscription, window: "session", since: .distantPast).map(\.at) == [0, 1800, 3600].map { t0.addingTimeInterval($0) })
    }

    @Test func budgetWindowsAreNotRecorded() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try UsageHistory(url: directory.appending(path: "h.sqlite"))
        let month = BillingMonth.containing(t0)
        let spend = APISpend(monthToDate: 10, daily: [], periodStart: month.start, periodEnd: month.end)
        history.record(UsageSnapshot(windows: [], planName: nil, fetchedAt: t0, source: .live, spend: spend).applyingBudget(100), for: subscription)
        #expect(history.sampleCount() == 0)
    }

    @Test func pruneAndDelete() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try UsageHistory(url: directory.appending(path: "h.sqlite"))
        let other = UUID()
        history.record(snapshot(10, at: 0), for: subscription)
        history.record(snapshot(10, at: 0), for: other)
        history.record(snapshot(11, at: 40 * 86_400), for: subscription)   // also prunes the 40-day-old rows
        #expect(history.samples(subscription: subscription, window: "session", since: .distantPast).count == 1)
        #expect(history.samples(subscription: other, window: "session", since: .distantPast).isEmpty)
        history.delete(subscription: subscription)
        #expect(history.sampleCount() == 0)
    }

    @Test func dailyIncreaseCountsResetsFromZero() {
        let first = t0
        let day: TimeInterval = 86_400
        let readings = [
            UsageSample(at: first.addingTimeInterval(-3600), usedPercent: 40),          // baseline from the day before
            UsageSample(at: first.addingTimeInterval(3600), usedPercent: 42),           // +2 on day 0
            UsageSample(at: first.addingTimeInterval(7200), usedPercent: 45),           // +3 on day 0
            UsageSample(at: first.addingTimeInterval(day + 100), usedPercent: 5),       // reset: +5 on day 1
            UsageSample(at: first.addingTimeInterval(day + 200), usedPercent: 5),       // unchanged
            UsageSample(at: first.addingTimeInterval(3 * day), usedPercent: 9.5),       // +4.5 on day 3
        ]
        let days = UsageHistory.dailyIncrease(readings, from: first, days: 4, calendar: utc)
        #expect(days.map(\.percent) == [5, 5, 0, 4.5])
        #expect(days.map(\.day) == [0, 1, 2, 3].map { first.addingTimeInterval(Double($0) * day) })
    }

    @Test func dailyUsageReadsTheLastSevenDays() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try UsageHistory(url: directory.appending(path: "h.sqlite"))
        for hour in 0..<(10 * 24) where hour % 6 == 0 {
            history.record(snapshot(0, at: TimeInterval(hour) * 3600, weekly: Double(hour) / 10), for: subscription)
        }
        let now = t0.addingTimeInterval(9 * 86_400 + 3600)
        let days = history.dailyUsage(subscription: subscription, window: "weekly", days: 7, now: now, calendar: utc)
        #expect(days.count == 7)
        #expect(days.first?.day == t0.addingTimeInterval(3 * 86_400))
        // 4 readings a day, 0.6% apart: 2.4% per day.
        #expect(days.allSatisfy { abs($0.percent - 2.4) < 0.0001 })
    }

    @Test func appFilesArePrivate() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let subscriptions = SubscriptionFile(url: directory.appending(path: "subscriptions.json"))
        try subscriptions.save([Subscription(name: "A", harness: .claude)])
        let cache = UsageCacheFile(url: directory.appending(path: "usage-cache.json"))
        try cache.save([subscription: snapshot(1, at: 0)])
        for url in [subscriptions.url, cache.url] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }
}

@Suite struct PrivateWriteTests {
    @Test func appDataFilesArePrivateAndReplacedWhole() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hb-private-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createPrivateDirectory(at: directory)
        let url = directory.appending(path: "data.json")
        try Data("first".utf8).writePrivately(to: url)
        // Even a file that was readable by others ends up 0600 after the next save.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false))
        try Data("second".utf8).writePrivately(to: url)
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        // No temp files are left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == ["data.json"])
    }
}
