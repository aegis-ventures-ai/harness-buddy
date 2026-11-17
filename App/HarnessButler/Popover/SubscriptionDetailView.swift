import Charts
import HarnessButlerKit
import SwiftUI

/// U-9 detail: every window, source path, last refresh, and for API subscriptions the spend (U-7).
struct SubscriptionDetailView: View {
    let store: UsageStore
    let harnesses: HarnessStore
    let subscription: Subscription
    let now: Date
    let back: () -> Void

    var body: some View {
        let usage = store.usage(for: subscription.id)
        let snapshot = usage.snapshot?.current(at: now)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                HarnessAvatar(harness: subscription.harness, size: 24)
                Text(subscription.name).font(Theme.mono(13, weight: .semibold)).lineLimit(1)
                if let plan = snapshot?.planName {
                    Text(plan).font(Theme.mono(10)).foregroundStyle(.secondary)
                }
                Spacer()
                PinButton(store: store, subscription: subscription)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if subscription.isHarnessLogin {
                    harnessRow
                }
                row("source", subscription.sourceDescription())
                if let snapshot {
                    row("updated", "\(Format.age(snapshot.fetchedAt, now: now)) · \(snapshot.source == .live ? "live" : "harness cache")")
                }
                if let issue = usage.issue {
                    GridRow {
                        Text("status").foregroundStyle(.secondary)
                        Text(issue.message).foregroundStyle(Theme.bad)
                    }
                }
            }
            .font(Theme.mono(11))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if let snapshot {
                VStack(alignment: .leading, spacing: 12) {
                    if let spend = snapshot.spend {
                        spendSection(spend)
                    }
                    ForEach(snapshot.windows) { window in
                        windowRow(window)
                    }
                    if let credits = snapshot.credits {
                        creditsRow(credits)
                    }
                    if let window = historyWindow(snapshot), let history = store.history {
                        Divider()
                        historyChart(window, history: history)
                    }
                }
                .padding(14)
            } else {
                Text(usage.isLoading ? "Loading…" : "No usage data yet.")
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
    }

