import Foundation
import Observation

/// What the app knows about one harness's install and updates.
public struct HarnessStatus: Sendable {
    public var installation: HarnessInstallation?
    public var latest: SemanticVersion?
    public var latestCheckedAt: Date?
    public var checkError: String?
    /// H-7: processes currently running this harness binary.
    public var runningProcesses = 0
    public var updateCommand: HarnessCommand?

    public init() {}

    public var isUpdateAvailable: Bool {
        guard let installed = installation?.version, let latest else { return false }
        return latest > installed
    }
}

/// One click-to-update run (H-4). Never started without a user action.
@MainActor
@Observable
public final class UpdateRun: Identifiable {
    public enum State: Equatable, Sendable {
        case running
        case succeeded(SemanticVersion?)
        case failed(String)
        case cancelled
    }

    public let id = UUID()
    public let harness: Harness
    public let command: HarnessCommand
    public let fromVersion: SemanticVersion?
    public let targetVersion: SemanticVersion?
    public internal(set) var log = TerminalLog()
    public internal(set) var state: State = .running
    @ObservationIgnored var task: Task<Void, Never>?

    init(harness: Harness, command: HarnessCommand, fromVersion: SemanticVersion?, targetVersion: SemanticVersion?) {
        self.harness = harness
        self.command = command
        self.fromVersion = fromVersion
        self.targetVersion = targetVersion
    }

    public var isRunning: Bool { state == .running }
}

/// Detects installed harnesses, checks for newer versions (H-1…H-3) and runs updates (H-4).
@MainActor
@Observable
public final class HarnessStore {
    public private(set) var statuses: [Harness: HarnessStatus] = [:]
    public private(set) var runs: [Harness: UpdateRun] = [:]
    public private(set) var lastCheck: Date?
    public private(set) var lastDetection: Date?
    public private(set) var isChecking = false

    /// Latest-version lookups run this often (spike 01: 6–12 h).
    public static let checkInterval: TimeInterval = 6 * 3600

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var environment: HarnessEnvironment?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(session: URLSession = .shared, appVersion: String) {
        self.session = session
        self.appVersion = appVersion
    }

    public func start(environment: HarnessEnvironment) {
        self.environment = environment
        Task { await refresh(force: true) }
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                await self?.refresh(force: false)
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        for run in runs.values { run.task?.cancel() }
    }

    public func status(for harness: Harness) -> HarnessStatus { statuses[harness] ?? HarnessStatus() }

    public var updatesAvailable: [Harness] {
        Harness.allCases.filter { status(for: $0).isUpdateAvailable }
    }

    // MARK: - Checking

    /// Re-detect installs and, when due (or forced), look up the latest versions.
    public func refresh(force: Bool) async {
        guard let environment, !isChecking else { return }
        let now = Date.now
        let latestDue = force || lastCheck.map { now.timeIntervalSince($0) >= Self.checkInterval } ?? true
        // Re-detecting spawns three `--version` processes; don't repeat it within a minute.
        if !latestDue, let lastDetection, now.timeIntervalSince(lastDetection) < 60 { return }
        isChecking = true
        defer { isChecking = false }

        async let claude = HarnessDetector.detect(.claude, environment: environment, now: now)
        async let codex = HarnessDetector.detect(.codex, environment: environment, now: now)
        async let grok = HarnessDetector.detect(.grok, environment: environment, now: now)
        let installations: [Harness: HarnessInstallation?] = [.claude: await claude, .codex: await codex, .grok: await grok]
        lastDetection = now

        var latestResults: [Harness: Result<SemanticVersion, LatestVersionError>] = [:]
        if latestDue {
            await withTaskGroup(of: (Harness, Result<SemanticVersion, LatestVersionError>)?.self) { group in
                for (harness, installation) in installations {
                    guard let installation, let source = installation.method.latestVersionSource(channel: installation.channel) else { continue }
                    group.addTask { [session, appVersion] in
                        (harness, await Self.fetchLatest(source, session: session, appVersion: appVersion))
                    }
                }
                for await result in group {
                    if let (harness, value) = result { latestResults[harness] = value }
                }
            }
            lastCheck = now
        }

        let ownChildren = ChildProcessRegistry.shared.pids
        for harness in Harness.allCases {
            var status = self.status(for: harness)
            status.installation = installations[harness] ?? nil
            if let installation = status.installation {
                status.updateCommand = installation.method.updateCommand(binary: installation.binary) { environment.locate($0) }
                status.runningProcesses = RunningProcesses.count(executable: installation.resolvedBinary, excluding: ownChildren)
                if installation.method.latestVersionSource(channel: installation.channel) == nil {
                    status.checkError = "Unknown install method; update it the way you installed it"
                }
            } else {
                status.updateCommand = nil
                status.runningProcesses = 0
            }
            switch latestResults[harness] {
            case .success(let version):
                status.latest = version
                status.latestCheckedAt = now
                status.checkError = nil
            case .failure(let error):
                status.checkError = error.message
            case nil:
                break
            }
            statuses[harness] = status
        }
    }

