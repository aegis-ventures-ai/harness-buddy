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
        guard let snapshot = usage.snapshot else { return usage.issue == nil ? .onTrack : .stale }
        if usage.issue != nil || now.timeIntervalSince(snapshot.fetchedAt) > harness.staleAfter { return .stale }
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
    @ObservationIgnored private let providers: [Harness: any UsageProvider]
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let homeDirectory: URL
    @ObservationIgnored private var environment: HarnessEnvironment?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let scratchDirectory: URL
    @ObservationIgnored private let onBattery: @Sendable () -> Bool

    public init(
        file: SubscriptionFile = .standard,
        cacheFile: UsageCacheFile = .standard,
        providers: [any UsageProvider] = [ClaudeUsageProvider(), CodexAppServerUsageProvider(), GrokACPUsageProvider()],
        appVersion: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        onBattery: @escaping @Sendable () -> Bool = { PowerSource.shouldConserve }
    ) {
        self.file = file
        self.cacheFile = cacheFile
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.harness, $0) })
        self.appVersion = appVersion
        self.homeDirectory = homeDirectory
        self.onBattery = onBattery
        self.scratchDirectory = FileManager.default.temporaryDirectory.appending(path: "HarnessButler-cwd", directoryHint: .isDirectory)
    }

    // MARK: - Lifecycle

    /// Load (or discover, on first launch) subscriptions, then start refreshing.
    public func start() async {
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
        for (id, snapshot) in cacheFile.load() where subscriptions.contains(where: { $0.id == id }) {
            usage[id] = SubscriptionUsage(snapshot: snapshot)
        }
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

    /// Stop polling and write the snapshot cache now (call on quit).
    public func stop() {
        ticker?.cancel()
        ticker = nil
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        try? cacheFile.save(usage.compactMapValues(\.snapshot))
    }

    // MARK: - Queries

    public var pinned: [Subscription] { subscriptions.filter(\.isPinned) }

    public func usage(for id: UUID) -> SubscriptionUsage { usage[id] ?? SubscriptionUsage() }

    public func group(for subscription: Subscription, at now: Date = .now) -> SubscriptionGroup {
        SubscriptionGroup.classify(usage(for: subscription.id), harness: subscription.harness, at: now)
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
              let provider = providers[subscription.harness] else { return }
        var entry = usage(for: id)
        let now = Date.now
        guard RefreshPolicy.shouldRefresh(
            harness: subscription.harness, state: entry.refresh, snapshot: entry.snapshot,
            trigger: trigger, now: now, onBattery: onBattery()
        ) else { return }

        entry.refresh.inFlight = true
        usage[id] = entry
        let context = UsageFetchContext(
            environment: environment,
            now: now,
            acceptableCacheAge: RefreshPolicy.acceptableCacheAge(harness: subscription.harness, trigger: trigger),
            appVersion: appVersion,
            scratchDirectory: scratchDirectory
        )
        Task { [weak self] in
            let report = await provider.fetch(subscription, context: context)
            self?.apply(report, to: id)
        }
    }

    private func apply(_ report: UsageReport, to id: UUID) {
        guard subscriptions.contains(where: { $0.id == id }) else { return }
        var entry = usage(for: id)
        RefreshPolicy.record(report, into: &entry.refresh, at: .now)
        if let snapshot = report.snapshot, snapshot.fetchedAt >= (entry.snapshot?.fetchedAt ?? .distantPast) {
            entry.snapshot = snapshot
        }
        entry.issue = report.issue
        usage[id] = entry
        if report.snapshot != nil { scheduleCacheSave() }
    }

    /// Coalesce writes: at most one save every few seconds.
    private func scheduleCacheSave() {
        guard cacheSaveTask == nil else { return }
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.cacheSaveTask = nil
            try? self.cacheFile.save(self.usage.compactMapValues(\.snapshot))
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

    @discardableResult
    public func rename(_ id: UUID, to name: String) -> SubscriptionNameError? {
        if let error = SubscriptionNames.validate(name, among: subscriptions, excluding: id) { return error }
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return nil }
        subscriptions[index].name = SubscriptionNames.normalized(name)
        persist()
        return nil
    }

    public func remove(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        usage[id] = nil
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
