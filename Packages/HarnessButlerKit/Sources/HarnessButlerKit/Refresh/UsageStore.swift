import Foundation
import Observation

/// Popover grouping (U-8).
public enum SubscriptionGroup: Int, CaseIterable, Sendable, Comparable {
    case atRisk
    case limited
    case onTrack
    case stale

    public var title: String {
        switch self {
        case .atRisk: "at risk"
        case .limited: "limited"
        case .onTrack: "on track"
        case .stale: "stale / error"
        }
    }

    public static func < (lhs: SubscriptionGroup, rhs: SubscriptionGroup) -> Bool { lhs.rawValue < rhs.rawValue }

    /// U-8 grouping. Errors and data older than `Harness.staleAfter` are stale; otherwise the worst window decides.
    /// A subscription with nothing yet (still loading) counts as on track.
    public static func classify(_ usage: SubscriptionUsage, harness: Harness, at now: Date) -> SubscriptionGroup {
        classify(usage, cadence: harness.cadence, at: now)
    }

    public static func classify(_ usage: SubscriptionUsage, cadence: UsageCadence, at now: Date) -> SubscriptionGroup {
        guard let snapshot = usage.snapshot else { return usage.issue == nil ? .onTrack : .stale }
        // Being rate-limited isn't an error while the last reading is still fresh enough.
        let tolerated: Bool = if case .rateLimited = usage.issue { true } else { false }
        if (usage.issue != nil && !tolerated) || now.timeIntervalSince(snapshot.fetchedAt) > cadence.staleAfter { return .stale }
        switch UsageRules.status(of: snapshot.current(at: now), at: now) {
        case .limited: return .limited
        case .atRisk: return .atRisk
        case .onTrack: return .onTrack
        }
    }
}

/// What the UI knows about one subscription.
public struct SubscriptionUsage: Sendable {
    /// Last good data, kept when later refreshes fail (NFR: resilience).
    public var snapshot: UsageSnapshot?
    public var issue: UsageIssue?
    public var refresh = RefreshState()

    public init(snapshot: UsageSnapshot? = nil, issue: UsageIssue? = nil) {
        self.snapshot = snapshot
        self.issue = issue
    }

    public var isLoading: Bool { snapshot == nil && issue == nil }
}

/// Owns subscriptions and their usage, and drives refreshes.
@MainActor
@Observable
public final class UsageStore {
    public private(set) var subscriptions: [Subscription] = []
    public private(set) var usage: [UUID: SubscriptionUsage] = [:]
    /// Paused while the Mac sleeps.
    public var isPaused = false
    /// Last persistence error, surfaced in Settings.
    public private(set) var saveError: String?

    @ObservationIgnored private let file: SubscriptionFile
    @ObservationIgnored private let cacheFile: UsageCacheFile
    @ObservationIgnored private var cacheSaveTask: Task<Void, Never>?
    @ObservationIgnored private let providers: [UsageProviderKey: any UsageProvider]
    /// Admin keys for API subscriptions (U-3).
    @ObservationIgnored public let secrets: any SecretStore
    /// Called with every new snapshot (alerts).
    @ObservationIgnored public var onSnapshot: ((Subscription, UsageSnapshot) -> Void)?
    /// U-10: where new snapshots are recorded, if history is available.
    @ObservationIgnored public var history: UsageHistory?
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let homeDirectory: URL
    /// Resolved during `start()`; shared with `HarnessStore`.
    @ObservationIgnored public private(set) var environment: HarnessEnvironment?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let scratchDirectory: URL
    @ObservationIgnored private let onBattery: @Sendable () -> Bool

    public init(
        file: SubscriptionFile = .standard,
        cacheFile: UsageCacheFile = .standard,
        providers: [any UsageProvider]? = nil,
        secrets: any SecretStore = KeychainSecretStore(),
        appVersion: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        onBattery: @escaping @Sendable () -> Bool = { PowerSource.shouldConserve }
    ) {
        self.file = file
        self.cacheFile = cacheFile
        self.secrets = secrets
        let all = providers ?? [
            ClaudeUsageProvider(), CodexAppServerUsageProvider(), GrokACPUsageProvider(),
            AnthropicAdminUsageProvider(secrets: secrets), OpenAIAdminUsageProvider(secrets: secrets),
        ]
        self.providers = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        self.appVersion = appVersion
        self.homeDirectory = homeDirectory
        self.onBattery = onBattery
        self.scratchDirectory = FileManager.default.temporaryDirectory.appending(path: "HarnessButler-cwd", directoryHint: .isDirectory)
    }

    // MARK: - Lifecycle

