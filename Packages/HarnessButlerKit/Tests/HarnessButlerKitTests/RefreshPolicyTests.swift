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

@Suite struct RelaunchAndRateLimitTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func launch(lastAttemptAgo: TimeInterval?, blockedFor: TimeInterval? = nil) -> Bool {
        var state = RefreshState()
        state.lastAttempt = lastAttemptAgo.map { t0.addingTimeInterval(-$0) }
        state.blockedUntil = blockedFor.map { t0.addingTimeInterval($0) }
        return RefreshPolicy.shouldRefresh(harness: .claude, state: state, snapshot: nil, trigger: .launch, now: t0, onBattery: false)
    }

    @Test func launchOnlyReadsStaleData() {
        #expect(launch(lastAttemptAgo: nil))
        #expect(!launch(lastAttemptAgo: 60))          // read a minute ago (seeded from the cache)
        #expect(launch(lastAttemptAgo: 5 * 60))
        #expect(!launch(lastAttemptAgo: nil, blockedFor: 60))
    }

    @Test func rateLimitWithoutRetryAfterBlocksForTheBackoffStep() {
        var state = RefreshState()
        RefreshPolicy.record(.failure(.rateLimited(retryAfter: nil)), into: &state, at: t0)
        #expect(state.blockedUntil == t0.addingTimeInterval(5 * 60))
        RefreshPolicy.record(.failure(.rateLimited(retryAfter: nil)), into: &state, at: t0)
        #expect(state.blockedUntil == t0.addingTimeInterval(10 * 60))
        // Other failures back off through `nextDue` without a hard block.
        var other = RefreshState()
        RefreshPolicy.record(.failure(.unavailable("x")), into: &other, at: t0)
        #expect(other.blockedUntil == nil)
    }

    @Test func freshDataWhileRateLimitedIsNotAnError() {
        let window = UsageWindow(id: "w", label: "w", usedPercent: 10, resetsAt: t0.addingTimeInterval(86_400), duration: 7 * 86_400)
        func usage(age: TimeInterval) -> SubscriptionUsage {
            SubscriptionUsage(snapshot: UsageSnapshot(windows: [window], planName: nil, fetchedAt: t0.addingTimeInterval(-age), source: .live),
                              issue: .rateLimited(retryAfter: nil))
        }
        #expect(SubscriptionGroup.classify(usage(age: 4 * 60), harness: .claude, at: t0) == .onTrack)
        #expect(SubscriptionGroup.classify(usage(age: 31 * 60), harness: .claude, at: t0) == .stale)
    }

    @Test func retriesSurviveTheCacheFileAndOldBlocksStillLoad() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hb-blocks-\(UUID().uuidString)/usage-cache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = UsageCacheFile(url: url)
        let id = UUID()
        let record = RetryRecord(lastAttempt: t0, failures: 2, blockedUntil: nil, issue: .unavailable("Anthropic returned HTTP 500"))
        try cache.save([:], retries: [id: record])
        #expect(cache.loadRetries() == [id: record])
        try cache.save([:])
        #expect(cache.loadRetries().isEmpty)
        // Earlier builds wrote only rate-limit blocks.
        try Data(#"{"version":1,"snapshots":[],"blockedUntil":["\#(id.uuidString)","2027-01-15T08:00:00Z"]}"#.utf8).write(to: url)
        #expect(cache.loadRetries()[id]?.blockedUntil == (try Date("2027-01-15T08:00:00Z", strategy: .iso8601)))
    }
}

/// U-12: quitting and reopening the app while a provider is failing doesn't reset the back-off.
@MainActor
@Suite struct BackoffAcrossRelaunchTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "hb-relaunch-\(UUID().uuidString)")

    func makeStore() -> UsageStore {
        UsageStore(file: SubscriptionFile(url: dir.appending(path: "subscriptions.json")),
                   cacheFile: UsageCacheFile(url: dir.appending(path: "cache.json")),
                   providers: [], secrets: InMemorySecretStore(), appVersion: "test", homeDirectory: dir)
    }

    func relaunch() -> UsageStore {
        let store = makeStore()
        store.loadSubscriptions()
        store.restoreCache(now: .now)
        return store
    }

    func shouldReadOnLaunch(_ store: UsageStore, _ subscription: Subscription, at now: Date) -> Bool {
        let entry = store.usage(for: subscription.id)
        return RefreshPolicy.shouldRefresh(cadence: subscription.cadence, state: entry.refresh, snapshot: entry.snapshot,
                                           trigger: .launch, now: now, onBattery: false)
    }

    @Test func failuresWithoutDataKeepTheirStep() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore()
        store.addAPI(name: "Org", provider: .openai, key: "sk-admin-x", monthlyBudget: nil)
        let subscription = try #require(store.subscriptions.first)
        store.apply(.failure(.unavailable("OpenAI returned HTTP 500")), to: subscription.id)
        store.apply(.failure(.unavailable("OpenAI returned HTTP 500")), to: subscription.id)
        store.stop()

        let relaunched = relaunch()
        let entry = relaunched.usage(for: subscription.id)
        #expect(entry.refresh.consecutiveFailures == 2)
        #expect(entry.issue == .unavailable("OpenAI returned HTTP 500"))
        // Second step: 10 minutes (API cadence is 30, so the longer of the two applies).
        #expect(!shouldReadOnLaunch(relaunched, subscription, at: .now))
        #expect(shouldReadOnLaunch(relaunched, subscription, at: .now.addingTimeInterval(31 * 60)))
        #expect(relaunched.nextAttempt(for: subscription.id) != nil)
    }

    @Test func failuresAfterOldDataKeepTheirStep() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore()
        store.addAPI(name: "Org", provider: .openai, key: "sk-admin-x", monthlyBudget: nil)
        let subscription = try #require(store.subscriptions.first)
        let month = BillingMonth.containing(.now)
        let spend = APISpend(monthToDate: 1, daily: [], periodStart: month.start, periodEnd: month.end)
        let old = UsageSnapshot(windows: [], planName: nil, fetchedAt: .now.addingTimeInterval(-3 * 3600), source: .live, spend: spend)
        store.apply(UsageReport(snapshot: old), to: subscription.id)
        store.apply(.failure(.unavailable("Can't reach OpenAI")), to: subscription.id)
        store.stop()

        let relaunched = relaunch()
        #expect(relaunched.usage(for: subscription.id).snapshot != nil)
        #expect(relaunched.usage(for: subscription.id).refresh.consecutiveFailures == 1)
        #expect(!shouldReadOnLaunch(relaunched, subscription, at: .now))
    }

    @Test func successClearsTheRecord() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore()
        store.addAPI(name: "Org", provider: .openai, key: "sk-admin-x", monthlyBudget: nil)
        let subscription = try #require(store.subscriptions.first)
        store.apply(.failure(.unavailable("Can't reach OpenAI")), to: subscription.id)
        let month = BillingMonth.containing(.now)
        let spend = APISpend(monthToDate: 1, daily: [], periodStart: month.start, periodEnd: month.end)
        store.apply(UsageReport(snapshot: UsageSnapshot(windows: [], planName: nil, fetchedAt: .now, source: .live, spend: spend)), to: subscription.id)
        store.stop()
        #expect(store.retries.isEmpty)
        #expect(relaunch().usage(for: subscription.id).issue == nil)
    }
}
