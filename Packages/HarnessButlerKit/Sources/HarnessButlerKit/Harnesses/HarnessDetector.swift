import Foundation

/// A harness binary found on this Mac (H-1, H-2).
public struct HarnessInstallation: Hashable, Sendable {
    public var harness: Harness
    /// As found on the search path (e.g. `~/.local/bin/claude`).
    public var binary: URL
    /// Symlinks resolved (e.g. `~/.local/share/claude/versions/2.1.326`).
    public var resolvedBinary: URL
    public var version: SemanticVersion?
    /// Raw `--version` output, first line.
    public var versionOutput: String?
    public var method: InstallMethod
    /// The harness's own update channel (`latest`/`stable` for Claude, `stable`/`alpha` for Grok).
    public var channel: String?
    public var detectedAt: Date
}

public enum HarnessDetector {
    /// Find, resolve and version one harness. `nil` when it isn't installed.
    public static func detect(_ harness: Harness, environment: HarnessEnvironment, now: Date = .now) async -> HarnessInstallation? {
        let home = environment.homeDirectory
        let preferred: [URL] = switch harness {
        case .claude: [home.appending(path: ".local/bin/claude")]
        case .codex: []
        case .grok: [home.appending(path: ".grok/bin/grok")]
        }
        guard let binary = environment.locate(harness.executableName, preferring: preferred) else { return nil }
        let resolved = binary.resolvingSymlinksInPath()
        let packageJSON = resolved.deletingLastPathComponent().deletingLastPathComponent().appending(path: "codex-package.json")
        let method = InstallMethod.classify(
            harness: harness,
            resolvedPath: resolved.path(percentEncoded: false),
            hasCodexPackageJSON: harness == .codex && FileManager.default.fileExists(atPath: packageJSON.path(percentEncoded: false))
        )

        let output = await versionOutput(of: binary, environment: environment)
        var channel: String?
        switch harness {
        case .grok:
            // `grok 1.0.88 (2fe3608f7398) [stable]`
            channel = output?.firstMatch(of: /\[([a-z]+)\]/).map { String($0.1) }
        case .claude:
            channel = claudeChannel(homeDirectory: home)
        case .codex:
            channel = nil
        }

        return HarnessInstallation(
            harness: harness,
            binary: binary,
            resolvedBinary: resolved,
            version: output.flatMap(SemanticVersion.init),
            versionOutput: output,
            method: method,
            channel: channel,
            detectedAt: now
        )
    }

    static func versionOutput(of binary: URL, environment: HarnessEnvironment) async -> String? {
        guard let result = try? await ProcessRunner.run(
            binary,
            arguments: ["--version"],
            environment: environment.environment(adding: [
                "GROK_TELEMETRY_ENABLED": "0",
                "GROK_TELEMETRY_MIXPANEL_ENABLED": "false",
                "GROK_DISABLE_AUTOUPDATER": "1",
                "DISABLE_AUTOUPDATER": "1",
            ]),
            timeout: .seconds(10)
        ), result.exitCode == 0, !result.timedOut else { return nil }
        let text = String(decoding: result.stdout.isEmpty ? result.stderr : result.stdout, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// `autoUpdatesChannel` from the default Claude settings (only that key is read).
    static func claudeChannel(homeDirectory: URL) -> String? {
        let url = homeDirectory.appending(path: ".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["autoUpdatesChannel"] as? String
    }
}
