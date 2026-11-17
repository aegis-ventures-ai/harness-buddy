import Foundation
import Testing
@testable import HarnessButlerKit

@Suite struct UsageRulesTests {
    let week: TimeInterval = 7 * 86400
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A weekly window with `elapsed` of it gone and `used` percent consumed.
    func window(used: Double, elapsed: Double, id: String = "w") -> UsageWindow {
        UsageWindow(id: id, label: id, usedPercent: used, resetsAt: now.addingTimeInterval(week * (1 - elapsed)), duration: week)
    }

    @Test func paceIsUsageMinusElapsed() throws {
        let pace = try #require(UsageRules.pace(of: window(used: 20, elapsed: 0.5), at: now))
        #expect(abs(pace.elapsedFraction - 0.5) < 1e-9)
        #expect(abs(pace.deltaPercent - -30) < 1e-9)      // 30 points behind: good
        #expect(abs(pace.projectedUsedPercent - 40) < 1e-9)
        #expect(abs(pace.expectedRemainingPercent - 50) < 1e-9)
    }

    @Test func atRiskWhenProjectionReachesHundredBeforeReset() {
        #expect(UsageRules.status(of: window(used: 60, elapsed: 0.5), at: now) == .atRisk)   // projects 120%
        #expect(UsageRules.status(of: window(used: 50, elapsed: 0.5), at: now) == .atRisk)   // exactly 100%
        #expect(UsageRules.status(of: window(used: 49, elapsed: 0.5), at: now) == .onTrack)
    }

    @Test func lowRemainingAloneIsNotAtRisk() {
        // 10% left but 95% of the window gone: projects 94.7%, so on track (decision 8).
        #expect(UsageRules.status(of: window(used: 90, elapsed: 0.95), at: now) == .onTrack)
    }

    @Test func earlyWindowGuardSkipsTheFirstTenPercent() {
        #expect(UsageRules.status(of: window(used: 30, elapsed: 0.05), at: now) == .onTrack)
        #expect(UsageRules.status(of: window(used: 30, elapsed: 0.10), at: now) == .atRisk)
    }

    @Test func limitedAtOrAboveHundredEvenInsideGuard() {
        #expect(UsageRules.status(of: window(used: 100, elapsed: 0.02), at: now) == .limited)
        #expect(UsageRules.status(of: window(used: 112, elapsed: 0.5), at: now) == .limited)
    }

    @Test func windowWithoutDurationIsOnTrackUnlessLimited() {
        let unknown = UsageWindow(id: "x", label: "x", usedPercent: 99, resetsAt: now.addingTimeInterval(60), duration: nil)
        #expect(UsageRules.status(of: unknown, at: now) == .onTrack)
        #expect(UsageRules.pace(of: unknown, at: now) == nil)
    }

    @Test func subscriptionTakesWorstWindowAndHeadlinesIt() throws {
        let calm = window(used: 10, elapsed: 0.5, id: "calm")
        let hot = window(used: 70, elapsed: 0.5, id: "hot")
        let low = window(used: 45, elapsed: 0.5, id: "low")
        let snapshot = UsageSnapshot(windows: [calm, low, hot], planName: nil, fetchedAt: now, source: .live)
        #expect(UsageRules.status(of: snapshot, at: now) == .atRisk)
        #expect(try #require(UsageRules.headlineWindow(of: snapshot, at: now)).id == "hot")

        let onTrack = UsageSnapshot(windows: [calm, low], planName: nil, fetchedAt: now, source: .live)
        #expect(try #require(UsageRules.headlineWindow(of: onTrack, at: now)).id == "low")
    }

    @Test func expiredWindowReadsAsFreshlyReset() throws {
        let past = UsageWindow(id: "s", label: "s", usedPercent: 100, resetsAt: now.addingTimeInterval(-3600), duration: 5 * 3600)
        let current = past.current(at: now)
        #expect(current.usedPercent == 0)
        #expect(try #require(current.resetsAt) == now.addingTimeInterval(4 * 3600))
    }
}

@Suite struct MenuBarModeRulesTests {
    let now = Date(timeIntervalSince1970: 1_793_491_200)

    func window(_ id: String, used: Double, hours: Double, elapsedHours: Double) -> UsageWindow {
        UsageWindow(id: id, label: id, usedPercent: used, resetsAt: now.addingTimeInterval((hours - elapsedHours) * 3600), duration: hours * 3600)
    }

    func snapshot(_ windows: [UsageWindow]) -> UsageSnapshot {
        UsageSnapshot(windows: windows, planName: nil, fetchedAt: now, source: .live)
    }

    @Test func worstOfPrefersWorstStatusThenLeastRemaining() {
        let relaxed = snapshot([window("session", used: 70, hours: 5, elapsedHours: 4.5)])      // 30% left, on track
        let atRisk = snapshot([window("session", used: 50, hours: 5, elapsedHours: 1)])         // 50% left, at risk
        let tight = snapshot([window("weekly", used: 85, hours: 168, elapsedHours: 160)])      // 15% left, on track
        #expect(UsageRules.mostConstrained([(relaxed, false), (atRisk, false), (tight, false)], at: now) == 1)
        #expect(UsageRules.mostConstrained([(relaxed, false), (tight, false)], at: now) == 1)
        // Stale data only wins when nothing is fresh; items without data are skipped.
        #expect(UsageRules.mostConstrained([(relaxed, false), (atRisk, true), (nil, false)], at: now) == 0)
        #expect(UsageRules.mostConstrained([(nil, false), (atRisk, true)], at: now) == 1)
        #expect(UsageRules.mostConstrained([(nil, false)], at: now) == nil)
    }

    @Test func miniBarsAreShortestThenLongest() {
        let session = window("session", used: 40, hours: 5, elapsedHours: 1)
        let weekly = window("weekly_all", used: 20, hours: 168, elapsedHours: 10)
        let scoped = window("weekly_scoped", used: 5, hours: 168, elapsedHours: 10)
        #expect(UsageRules.miniBarWindows(of: snapshot([weekly, scoped, session])).map(\.id) == ["session", "weekly_all"])
        #expect(UsageRules.miniBarWindows(of: snapshot([weekly, scoped])).map(\.id) == ["weekly_all"])
        let untimed = UsageWindow(id: "credits", label: "credits", usedPercent: 3, resetsAt: nil, duration: nil)
        #expect(UsageRules.miniBarWindows(of: snapshot([untimed])).map(\.id) == ["credits"])
        #expect(UsageRules.miniBarWindows(of: snapshot([])).isEmpty)
    }
}
