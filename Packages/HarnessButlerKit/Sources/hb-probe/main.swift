// Dev tool: discover subscriptions (or load the app's saved list) and print one live read of each.
// Prints percentages, reset times and plan names only; never tokens or account identifiers.
import Foundation
import HarnessButlerKit

let home = FileManager.default.homeDirectoryForCurrentUser
let subscriptions = (try? SubscriptionFile.standard.load()) ?? SubscriptionDiscovery.discover(homeDirectory: home)
let environment = await HarnessEnvironment.resolve(homeDirectory: home)
let scratch = FileManager.default.temporaryDirectory.appending(path: "HarnessButler-cwd", directoryHint: .isDirectory)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
let providers: [Harness: any UsageProvider] = [
    .claude: ClaudeUsageProvider(), .codex: CodexAppServerUsageProvider(), .grok: GrokACPUsageProvider(),
]
let forceLive = CommandLine.arguments.contains("--live")
// --offline-codex: hide the codex binary to exercise the session-log fallback.
let offlineCodex = CommandLine.arguments.contains("--offline-codex")
let claude = ClaudeUsageProvider()

// --harnesses: detect installs and check latest versions (never runs an update).
if CommandLine.arguments.contains("--harnesses") {
    let store = HarnessStore(appVersion: "probe")
    store.start(environment: environment)
    try? await Task.sleep(for: .seconds(1))
    await store.refresh(force: true)
    for harness in Harness.allCases {
        let status = store.status(for: harness)
        guard let install = status.installation else { print("\n\(harness.displayName): not installed"); continue }
        print("\n\(harness.displayName): \(install.binary.path(percentEncoded: false)) -> \(install.resolvedBinary.path(percentEncoded: false))")
        print("  version: \(install.version.map(\.description) ?? "?")  (\(install.versionOutput ?? "no output"))  method: \(install.method.displayName)  channel: \(install.channel ?? "-")")
        print("  latest: \(status.latest.map(\.description) ?? "?")  update available: \(status.isUpdateAvailable)  running: \(status.runningProcesses)")
        print("  update command: \(status.updateCommand?.displayString ?? "none")\(status.checkError.map { "  error: \($0)" } ?? "")")
    }
    store.stop()
    exit(0)
}

for subscription in subscriptions {
    let now = Date.now
    let env = offlineCodex && subscription.harness == .codex
        ? HarnessEnvironment(homeDirectory: home, searchPath: [], baseEnvironment: environment.baseEnvironment)
        : environment
    let context = UsageFetchContext(
        environment: env, now: now,
        acceptableCacheAge: forceLive ? 0 : subscription.harness.refreshInterval,
        appVersion: "probe", scratchDirectory: scratch
    )
    let started = ContinuousClock.now
    let report = await providers[subscription.harness]!.fetch(subscription, context: context)
    print("\n\(subscription.name)  [\(subscription.harness.displayName)]  \(subscription.sourceDescription())  (\(ContinuousClock.now - started))")
    if subscription.harness == .claude {
        let changed = claude.credentialModificationDate(for: subscription, environment: environment)
        print("  credential last changed: \(changed.map { "\(Int(now.timeIntervalSince($0) / 60))m ago" } ?? "unknown")")
    }
    if let snapshot = report.snapshot {
        let current = snapshot.current(at: now)
        print("  plan: \(snapshot.planName ?? "?")  source: \(snapshot.source.rawValue)  fetched: \(Int(now.timeIntervalSince(snapshot.fetchedAt)))s ago  status: \(UsageRules.status(of: current, at: now))")
        for window in current.windows {
            let pace = UsageRules.pace(of: window, at: now).map { String(format: "%+.0f", $0.deltaPercent) } ?? "–"
            print("  - \(window.label): \(Int(window.usedPercent))% used, resets \(window.resetsAt?.formatted(.relative(presentation: .named)) ?? "?"), pace \(pace)")
        }
        if let credits = snapshot.credits { print("  credits: \(credits.usedMinor)/\(credits.limitMinor ?? 0) \(credits.currency) minor units") }
    }
    if let issue = report.issue { print("  issue: \(issue.message)") }
}
ChildProcessRegistry.shared.terminateAll()
