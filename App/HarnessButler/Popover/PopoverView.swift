import HarnessButlerKit
import SwiftUI

/// The left-click popover: subscriptions grouped by status (U-8), with a per-subscription detail page (U-9).
struct PopoverView: View {
    enum Page: Hashable { case usage, harnesses }

    let store: UsageStore
    let harnesses: HarnessStore
    let openSettings: () -> Void
    @State private var selection: UUID?
    @State private var page: Page = Self.initialPage

    private static var initialPage: Page {
        #if DEBUG
        // `--open-popover harnesses` opens on the harnesses page (UI checks).
        if let index = CommandLine.arguments.firstIndex(of: "--open-popover"),
           CommandLine.arguments.dropFirst(index + 1).first == "harnesses" { return .harnesses }
        #endif
        return .usage
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
                        case .harnesses: HarnessesView(store: store, harnesses: harnesses, now: context.date)
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
            Button(action: openSettings) { Image(systemName: "gearshape") }
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
            Button("Open Settings", action: openSettings)
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
                    PinButton(store: store, subscription: subscription)
                    Spacer(minLength: 4)
                    if let window {
                        StatusRing(status: status, stale: stale)
                        Text("\(Format.percent(window.remainingPercent)) left")
                            .font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(status == .onTrack ? Color.primary : Theme.color(for: status, harness: subscription.harness))
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
                        // The window label gives way first; pace and reset time stay readable.
                        Text(metaLine(window: window, extraWindows: (snapshot?.windows.count ?? 1) - 1))
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                        if let pace {
                            Text(" · \(Format.pace(pace))")
                                .foregroundStyle(pace.deltaPercent > 0 ? Theme.warn : .secondary)
                                .layoutPriority(2)
                        }
                        if let snapshot, stale || now.timeIntervalSince(snapshot.fetchedAt) > 10 * 60 {
                            Text(" · \(Format.age(snapshot.fetchedAt, now: now))").foregroundStyle(.secondary).layoutPriority(2)
                        }
                        Spacer(minLength: 8)
                        Text(Format.resets(window.resetsAt, now: now)).foregroundStyle(.secondary).layoutPriority(1)
                    }
                    .font(Theme.mono(10))
                    .lineLimit(1)
                }
                if let issue = usage.issue {
                    Text(issue.message).font(Theme.mono(10)).foregroundStyle(Theme.bad).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(window: window))
    }

    private func metaLine(window: UsageWindow, extraWindows: Int) -> String {
        extraWindows > 0 ? "\(window.label) +\(extraWindows)" : window.label
    }

    private func accessibilityLabel(window: UsageWindow?) -> String {
        guard let window else { return "\(subscription.name), no data yet" }
        return "\(subscription.name), \(window.label), \(Int(window.remainingPercent.rounded())) percent left, \(Format.resets(window.resetsAt, now: now))"
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
