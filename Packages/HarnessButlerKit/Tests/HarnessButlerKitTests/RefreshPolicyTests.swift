import Foundation
import Testing
@testable import HarnessButlerKit

@Suite struct RefreshPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func state(lastAttempt: TimeInterval? = 0, failures: Int = 0, blockedFor: TimeInterval? = nil) -> RefreshState {
        var state = RefreshState()
        state.lastAttempt = lastAttempt.map { t0.addingTimeInterval($0) }
        state.consecutiveFailures = failures
        state.blockedUntil = blockedFor.map { t0.addingTimeInterval($0) }
        return state
    }

    func snapshot(age: TimeInterval, resetIn: TimeInterval? = nil) -> UsageSnapshot {
        UsageSnapshot(
            windows: [UsageWindow(id: "w", label: "w", usedPercent: 50, resetsAt: resetIn.map { t0.addingTimeInterval($0) }, duration: 3600)],
            planName: nil, fetchedAt: t0.addingTimeInterval(-age), source: .live
        )
    }

    func should(_ trigger: RefreshTrigger, _ harness: Harness = .claude, state: RefreshState, snapshot: UsageSnapshot? = nil, at offset: TimeInterval, battery: Bool = false) -> Bool {
        RefreshPolicy.shouldRefresh(harness: harness, state: state, snapshot: snapshot, trigger: trigger, now: t0.addingTimeInterval(offset), onBattery: battery)
    }

    @Test func scheduledCadencePerHarness() {
        #expect(!should(.scheduled, .claude, state: state(), at: 299))
        #expect(should(.scheduled, .claude, state: state(), at: 300))
        #expect(!should(.scheduled, .grok, state: state(), at: 600))
        #expect(should(.scheduled, .grok, state: state(), at: 720))
        #expect(should(.scheduled, state: state(lastAttempt: nil), at: 0))
    }

    @Test func batteryDoublesTheInterval() {
        #expect(!should(.scheduled, state: state(), at: 300, battery: true))
        #expect(should(.scheduled, state: state(), at: 600, battery: true))
    }

    @Test func refreshesRightAfterAWindowResets() {
        let snap = snapshot(age: 0, resetIn: 90)
        #expect(!should(.scheduled, state: state(), snapshot: snap, at: 90))
        #expect(should(.scheduled, state: state(), snapshot: snap, at: 95))
    }

    @Test func errorBackoffSteps() {
        #expect(!should(.scheduled, state: state(failures: 1), at: 299))
        #expect(should(.scheduled, state: state(failures: 1), at: 300))
        #expect(!should(.scheduled, state: state(failures: 2), at: 599))
        #expect(should(.scheduled, state: state(failures: 2), at: 600))
        #expect(!should(.scheduled, state: state(failures: 7), at: 1799))
        #expect(should(.scheduled, state: state(failures: 7), at: 1800))
    }

    @Test func retryAfterBlocksEverythingIncludingManual() {
        let blocked = state(failures: 1, blockedFor: 3600)
        #expect(!should(.manual, state: blocked, at: 120))
        #expect(!should(.scheduled, state: blocked, at: 1800))
        #expect(should(.scheduled, state: blocked, at: 3600))
    }

    @Test func manualLimitedToOncePerMinute() {
        #expect(!should(.manual, state: state(), at: 59))
        #expect(should(.manual, state: state(), at: 60))
    }

    @Test func popoverRefreshesOnlyStaleData() {
        #expect(!should(.popoverOpened, state: state(lastAttempt: -100), snapshot: snapshot(age: 0), at: 30)) // data 30 s old
        #expect(should(.popoverOpened, state: state(), snapshot: snapshot(age: 0), at: 70))     // data 70 s old
        #expect(!should(.popoverOpened, .grok, state: state(), snapshot: snapshot(age: 0), at: 120)) // Grok: 5 min
        #expect(should(.popoverOpened, .grok, state: state(), snapshot: snapshot(age: 0), at: 300))
    }

    @Test func popoverRespectsBackoffWhileFailing() {
        #expect(!should(.popoverOpened, state: state(failures: 1), at: 120))
    }

    @Test func inFlightBlocksDuplicates() {
        var busy = state(lastAttempt: nil)
        busy.inFlight = true
        #expect(!should(.launch, state: busy, at: 0))
    }

    @Test func recordingOutcomes() {
        var s = state(failures: 2, blockedFor: 10)
        s.inFlight = true
        RefreshPolicy.record(UsageReport(snapshot: nil, issue: .rateLimited(retryAfter: 120)), into: &s, at: t0)
        #expect(s.consecutiveFailures == 3)
        #expect(s.blockedUntil == t0.addingTimeInterval(120))
        #expect(!s.inFlight)
        RefreshPolicy.record(UsageReport(snapshot: snapshot(age: 0)), into: &s, at: t0)
        #expect(s.consecutiveFailures == 0)
        #expect(s.blockedUntil == nil)
    }
}
