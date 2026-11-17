import Foundation

public enum NodePackageManager: String, Sendable, Hashable {
    case npm, pnpm, bun
}

/// How a harness binary was installed. Decides where the latest version comes from (H-3)
/// and which command updates it (H-4). See requirements §5.2 and spikes 01–03.
public enum InstallMethod: Hashable, Sendable {
    /// Claude Code's native installer (`~/.local/share/claude/versions/<v>`).
    case claudeNative
    /// Grok Build's self-installer (`~/.grok/downloads/grok-<v>-…`).
    case grokInstaller
    case homebrewCask(token: String)
    case homebrewFormula(name: String)
    case nodeGlobal(NodePackageManager, package: String)
    /// Codex standalone install (`codex-package.json` next to `bin/`).
    case codexStandalone
    case unknown

    public var displayName: String {
        switch self {
        case .claudeNative: "native"
        case .grokInstaller: "self-installer"
        case .homebrewCask: "brew cask"
        case .homebrewFormula: "brew"
        case .nodeGlobal(let manager, _): manager.rawValue
        case .codexStandalone: "standalone"
        case .unknown: "unknown install"
        }
    }

    /// The npm package each harness ships as.
    static func nodePackage(for harness: Harness) -> String {
        switch harness {
        case .claude: "@anthropic-ai/claude-code"
        case .codex: "@openai/codex"
        case .grok: "@xai-official/grok"
        }
    }

    /// Classify from the binary's symlink-resolved path.
    /// - Parameter hasCodexPackageJSON: whether `codex-package.json` sits next to the resolved `bin/`.
    public static func classify(harness: Harness, resolvedPath: String, hasCodexPackageJSON: Bool = false) -> InstallMethod {
        if let token = resolvedPath.firstMatch(of: /\/Caskroom\/([^\/]+)\//)?.1 {
            return .homebrewCask(token: String(token))
        }
        if let name = resolvedPath.firstMatch(of: /\/Cellar\/([^\/]+)\//)?.1 {
            return .homebrewFormula(name: String(name))
        }
        if resolvedPath.contains("/node_modules/") {
            let manager: NodePackageManager =
                resolvedPath.contains("/.bun/") ? .bun
                : (resolvedPath.contains("/pnpm/") || resolvedPath.contains("/.pnpm/")) ? .pnpm
                : .npm
            return .nodeGlobal(manager, package: nodePackage(for: harness))
        }
        switch harness {
        case .claude where resolvedPath.contains("/claude/versions/"):
            return .claudeNative
        case .grok where resolvedPath.contains("/.grok/"):
            return .grokInstaller
        case .codex where hasCodexPackageJSON:
            return .codexStandalone
        default:
            return .unknown
        }
    }
}

/// A command to run, with a display form for the UI (`brew upgrade --cask codex`).
public struct HarnessCommand: Hashable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]

    public var displayString: String {
        ([executable.lastPathComponent] + arguments).joined(separator: " ")
    }
}

extension InstallMethod {
    /// H-4: the harness's own updater for this install method, or `nil` when we don't know a safe one.
    /// - Parameters:
    ///   - binary: the harness binary as found on `PATH`.
    ///   - locate: finds a helper (`brew`, `npm`, …) on the search path.
    public func updateCommand(binary: URL, locate: (String) -> URL?) -> HarnessCommand? {
        // Non-interactive: there's no terminal to answer prompts.
        let quiet = ["NONINTERACTIVE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "CODEX_NON_INTERACTIVE": "1"]
        switch self {
        case .claudeNative, .grokInstaller, .codexStandalone:
            return HarnessCommand(executable: binary, arguments: ["update"], environment: quiet)
        case .homebrewCask(let token):
            guard let brew = locate("brew") else { return nil }
            // Brew's local API cache goes stale (spike 02); refresh it as part of the upgrade.
            var env = quiet
            env["HOMEBREW_AUTO_UPDATE_SECS"] = "0"
            return HarnessCommand(executable: brew, arguments: ["upgrade", "--cask", token], environment: env)
        case .homebrewFormula(let name):
            guard let brew = locate("brew") else { return nil }
            var env = quiet
            env["HOMEBREW_AUTO_UPDATE_SECS"] = "0"
            return HarnessCommand(executable: brew, arguments: ["upgrade", name], environment: env)
        case .nodeGlobal(let manager, let package):
            guard let tool = locate(manager.rawValue) else { return nil }
            let arguments = switch manager {
            case .npm: ["install", "-g", "\(package)@latest"]
            case .pnpm: ["add", "-g", "\(package)@latest"]
            case .bun: ["add", "-g", "\(package)@latest"]
            }
            return HarnessCommand(executable: tool, arguments: arguments, environment: quiet)
        case .unknown:
            return nil
        }
    }

    /// H-3: where the latest version comes from. `channel` is the harness's own update channel.
    public func latestVersionSource(channel: String?) -> LatestVersionSource? {
        switch self {
        case .claudeNative:
            let channel = channel.flatMap { ["latest", "stable"].contains($0) ? $0 : nil } ?? "latest"
            return LatestVersionSource(url: URL(string: "https://downloads.claude.ai/claude-code-releases/\(channel)")!, format: .plainText)
        case .grokInstaller:
            let channel = channel.flatMap { ["stable", "alpha", "enterprise"].contains($0) ? $0 : nil } ?? "stable"
            return LatestVersionSource(url: URL(string: "https://x.ai/cli/\(channel)")!, format: .plainText)
        case .homebrewCask(let token):
            return LatestVersionSource(url: URL(string: "https://formulae.brew.sh/api/cask/\(token).json")!, format: .homebrewCask)
        case .homebrewFormula(let name):
            return LatestVersionSource(url: URL(string: "https://formulae.brew.sh/api/formula/\(name).json")!, format: .homebrewFormula)
        case .nodeGlobal(_, let package):
            return LatestVersionSource(url: URL(string: "https://registry.npmjs.org/\(package)/latest")!, format: .npm)
        case .codexStandalone:
            return LatestVersionSource(url: URL(string: "https://api.github.com/repos/openai/codex/releases/latest")!, format: .githubRelease)
        case .unknown:
            return nil
        }
    }
}

public struct LatestVersionSource: Hashable, Sendable {
    public enum Format: Sendable {
        case plainText, homebrewCask, homebrewFormula, npm, githubRelease
    }

    public var url: URL
    public var format: Format

    /// Pull the version out of a response body.
    public func parse(_ data: Data) -> SemanticVersion? {
        switch format {
        case .plainText:
            return SemanticVersion(String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        case .homebrewCask:
            // Cask versions can carry a build suffix after a comma ("1.2.3,abc").
            return json(data)?["version"].flatMap { $0 as? String }.flatMap { SemanticVersion($0.split(separator: ",").first.map(String.init) ?? $0) }
        case .homebrewFormula:
            return (json(data)?["versions"] as? [String: Any])?["stable"].flatMap { $0 as? String }.flatMap(SemanticVersion.init)
        case .npm:
            return json(data)?["version"].flatMap { $0 as? String }.flatMap(SemanticVersion.init)
        case .githubRelease:
            return json(data)?["tag_name"].flatMap { $0 as? String }.flatMap(SemanticVersion.init)
        }
    }

    private func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
