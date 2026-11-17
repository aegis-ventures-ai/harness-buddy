// Dev tool: discover subscriptions (or load the app's saved list) and print one live read of each.
// Prints percentages, reset times and plan names only; never tokens or account identifiers.
import Foundation
import HarnessButlerKit

let home = FileManager.default.homeDirectoryForCurrentUser
var subscriptions = (try? SubscriptionFile.standard.load()) ?? SubscriptionDiscovery.discover(homeDirectory: home)
// --api-env anthropic|openai: read API spend with the Admin key in $HB_ADMIN_KEY (held in memory only,
// never printed). Without it, saved API subscriptions are skipped so the probe never reads the Keychain.
var secrets: any SecretStore = InMemorySecretStore()
if let index = CommandLine.arguments.firstIndex(of: "--api-env"), index + 1 < CommandLine.arguments.count,
   let provider = APIProvider(rawValue: CommandLine.arguments[index + 1]) {
    let key = ProcessInfo.processInfo.environment["HB_ADMIN_KEY"] ?? ""
    let subscription = Subscription.api(APIAccount(provider: provider, monthlyBudget: ProcessInfo.processInfo.environment["HB_BUDGET"].flatMap(Double.init)),
                                        name: provider.displayName)
    secrets = InMemorySecretStore([subscription.id.uuidString: key])
    subscriptions = [subscription]
} else {
    subscriptions.removeAll { $0.api != nil }
}
let environment = await HarnessEnvironment.resolve(homeDirectory: home)
let scratch = FileManager.default.temporaryDirectory.appending(path: "HarnessButler-cwd", directoryHint: .isDirectory)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
let providers: [UsageProviderKey: any UsageProvider] = [
    .harness(.claude): ClaudeUsageProvider(), .harness(.codex): CodexAppServerUsageProvider(), .harness(.grok): GrokACPUsageProvider(),
    .api(.anthropic): AnthropicAdminUsageProvider(secrets: secrets), .api(.openai): OpenAIAdminUsageProvider(secrets: secrets),
]
let forceLive = CommandLine.arguments.contains("--live")
// --offline-codex: hide the codex binary to exercise the session-log fallback.
let offlineCodex = CommandLine.arguments.contains("--offline-codex")
let claude = ClaudeUsageProvider()

// --config: parse each profile's config files in memory (never writes). Prints only whether they
// parse, how many MCP servers each has and which curated keys are set, never values.
if CommandLine.arguments.contains("--config") {
    for profile in ConfigProfile.profiles(for: subscriptions, homeDirectory: home) {
        print("\n\(profile.harness.displayName) · \(profile.subscriptionNames.count) subscription(s) · \(PathExpansion.abbreviate(profile.home.path(percentEncoded: false), homeDirectory: home))")
        for ref in profile.files(homeDirectory: home) {
            do {
                let state = try ConfigStore.read(ref)
                guard state.exists else { print("  \(ref.kind.fileName): missing (saving creates it)"); continue }
                let fields = CuratedSettings.general(profile.harness).filter { $0.file == ref.kind }
                let set = fields.filter { $0.value(in: state.original) != nil }.map(\.label)
                let mapping = MCPServerMapping.forHarness(profile.harness)
                let servers = mapping.file == ref.kind ? "\(mapping.servers(in: state.original).count) MCP server(s)" : ""
                var noOp = state.original
                try noOp.apply([])
                print("  \(ref.kind.fileName): parses ✓  round-trip identical: \(noOp.bytes == state.loaded?.bytes)  \(servers)  set: \(set.joined(separator: ", "))\(state.isSymlink ? "  (symlink)" : "")")
            } catch {
                print("  \(ref.kind.fileName): ✗ \(String(describing: error).prefix(200))")
            }
        }
    }
    exit(0)
}

// --extensions: the read-only hooks / plugins / skills inventory (C-8). Prints counts and
// event names only, never commands or descriptions.
if CommandLine.arguments.contains("--extensions") {
    for profile in ConfigProfile.profiles(for: subscriptions, homeDirectory: home) {
        let inventory = ExtensionsScanner.scan(profile, homeDirectory: home)
        print("\n\(profile.harness.displayName) · \(PathExpansion.abbreviate(profile.home.path(percentEncoded: false), homeDirectory: home))")
        print("  hooks: \(inventory.hooks.count) (events: \(Set(inventory.hooks.map(\.event)).sorted().joined(separator: ", ")))")
        print("  plugins: \(inventory.plugins.count) (enabled \(inventory.plugins.count { $0.isEnabled == true }), with version \(inventory.plugins.count { $0.version != nil }))")
        let origins = Dictionary(grouping: inventory.skills, by: \.origin).map { "\($0.key): \($0.value.count)" }.sorted()
        print("  skills: \(inventory.skills.count) (broken \(inventory.skills.count(where: \.isBroken)), described \(inventory.skills.count { !$0.description.isEmpty })) \(origins.joined(separator: ", "))")
        for problem in inventory.problems { print("  ✗ \(problem.prefix(200))") }
    }
    exit(0)
}

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
        // --notes: fetch the release notes for the latest version and show what would be displayed.
        if CommandLine.arguments.contains("--notes"), let target = status.latest ?? install.version {
            let source = ReleaseNotesSource.forHarness(harness, target: target)
            let started = ContinuousClock.now
            guard let entries = await HarnessStore.fetchReleaseNotes(source, session: .shared, appVersion: "probe") else {
                print("  notes: fetch failed (\(source.url))"); continue
            }
            print("  notes: \(entries.count) versions parsed (\(entries.map(\.version.description).prefix(6).joined(separator: ", "))…) in \(ContinuousClock.now - started)")
            let selected = ReleaseNotes.select(entries, installed: status.isUpdateAvailable ? install.version : nil, target: target, fullNotesURL: source.fullNotesURL)
            for entry in selected.entries.prefix(2) {
                print("  ## \(entry.version)\(entry.date.map { " (\($0))" } ?? "")  \(entry.itemCount) items")
                for block in entry.blocks.prefix(4) { print("     \(block)".prefix(140)) }
            }
            print("  partial: \(selected.isPartial)  full: \(selected.fullNotesURL)")
        }
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
        acceptableCacheAge: forceLive ? 0 : subscription.cadence.refreshInterval,
        appVersion: "probe", scratchDirectory: scratch
    )
    let started = ContinuousClock.now
    let report = await providers[subscription.providerKey]!.fetch(subscription, context: context)
    print("\n\(subscription.name)  [\(subscription.kindName)]  \(subscription.sourceDescription())  (\(ContinuousClock.now - started))")
    if subscription.harness == .claude, subscription.isHarnessLogin {
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
        if let spend = snapshot.spend {
            print(String(format: "  spend: %.2f %@ month to date, %.2f/day, projected %.2f; %d day(s) with spend; data through %@",
                         spend.monthToDate, spend.currency, spend.dailyRunRate(at: now), spend.projectedMonthEnd(at: now),
                         spend.daily.count, spend.dataThrough?.formatted() ?? "now"))
        }
        if let credits = snapshot.credits { print("  credits: \(credits.usedMinor)/\(credits.limitMinor ?? 0) \(credits.currency) minor units") }
    }
    if let issue = report.issue { print("  issue: \(issue.message)") }
}
ChildProcessRegistry.shared.terminateAll()
