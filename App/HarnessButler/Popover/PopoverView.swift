import HarnessButlerKit
import SwiftUI

/// The left-click popover: subscriptions grouped by status (U-8), with a per-subscription detail page (U-9).
struct PopoverView: View {
    typealias Page = PopoverNavigation.Page

    let store: UsageStore
    let harnesses: HarnessStore
    let navigation: PopoverNavigation
    let openSettings: (SettingsPage?) -> Void

    private var page: Page {
        get { navigation.page }
        nonmutating set { navigation.page = newValue }
    }

    private var selection: UUID? {
        get { navigation.selection }
        nonmutating set { navigation.selection = newValue }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Group {
                if let id = selection, let subscription = store.subscriptions.first(where: { $0.id == id }) {
                    SubscriptionDetailView(store: store, harnesses: harnesses, subscription: subscription, now: context.date) { selection = nil }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        pagePicker
                        Divider()
                        switch page {
                        case .usage: list(now: context.date)
                        case .harnesses: HarnessesView(store: store, harnesses: harnesses, now: context.date) { harness in
                            let profile = ConfigProfile.profiles(for: store.subscriptions).first { $0.harness == harness }
                            openSettings(profile.map { .profile($0.id) } ?? .subscriptions)
                        }
                        }
                    }
                }
            }
        }
        .frame(width: 360)
        .font(Theme.mono(12))
    }

    private func list(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.subscriptions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let grouped = Dictionary(grouping: store.subscriptions) { store.group(for: $0, at: now) }
                        ForEach(SubscriptionGroup.allCases.filter { grouped[$0] != nil }, id: \.self) { group in
                            GroupHeader(group: group, count: grouped[group]?.count ?? 0)
                            ForEach(grouped[group] ?? []) { subscription in
                                SubscriptionRow(store: store, subscription: subscription, now: now)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selection = subscription.id }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(page == .usage ? "subscriptions" : "harnesses").font(Theme.mono(12, weight: .semibold))
            Text("\(page == .usage ? store.subscriptions.count : installedHarnessCount)").foregroundStyle(.secondary)
            Spacer()
            Button {
                switch page {
                case .usage: store.refreshAll(.manual)
                case .harnesses: Task { await harnesses.refresh(force: true) }
                }
            } label: { Image(systemName: "arrow.clockwise") }
                .disabled(page == .harnesses && harnesses.isChecking)
                .help(page == .usage ? "Refresh all (at most once a minute per subscription)" : "Check for harness updates now")
            Button { openSettings(nil) } label: { Image(systemName: "gearshape") }
                .help("Settings")
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var installedHarnessCount: Int {
        Harness.allCases.filter { harnesses.status(for: $0).installation != nil }.count
    }

    /// "usage | harnesses ●N" (mockup).
    private var pagePicker: some View {
        HStack(spacing: 4) {
            pageButton("usage", page: .usage, badge: 0)
            pageButton("harnesses", page: .harnesses, badge: harnesses.updatesAvailable.count)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func pageButton(_ title: String, page target: Page, badge: Int) -> some View {
        Button {
            page = target
            if target == .harnesses { Task { await harnesses.refresh(force: false) } }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if badge > 0 {
                    Text("●\(badge)").foregroundStyle(Theme.accent)
                        .accessibilityLabel("\(badge) update\(badge == 1 ? "" : "s") available")
                }
            }
            .font(Theme.mono(11, weight: page == target ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(page == target ? Color.primary.opacity(0.1) : .clear))
            .foregroundStyle(page == target ? Color.primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No subscriptions yet").font(Theme.mono(12, weight: .semibold))
            Text("Sign in to Claude Code, Codex or Grok Build, or add a config directory in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings") { openSettings(.subscriptions) }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

private struct GroupHeader: View {
    var group: SubscriptionGroup
    var count: Int

    var body: some View {
        HStack {
            Text(group.title.uppercased())
                .font(Theme.mono(10, weight: .semibold))
                .foregroundStyle(color)
            Text("\(count)").font(Theme.mono(10)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var color: Color {
        switch group {
        case .atRisk: Theme.warn
        case .limited: Theme.bad
        case .onTrack, .stale: .secondary
        }
    }
}

/// One subscription: name, plan, pin, % left, headline bar, pace, reset (U-4, U-5).
struct SubscriptionRow: View {
    let store: UsageStore
    let subscription: Subscription
    let now: Date

    var body: some View {
        let usage = store.usage(for: subscription.id)
        let snapshot = usage.snapshot?.current(at: now)
        let window = snapshot.flatMap { UsageRules.headlineWindow(of: $0, at: now) }
        let status = window.map { UsageRules.status(of: $0, at: now) } ?? .onTrack
        let pace = window.flatMap { UsageRules.pace(of: $0, at: now) }
        let stale = store.isStale(subscription, at: now)

        HStack(alignment: .top, spacing: 10) {
            HarnessAvatar(harness: subscription.harness)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(subscription.name).font(Theme.mono(12, weight: .semibold)).lineLimit(1)
                    if let plan = snapshot?.planName {
                        Text(plan).font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let window {
                        StatusRing(status: status, stale: stale)
                        Text("\(Format.percent(window.remainingPercent)) left")
                            .font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(status == .onTrack ? Color.primary : Theme.color(for: status, harness: subscription.harness))
                    } else if let spend = snapshot?.spend {
                        StatusRing(status: .onTrack, stale: stale)
                        Text("\(Format.dollars(spend.monthToDate, currency: spend.currency)) this month")
                            .font(Theme.mono(12, weight: .semibold))
                    } else if usage.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }
                if let window {
                    UsageBar(
                        remainingPercent: window.remainingPercent,
                        paceRemainingPercent: pace?.expectedRemainingPercent,
                        color: Theme.color(for: status, harness: subscription.harness)
                    )
                    HStack(spacing: 0) {
                        // Short pieces so the line fits: "weekly +2 · 41% behind      resets 2d 20h".
                        Text(metaLine(window: window, extraWindows: (snapshot?.windows.count ?? 1) - 1))
                            .foregroundStyle(.secondary)
                        if let pace {
                            Text(" · \(Format.pace(pace))")
                                .foregroundStyle(pace.deltaPercent > 0 ? Theme.warn : .secondary)
                        }
                        if let snapshot, stale || now.timeIntervalSince(snapshot.fetchedAt) > 10 * 60 {
                            Text(" · \(Format.age(snapshot.fetchedAt, now: now))").foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(Format.resetsShort(window.resetsAt, now: now)).foregroundStyle(.secondary).layoutPriority(1)
                    }
                    .font(Theme.mono(10))
                    .lineLimit(1)
                    .padding(.top, 3)
                } else if snapshot != nil, snapshot?.spend == nil, usage.issue == nil {
                    Text("No usage limits reported for this plan")
                        .font(Theme.mono(10))
                        .foregroundStyle(.secondary)
                } else if usage.isLoading {
                    Text("Loading…")
                        .font(Theme.mono(10))
                        .foregroundStyle(.secondary)
                }
                if let spend = snapshot?.spend {
                    SpendLine(spend: spend, budget: subscription.api?.monthlyBudget, now: now, showsReset: window == nil)
                }
                if let issue = usage.issue {
                    Text(IssueText.describe(issue, for: subscription, nextAttempt: store.nextAttempt(for: subscription.id, now: now), now: now))
                        .font(Theme.mono(10))
                        .foregroundStyle(IssueText.isMinor(issue, stale: stale) ? Theme.warn : Theme.bad)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(window: window))
    }

    /// The window's short name ("weekly" for "weekly · all models"), plus how many other windows there are.
    private func metaLine(window: UsageWindow, extraWindows: Int) -> String {
        let name = window.label.components(separatedBy: " · ").first ?? window.label
        return extraWindows > 0 ? "\(name) +\(extraWindows)" : name
    }

    private func accessibilityLabel(window: UsageWindow?) -> String {
        if window == nil, let spend = store.usage(for: subscription.id).snapshot?.spend {
            return "\(subscription.name), \(Format.dollars(spend.monthToDate, currency: spend.currency)) spent this month, projected \(Format.dollars(spend.projectedMonthEnd(at: now), currency: spend.currency))"
        }
        guard let window else { return "\(subscription.name), no data yet" }
        return "\(subscription.name), \(window.label), \(Int(window.remainingPercent.rounded())) percent left, \(Format.resets(window.resetsAt, now: now))"
    }
}

/// Row text for an issue, e.g. "Anthropic is rate-limiting usage reads · next try in 4m".
enum IssueText {
    static func describe(_ issue: UsageIssue, for subscription: Subscription, nextAttempt: Date?, now: Date) -> String {
        let base: String = if case .rateLimited = issue {
            "\(subscription.api?.provider.displayName ?? subscription.harness.providerName) is rate-limiting usage reads"
        } else {
            issue.message
        }
        guard let nextAttempt else { return base }
        return base + " · next try in \(Format.duration(max(60, nextAttempt.timeIntervalSince(now))))"
    }

    /// A rate limit while the last reading is still fresh: shown as a warning, not an error.
    static func isMinor(_ issue: UsageIssue, stale: Bool) -> Bool {
        if case .rateLimited = issue { return !stale }
        return false
    }
}

/// U-7: "$412 of $1,000 · $27/day · projected $830".
struct SpendLine: View {
    let spend: APISpend
    let budget: Double?
    let now: Date
    var showsReset = false

    var body: some View {
        let projected = spend.projectedMonthEnd(at: now)
        let overBudget = budget.map { projected > $0 } ?? false
        HStack(spacing: 0) {
            if let budget {
                Text("\(Format.dollars(spend.monthToDate, currency: spend.currency)) of \(Format.dollars(budget, currency: spend.currency)) · ")
            }
            Text("\(Format.dollars(spend.dailyRunRate(at: now), currency: spend.currency))/day · ")
            Text("projected \(Format.dollars(projected, currency: spend.currency))")
                .foregroundStyle(overBudget ? Theme.warn : .secondary)
            Spacer(minLength: 8)
            if showsReset {
                Text(Format.resetsShort(spend.periodEnd, now: now))
            }
        }
        .font(Theme.mono(10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct PinButton: View {
    let store: UsageStore
    let subscription: Subscription

    var body: some View {
        Button {
            store.setPinned(subscription.id, !subscription.isPinned)
        } label: {
            Image(systemName: subscription.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 9))
                .foregroundStyle(subscription.isPinned ? Theme.accent : .secondary)
        }
        .buttonStyle(.borderless)
        .help(subscription.isPinned ? "Shown in the menubar. Click to unpin." : "Pin to the menubar")
        .accessibilityLabel(subscription.isPinned ? "Unpin from menubar" : "Pin to menubar")
    }
}
