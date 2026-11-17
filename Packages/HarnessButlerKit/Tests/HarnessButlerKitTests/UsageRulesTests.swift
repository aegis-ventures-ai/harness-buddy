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