    public enum LatestVersionError: Error, Sendable {
        case network(String)
        case http(Int)
        case unparseable

        public var message: String {
            switch self {
            case .network: "Couldn't check for updates (offline?)"
            case .http(let code): "Update check failed (HTTP \(code))"
            case .unparseable: "Update check returned an unexpected response"
            }
        }
    }

    nonisolated static func fetchLatest(_ source: LatestVersionSource, session: URLSession, appVersion: String) async -> Result<SemanticVersion, LatestVersionError> {
        var request = URLRequest(url: source.url, timeoutInterval: 15)
        request.setValue("HarnessButler/\(appVersion)", forHTTPHeaderField: "User-Agent")
        if source.format == .githubRelease { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .failure(.http(status)) }
            guard let version = source.parse(data) else { return .failure(.unparseable) }
            return .success(version)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    // MARK: - Updating (H-4)

    /// Run the harness's own updater. Only call from an explicit user action.
    public func update(_ harness: Harness) {
        guard let environment, runs[harness]?.isRunning != true else { return }
        let status = status(for: harness)
        guard let command = status.updateCommand else { return }

        let run = UpdateRun(harness: harness, command: command, fromVersion: status.installation?.version, targetVersion: status.latest)
        run.log.appendLine("$ \(command.displayString)")
        runs[harness] = run

        let (stream, continuation) = AsyncStream<String>.makeStream()
        run.task = Task { [weak self] in
            let consumer = Task { @MainActor in
                for await chunk in stream { run.log.append(chunk) }
            }
            let result: StreamingResult?
            do {
                result = try await StreamingProcess.run(
                    command.executable,
                    arguments: command.arguments,
                    environment: environment.environment(adding: command.environment),
                    currentDirectory: environment.homeDirectory,
                    onOutput: { continuation.yield($0) }
                )
            } catch {
                result = nil
                continuation.yield("\nCouldn't start \(command.executable.lastPathComponent): \(error)\n")
            }
            continuation.finish()
            await consumer.value

            // Confirm with a fresh `--version` (mockup: "re-runs --version to confirm").
            let installation = await HarnessDetector.detect(harness, environment: environment)
            self?.finish(run, result: result, installation: installation)
        }
    }

    public func cancelUpdate(_ harness: Harness) {
        runs[harness]?.task?.cancel()
    }

    /// Hide a finished run's log.
    public func dismissRun(_ harness: Harness) {
        if runs[harness]?.isRunning == false { runs[harness] = nil }
    }

    private func finish(_ run: UpdateRun, result: StreamingResult?, installation: HarnessInstallation?) {
        var status = status(for: run.harness)
        if let installation {
            status.installation = installation
            status.runningProcesses = RunningProcesses.count(executable: installation.resolvedBinary, excluding: ChildProcessRegistry.shared.pids)
        }
        statuses[run.harness] = status
        run.state = Self.outcome(result: result, from: run.fromVersion, target: run.targetVersion, now: installation?.version)
        switch run.state {
        case .succeeded(let version): run.log.appendLine("✓ \(run.harness.displayName) is now \(version.map(\.description) ?? "updated")")
        case .failed(let message): run.log.appendLine("✗ \(message)")
        case .cancelled: run.log.appendLine("Cancelled")
        case .running: break
        }
    }

    /// Decide how an update went from the exit status and a fresh `--version`.
    nonisolated static func outcome(result: StreamingResult?, from: SemanticVersion?, target: SemanticVersion?, now: SemanticVersion?) -> UpdateRun.State {
        guard let result else { return .failed("The updater couldn't be started") }
        if result.cancelled { return .cancelled }
        if result.timedOut { return .failed("The updater took longer than 10 minutes and was stopped") }
        guard result.exitCode == 0 else { return .failed("The updater exited with status \(result.exitCode)") }
        guard let now else { return .failed("Updated, but the new version couldn't be read") }
        if let target, now >= target { return .succeeded(now) }
        if let from, now > from { return .succeeded(now) }
        return .failed("The updater finished, but the installed version is still \(now)")
    }
}