    /// "Claude Code · claude 2.1.326 · update available" (mockup).
    private var harnessRow: some View {
        let status = harnesses.status(for: subscription.harness)
        return GridRow {
            Text("harness").foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Text(subscription.harness.displayName)
                if let version = status.installation?.version {
                    Text(" · \(subscription.harness.executableName) \(version.description)")
                } else if status.installation == nil, harnesses.lastDetection != nil {
                    Text(" · not installed").foregroundStyle(.secondary)
                }
                if status.isUpdateAvailable {
                    Text(" · update available").foregroundStyle(Theme.accent)
                }
            }
            .lineLimit(1)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2)
        }
    }

    private func windowRow(_ window: UsageWindow) -> some View {
        let status = UsageRules.status(of: window, at: now)
        let pace = UsageRules.pace(of: window, at: now)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label)
                Spacer()
                Text("\(Format.percent(window.remainingPercent)) left · \(Format.resets(window.resetsAt, now: now))")
                    .foregroundStyle(.secondary)
            }
            .font(Theme.mono(11))
            UsageBar(
                remainingPercent: window.remainingPercent,
                paceRemainingPercent: pace?.expectedRemainingPercent,
                color: Theme.color(for: status, harness: subscription.harness)
            )
            if let pace {
                Text(Format.pace(pace) + (status == .atRisk ? " · projected to run out before reset" : ""))
                    .font(Theme.mono(10))
                    .foregroundStyle(status == .atRisk ? Theme.warn : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subscription.name), \(window.label), \(Int(window.remainingPercent.rounded())) percent left, \(Format.resets(window.resetsAt, now: now))")
    }

    @ViewBuilder
    private func spendSection(_ spend: APISpend) -> some View {
        let budget = subscription.api?.monthlyBudget
        let money = { (amount: Double) in Format.dollars(amount, currency: spend.currency) }
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("month to date", money(spend.monthToDate))
                row("run rate", "\(money(spend.dailyRunRate(at: now))) per day")
                GridRow {
                    Text("projected").foregroundStyle(.secondary)
                    let projected = spend.projectedMonthEnd(at: now)
                    Text("\(money(projected)) by month end")
                        .foregroundStyle(budget.map { projected > $0 } == true ? Theme.warn : .primary)
                }
                row("budget", budget.map(money) ?? "none (set one in Settings → Subscriptions)")
                row("billing month", "\(spend.periodStart.formatted(.dateTime.month(.wide).year())) (UTC) · \(Format.resets(spend.periodEnd, now: now))")
                if let through = spend.dataThrough {
                    row("data through", "\(Format.age(through, now: now)) · providers report spend with a delay")
                }
            }
            .font(Theme.mono(11))
            dailyChart(spend)
        }
    }

    /// The last 7 UTC days of spend (U-9 sparkline for API subscriptions).
    private func dailyChart(_ spend: APISpend) -> some View {
        let days = spend.lastDays(7, at: now)
        return VStack(alignment: .leading, spacing: 3) {
            Text("last 7 days").font(Theme.mono(10)).foregroundStyle(.secondary)
            // Billing days are UTC days, so label them in UTC (7 consecutive days have distinct weekdays).
            Chart(days, id: \.day) { day in
                BarMark(x: .value("Day", day.day.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated))), y: .value("Spend", day.amount))
                    .foregroundStyle(Theme.color(for: subscription.harness))
                    .cornerRadius(2)
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(Format.compactDollars(amount, currency: spend.currency)) } }
                }
            }
            .font(Theme.mono(9))
            .frame(height: 64)
            .accessibilityLabel("Spend over the last 7 days: " + days.map { money(for: $0.amount, spend) }.joined(separator: ", "))
        }
    }

    /// The window the history sparkline follows: the longest one (usually weekly), as in the mockup.
    private func historyWindow(_ snapshot: UsageSnapshot) -> UsageWindow? {
        snapshot.windows.filter { $0.id != APISpend.budgetWindowID }.max { ($0.duration ?? 0) < ($1.duration ?? 0) }
    }

    /// U-9 sparkline: percent of the window used on each of the last 7 days, from U-10 history.
    private func historyChart(_ window: UsageWindow, history: UsageHistory) -> some View {
        let days = history.dailyUsage(subscription: subscription.id, window: window.id, days: 7, now: now)
        let today = Calendar.current.startOfDay(for: now)
        let color = Theme.color(for: subscription.harness)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(window.label) · last 7 days")
                Spacer()
                Text("% of window / day").foregroundStyle(.secondary)
            }
            .font(Theme.mono(10))
            if days.allSatisfy({ $0.percent == 0 }) {
                Text("History builds up while Harness Butler runs.")
                    .font(Theme.mono(10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            } else {
                Chart(days, id: \.day) { day in
                    BarMark(x: .value("Day", day.day.formatted(.dateTime.weekday(.abbreviated))), y: .value("Used", day.percent))
                        .foregroundStyle(day.day == today ? color : color.opacity(0.45))
                        .cornerRadius(2)
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                        AxisGridLine()
                        AxisValueLabel { if let percent = value.as(Double.self) { Text("\(Int(percent))%") } }
                    }
                }
                .font(Theme.mono(9))
                .frame(height: 64)
                .accessibilityLabel("\(window.label) used per day over the last 7 days: "
                    + days.map { "\($0.day.formatted(.dateTime.weekday(.wide))) \(Int($0.percent.rounded())) percent" }.joined(separator: ", "))
            }
        }
    }

    private func money(for amount: Double, _ spend: APISpend) -> String { Format.dollars(amount, currency: spend.currency) }

    private func creditsRow(_ credits: UsageCredits) -> some View {
        let used = Format.money(credits.usedMinor, exponent: credits.exponent, currency: credits.currency)
        let limit = credits.limitMinor.map { Format.money($0, exponent: credits.exponent, currency: credits.currency) }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("extra usage")
                Spacer()
                Text(limit.map { "\(used) of \($0)" } ?? used).foregroundStyle(.secondary)
            }
            .font(Theme.mono(11))
            if let limitMinor = credits.limitMinor, limitMinor > 0 {
                UsageBar(
                    remainingPercent: max(0, 100 - Double(credits.usedMinor) / Double(limitMinor) * 100),
                    paceRemainingPercent: nil,
                    color: Theme.accent,
                    height: 4
                )
            }
        }
    }
}
