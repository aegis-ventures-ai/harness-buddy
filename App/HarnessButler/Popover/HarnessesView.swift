import HarnessButlerKit
import SwiftUI

/// Harness versions, install methods and click-to-update (H-1…H-4, H-7).
struct HarnessesView: View {
    let store: UsageStore
    let harnesses: HarnessStore
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let shown = Harness.allCases.filter { harness in
                harnesses.status(for: harness).installation != nil || store.subscriptions.contains { $0.harness == harness }
            }
            if shown.isEmpty {
                Text(harnesses.lastDetection == nil ? "Looking for harnesses…" : "No harnesses found on this Mac.")
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
            ForEach(shown) { harness in
                HarnessRow(
                    harness: harness,
                    status: harnesses.status(for: harness),
                    run: harnesses.runs[harness],
                    profiles: store.subscriptions.filter { $0.harness == harness }.count,
                    now: now,
                    update: { harnesses.update(harness) },
                    cancel: { harnesses.cancelUpdate(harness) },
                    dismiss: { harnesses.dismissRun(harness) }
                )
                if harness != shown.last { Divider().padding(.leading, 46) }
            }
            Divider()
            HStack {
                if harnesses.isChecking {
                    ProgressView().controlSize(.mini)
                    Text("checking…")
                } else if let lastCheck = harnesses.lastCheck {
                    Text("last checked \(Format.age(lastCheck, now: now).replacingOccurrences(of: " old", with: " ago"))")
                }
                Spacer()
                Text("checks every \(Int(HarnessStore.checkInterval / 3600))h")
            }
            .font(Theme.mono(10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

private struct HarnessRow: View {
    let harness: Harness
    let status: HarnessStatus
    let run: UpdateRun?
    let profiles: Int
    let now: Date
    let update: () -> Void
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                HarnessAvatar(harness: harness)
                VStack(alignment: .leading, spacing: 3) {
                    Text(harness.displayName).font(Theme.mono(12, weight: .semibold))
                    versionLine.font(Theme.mono(11))
                    Text(pathLine).font(Theme.mono(10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    if let error = status.checkError, run == nil {
                        Text(error).font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                actions
            }
            if let run {
                UpdateLogView(run: run)
            } else if status.isUpdateAvailable {
                notes
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var versionLine: some View {
        if let run, run.isRunning {
            HStack(spacing: 0) {
                Text("updating")
                if let target = run.targetVersion {
                    Text(" to ")
                    Text(target.description).foregroundStyle(Theme.accent)
                }
                Text("…")
            }
            .foregroundStyle(.secondary)
        } else if let installation = status.installation {
            let installed = installation.version?.description ?? "unknown version"
            HStack(spacing: 0) {
                if status.isUpdateAvailable, let latest = status.latest {
                    Text("\(installed) → ")
                    Text(latest.description).foregroundStyle(Theme.accent)
                } else if status.latest != nil {
                    Text("\(installed) · ")
                    Text("up to date").foregroundStyle(Theme.ok)
                } else {
                    Text(installed)
                }
                Text(" · \(installation.method.displayName)")
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            Text("not installed").foregroundStyle(.secondary)
        }
    }

    private var pathLine: String {
        if let run, run.isRunning { return "running: \(run.command.displayString)" }
        guard let installation = status.installation else { return "\(profiles) profile\(profiles == 1 ? "" : "s")" }
        var parts = [PathFormatting.abbreviate(installation.binary.path(percentEncoded: false))]
        parts.append("\(profiles) profile\(profiles == 1 ? "" : "s")")
        if status.runningProcesses > 0 { parts.append("\(status.runningProcesses) running") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        if let run {
            if run.isRunning {
                Button("Cancel", action: cancel).controlSize(.small)
            } else {
                Button("Done", action: dismiss).controlSize(.small)
            }
        } else if status.isUpdateAvailable {
            if let command = status.updateCommand {
                Button("Update", action: update)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Runs \(command.displayString)")
            } else {
                Text("update manually").font(Theme.mono(10)).foregroundStyle(.secondary)
            }
        }
    }

    /// What will run, and the H-7 warning about sessions that keep the old version.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let command = status.updateCommand {
                Text("runs: \(command.displayString)").foregroundStyle(.secondary)
            }
            if status.runningProcesses > 0 {
                let n = status.runningProcesses
                Label("\(n) \(harness.executableName) process\(n == 1 ? " is" : "es are") running and will keep the old version until restarted",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warn)
            }
        }
        .font(Theme.mono(10))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
        .padding(.leading, 32)
    }
}

/// Streamed updater output (mockup "update in progress").
private struct UpdateLogView: View {
    let run: UpdateRun

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(run.log.text)
                    .font(Theme.mono(10))
                    .foregroundStyle(color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("end")
            }
            .frame(height: 120)
            .defaultScrollAnchor(.bottom)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
            .onChange(of: run.log) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .padding(.leading, 32)
        .accessibilityLabel("Update output for \(run.harness.displayName)")
    }

    private var color: Color {
        switch run.state {
        case .running, .succeeded: Color(nsColor: NSColor(hex: 0xA9D8B8))
        case .failed: Theme.bad
        case .cancelled: .secondary
        }
    }
}

enum PathFormatting {
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalized = "/" + home
        return path.hasPrefix(normalized + "/") ? "~" + path.dropFirst(normalized.count) : path
    }
}
