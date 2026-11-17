import HarnessButlerKit
import SwiftUI

/// U-9 detail: every window, source path, last refresh. History sparkline arrives with U-10 (M4).
struct SubscriptionDetailView: View {
    let store: UsageStore
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
                row("harness", subscription.harness.displayName)
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
                    ForEach(snapshot.windows) { window in
                        windowRow(window)
                    }
                    if let credits = snapshot.credits {
                        creditsRow(credits)
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