    /// Load (or discover, on first launch) subscriptions, then start refreshing.
    public func start() async {
        loadSubscriptions()
        restoreCache(now: .now)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        environment = await HarnessEnvironment.resolve(homeDirectory: homeDirectory)
        refreshAll(.launch)
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.refreshAll(.scheduled)
            }
        }
    }

    func loadSubscriptions() {
        do {
            if let saved = try file.load() {
                subscriptions = saved
            } else {
                subscriptions = SubscriptionDiscovery.discover(homeDirectory: homeDirectory)
                persist()
            }
        } catch {
            saveError = "Couldn't read saved subscriptions: \(error.localizedDescription)"
        }
    }

    /// Last good snapshots, and the back-off of subscriptions that were failing, from the cache file.
    func restoreCache(now: Date) {
        for (id, snapshot) in cacheFile.load() {
            guard let subscription = subscriptions.first(where: { $0.id == id }) else { continue }
            var entry = SubscriptionUsage(snapshot: subscription.api == nil ? snapshot : snapshot.applyingBudget(subscription.api?.monthlyBudget))
            // Treat the cached reading as the last attempt, so launch only re-reads stale data.
            if snapshot.fetchedAt <= now { entry.refresh.lastAttempt = snapshot.fetchedAt }
            usage[id] = entry
        }
        // Failing subscriptions keep their back-off step and any provider-imposed quiet period.
        for (id, record) in cacheFile.loadRetries() where subscriptions.contains(where: { $0.id == id }) {
            var entry = usage[id, default: SubscriptionUsage()]
            // Capped, so a bad value saved by an older build can't block reads for long.
            let blocked = record.blockedUntil.flatMap { $0 > now ? min($0, now.addingTimeInterval(RetryAfter.maximum)) : nil }
            guard record.lastAttempt >= (entry.refresh.lastAttempt ?? .distantPast) || blocked != nil else { continue }
            if record.lastAttempt <= now { entry.refresh.lastAttempt = max(record.lastAttempt, entry.refresh.lastAttempt ?? .distantPast) }
            entry.refresh.consecutiveFailures = record.failures
            entry.refresh.blockedUntil = blocked
            entry.issue = record.issue
            usage[id] = entry
        }
    }

    /// Stop polling and write the snapshot cache now (call on quit).
    public func stop() {
        ticker?.cancel()
        ticker = nil
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        try? cacheFile.save(usage.compactMapValues(\.snapshot), retries: retries)
    }

    /// Back-off of failing subscriptions (step and provider-imposed quiet period), persisted so a
    /// relaunch respects it.
    var retries: [UUID: RetryRecord] {
        let now = Date.now
        return usage.compactMapValues { entry in
            guard let issue = entry.issue, let last = entry.refresh.lastAttempt else { return nil }
            let blocked = entry.refresh.blockedUntil.flatMap { $0 > now ? $0 : nil }
            guard entry.refresh.consecutiveFailures > 0 || blocked != nil else { return nil }
            return RetryRecord(lastAttempt: last, failures: entry.refresh.consecutiveFailures, blockedUntil: blocked, issue: issue)
        }
    }

    /// When this subscription will next be read automatically, if it's waiting on a rate limit or back-off.
    public func nextAttempt(for id: UUID, now: Date = .now) -> Date? {
        guard let subscription = subscriptions.first(where: { $0.id == id }) else { return nil }
        let entry = usage(for: id)
        guard entry.issue != nil, !entry.refresh.inFlight else { return nil }
        let due = RefreshPolicy.nextDue(cadence: subscription.cadence, state: entry.refresh, snapshot: entry.snapshot, onBattery: onBattery())
        return due > now ? due : nil
    }

    // MARK: - Queries

    public var pinned: [Subscription] { subscriptions.filter(\.isPinned) }

    public func usage(for id: UUID) -> SubscriptionUsage { usage[id] ?? SubscriptionUsage() }

    public func group(for subscription: Subscription, at now: Date = .now) -> SubscriptionGroup {
        SubscriptionGroup.classify(usage(for: subscription.id), cadence: subscription.cadence, at: now)
    }

    /// True when the subscription's data is stale or errored (dims it in the menubar).
    public func isStale(_ subscription: Subscription, at now: Date = .now) -> Bool {
        group(for: subscription, at: now) == .stale
    }

    // MARK: - Refresh

    public func refreshAll(_ trigger: RefreshTrigger) {
        for subscription in subscriptions { refresh(subscription.id, trigger) }
    }

    public func refresh(_ id: UUID, _ trigger: RefreshTrigger) {
        guard !isPaused || trigger == .manual,
              let environment,
              let subscription = subscriptions.first(where: { $0.id == id }),
              let provider = providers[subscription.providerKey] else { return }
        var entry = usage(for: id)
        let now = Date.now
        guard RefreshPolicy.shouldRefresh(
            cadence: subscription.cadence, state: entry.refresh, snapshot: entry.snapshot,
            trigger: trigger, now: now, onBattery: onBattery()
        ) else { return }

        entry.refresh.inFlight = true
        usage[id] = entry
        let context = UsageFetchContext(
            environment: environment,
            now: now,
            acceptableCacheAge: RefreshPolicy.acceptableCacheAge(cadence: subscription.cadence, trigger: trigger),
            appVersion: appVersion,
            scratchDirectory: scratchDirectory
        )
        Task { [weak self] in
            let report = await provider.fetch(subscription, context: context)
            self?.apply(report, to: id)
        }
    }

    func apply(_ report: UsageReport, to id: UUID) {
        guard let subscription = subscriptions.first(where: { $0.id == id }) else { return }
        var entry = usage(for: id)
        RefreshPolicy.record(report, into: &entry.refresh, at: .now)
        var accepted: UsageSnapshot?
        if var snapshot = report.snapshot, snapshot.fetchedAt >= (entry.snapshot?.fetchedAt ?? .distantPast) {
            // The budget may have changed while the read was in flight.
            if let api = subscription.api { snapshot = snapshot.applyingBudget(api.monthlyBudget) }
            if snapshot != entry.snapshot { accepted = snapshot }
            entry.snapshot = snapshot
        }
        entry.issue = report.issue
        usage[id] = entry
        scheduleCacheSave()
        if let accepted {
            history?.record(accepted, for: id)
            onSnapshot?(subscription, accepted)
        }
    }

    /// Coalesce writes: at most one save every few seconds.
    private func scheduleCacheSave() {
        guard cacheSaveTask == nil else { return }
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.cacheSaveTask = nil
            try? self.cacheFile.save(self.usage.compactMapValues(\.snapshot), retries: self.retries)
        }
    }

    // MARK: - Editing (U-2, M-1)

    @discardableResult
    public func add(name: String, harness: Harness, homeOverride: String?) -> SubscriptionNameError? {
        if let error = SubscriptionNames.validate(name, among: subscriptions) { return error }
        let override = homeOverride.map(SubscriptionNames.normalized).flatMap { $0.isEmpty ? nil : $0 }
        let subscription = Subscription(name: SubscriptionNames.normalized(name), harness: harness, homeOverride: override)
        subscriptions.append(subscription)
        persist()
        refresh(subscription.id, .launch)
        return nil
    }

    /// U-3: adds an API-spend subscription and stores its Admin key in the Keychain.
    /// Returns a message when the name is invalid or the key can't be saved.
    @discardableResult
    public func addAPI(name: String, provider: APIProvider, key: String, monthlyBudget: Double?) -> String? {
        if let error = SubscriptionNames.validate(name, among: subscriptions) { return error.message }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = provider.keyProblem(key) { return problem }
        let subscription = Subscription.api(APIAccount(provider: provider, monthlyBudget: Self.validBudget(monthlyBudget)),
                                            name: SubscriptionNames.normalized(name))
        do {
            try secrets.write(key, account: subscription.id.uuidString)
        } catch {
            return "Couldn't save the key: \(error.message)"
        }
        subscriptions.append(subscription)
        persist()
        refresh(subscription.id, .launch)
        return nil
    }

    /// Replaces an API subscription's Admin key and reads again.
    @discardableResult
    public func replaceKey(_ id: UUID, with key: String) -> String? {
        guard let subscription = subscriptions.first(where: { $0.id == id }), let api = subscription.api else { return nil }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = api.provider.keyProblem(key) { return problem }
        do {
            try secrets.write(key, account: id.uuidString)
        } catch {
            return "Couldn't save the key: \(error.message)"
        }
        var entry = usage(for: id)
        entry.refresh = RefreshState()
        usage[id] = entry
        refresh(id, .launch)
        return nil
    }

    /// U-7: sets or clears the monthly budget; the budget window updates without a refetch.
    public func setBudget(_ id: UUID, _ budget: Double?) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }), subscriptions[index].api != nil else { return }
        subscriptions[index].api?.monthlyBudget = Self.validBudget(budget)
        persist()
        if var entry = usage[id], let snapshot = entry.snapshot {
            entry.snapshot = snapshot.applyingBudget(subscriptions[index].api?.monthlyBudget)
            usage[id] = entry
            scheduleCacheSave()
        }
    }

    /// Budgets from one cent to a trillion: outside that, percentages and pace stop meaning anything.
    public static let budgetRange: ClosedRange<Double> = 0.01...1e12

    static func validBudget(_ budget: Double?) -> Double? {
        guard let budget, budget.isFinite, budgetRange.contains(budget) else { return nil }
        return budget
    }

    @discardableResult
    public func rename(_ id: UUID, to name: String) -> SubscriptionNameError? {
        if let error = SubscriptionNames.validate(name, among: subscriptions, excluding: id) { return error }
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return nil }
        subscriptions[index].name = SubscriptionNames.normalized(name)
        persist()
        return nil
    }

    public func remove(_ id: UUID) {
        if subscriptions.first(where: { $0.id == id })?.api != nil {
            try? secrets.delete(account: id.uuidString)
        }
        subscriptions.removeAll { $0.id == id }
        usage[id] = nil
        history?.delete(subscription: id)
        persist()
        scheduleCacheSave()
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].isPinned = pinned
        persist()
    }

    /// Reorder within the pinned subset (Settings → Menubar); unpinned subscriptions keep their slots.
    public func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        subscriptions = SubscriptionOrdering.movingPinned(subscriptions, fromOffsets: source, toOffset: destination)
        persist()
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        subscriptions = SubscriptionOrdering.moving(subscriptions, fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        do {
            try file.save(subscriptions)
            saveError = nil
        } catch {
            saveError = "Couldn't save subscriptions: \(error.localizedDescription)"
        }
    }
}
