import Foundation
import Testing
@testable import HarnessButlerKit

@Suite struct UsageAlertTests {
    let subscription = Subscription(name: "Work", harness: .claude)
    let t0 = Date(timeIntervalSince1970: 1_793_491_200)
    let reset1: Date
    let reset2: Date

    init() {
        reset1 = t0.addingTimeInterval(5 * 3600)
        reset2 = t0.addingTimeInterval(10 * 3600)
    }

    func snapshot(_ used: Double, resetsAt: Date?, at offset: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(id: "session", label: "5-hour session", usedPercent: used, resetsAt: resetsAt, duration: 5 * 3600)],
                      planName: nil, fetchedAt: t0.addingTimeInterval(offset), source: .live)
    }

    func kinds(_ ledger: inout UsageAlertLedger, _ used: Double, resetsAt: Date?, at offset: TimeInterval,
               preferences: UsageAlertPreferences = .standard) -> [UsageAlert.Kind] {
        ledger.evaluate(snapshot(used, resetsAt: resetsAt, at: offset), for: subscription, preferences: preferences,
                        now: t0.addingTimeInterval(offset)).map(\.kind)
    }

    @Test func eachThresholdOncePerPeriod() {
        var ledger = UsageAlertLedger()
        #expect(kinds(&ledger, 50, resetsAt: reset1, at: 0).isEmpty)
        #expect(kinds(&ledger, 81, resetsAt: reset1, at: 600) == [.threshold(80)])
        #expect(kinds(&ledger, 85, resetsAt: reset1.addingTimeInterval(20), at: 900).isEmpty)   // jitter isn't a new period
        #expect(kinds(&ledger, 96, resetsAt: reset1, at: 1200) == [.threshold(95)])
        #expect(kinds(&ledger, 97, resetsAt: reset1, at: 1500).isEmpty)
        // Next period: the thresholds arm again.
        #expect(kinds(&ledger, 10, resetsAt: reset2, at: 5 * 3600 + 10).isEmpty)
        #expect(kinds(&ledger, 82, resetsAt: reset2, at: 6 * 3600) == [.threshold(80)])
    }

    @Test func aJumpAnnouncesOnlyTheHighest() {
        var ledger = UsageAlertLedger()
        #expect(kinds(&ledger, 99, resetsAt: reset1, at: 0) == [.threshold(95)])
    }

    @Test func limitedThenResetNotifies() {
        var ledger = UsageAlertLedger()
        #expect(kinds(&ledger, 90, resetsAt: reset1, at: 0) == [.threshold(80)])
        #expect(kinds(&ledger, 100, resetsAt: reset1, at: 600) == [.threshold(95)])
        #expect(kinds(&ledger, 100, resetsAt: reset1, at: 1200).isEmpty)
        #expect(kinds(&ledger, 0, resetsAt: reset2, at: 5 * 3600 + 5) == [.reset])
        #expect(kinds(&ledger, 1, resetsAt: reset2, at: 5 * 3600 + 600).isEmpty)
    }

    @Test func limitedAfterTheLastThresholdStillSaysSo() {
        var ledger = UsageAlertLedger()
        #expect(kinds(&ledger, 96, resetsAt: reset1, at: 0) == [.threshold(95)])
        let alerts = ledger.evaluate(snapshot(100, resetsAt: reset1, at: 600), for: subscription, preferences: .standard, now: t0.addingTimeInterval(600))
        #expect(alerts.map(\.kind) == [.threshold(100)])
        #expect(alerts.first?.text(now: t0).title == "Work is limited")
    }

    @Test func preferencesAreHonoured() {
        var ledger = UsageAlertLedger()
        let quiet = UsageAlertPreferences(thresholds: [50], notifyOnReset: false)
        #expect(kinds(&ledger, 90, resetsAt: reset1, at: 0, preferences: quiet) == [.threshold(50)])
        #expect(kinds(&ledger, 100, resetsAt: reset1, at: 600, preferences: quiet) == [.threshold(100)])
        #expect(kinds(&ledger, 0, resetsAt: reset2, at: 5 * 3600 + 5, preferences: quiet).isEmpty)
        var none = UsageAlertLedger()
        #expect(kinds(&none, 100, resetsAt: reset1, at: 0, preferences: UsageAlertPreferences(thresholds: [], notifyOnReset: true)).isEmpty)
    }

    @Test func staleSnapshotsDontAlert() {
        var ledger = UsageAlertLedger()
        let old = snapshot(99, resetsAt: reset1, at: 0)
        #expect(ledger.evaluate(old, for: subscription, preferences: .standard, now: t0.addingTimeInterval(2 * 3600)).isEmpty)
    }

    @Test func windowsWithoutResetTimeUseADrop() {
        var ledger = UsageAlertLedger()
        #expect(kinds(&ledger, 100, resetsAt: nil, at: 0) == [.threshold(95)])
        #expect(kinds(&ledger, 2, resetsAt: nil, at: 600) == [.reset])
        #expect(kinds(&ledger, 81, resetsAt: nil, at: 1200) == [.threshold(80)])
    }

    @Test func budgetRaisedWhileLimitedCountsAsReset() {
        let api = Subscription.api(APIAccount(provider: .anthropic, monthlyBudget: 100), name: "Org")
        let month = BillingMonth.containing(t0.addingTimeInterval(10 * 86_400))
        let now = t0.addingTimeInterval(10 * 86_400)
        let spend = APISpend(monthToDate: 120, daily: [], periodStart: month.start, periodEnd: month.end)
        let base = UsageSnapshot(windows: [], planName: nil, fetchedAt: now, source: .live, spend: spend)
        var ledger = UsageAlertLedger()
        #expect(ledger.evaluate(base.applyingBudget(100), for: api, preferences: .standard, now: now).map(\.kind) == [.threshold(95)])
        // Raising the budget to $200 drops usage to 60%: no threshold alert, a "reset" because it's usable again.
        #expect(ledger.evaluate(base.applyingBudget(200), for: api, preferences: .standard, now: now).map(\.kind) == [.reset])
        // Removing the budget forgets the window.
        #expect(ledger.evaluate(base, for: api, preferences: .standard, now: now).isEmpty)
        #expect(ledger.windows.isEmpty)
    }

    @Test func ledgerRoundTripsAndForgets() throws {
        var ledger = UsageAlertLedger()
        _ = kinds(&ledger, 81, resetsAt: reset1, at: 0)
        var decoded = try JSONDecoder().decode(UsageAlertLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
        #expect(kinds(&decoded, 82, resetsAt: reset1, at: 60).isEmpty)
        decoded.forget(subscription.id)
        #expect(decoded.windows.isEmpty)
    }

    @Test func alertText() {
        let alert = UsageAlert(kind: .threshold(80), subscriptionID: subscription.id, subscriptionName: "Work", windowID: "session",
                               windowLabel: "5-hour session", usedPercent: 83.4, resetsAt: nil)
        #expect(alert.text(now: t0).title == "Work: 83% of 5-hour session used")
        #expect(alert.text(now: t0).body == "17% left.")
        var reset = alert
        reset.kind = .reset
        #expect(reset.text(now: t0).title == "Work: 5-hour session has reset")
    }
}
