import Foundation

/// A local CLI agent whose subscription the app tracks.
public enum Harness: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case codex
    case grok

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok Build"
        }
    }

    public var providerName: String {
        switch self {
        case .claude: "Anthropic"
        case .codex: "OpenAI"
        case .grok: "xAI"
        }
    }

    /// The binary name on `PATH`.
    public var executableName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .grok: "grok"
        }
    }

    /// Environment variable that relocates the harness home (one login per value).
    public var homeEnvironmentVariable: String {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        case .grok: "GROK_HOME"
        }
    }

    /// Default home directory when the environment variable is unset.
    public func defaultHome(homeDirectory: URL) -> URL {
        switch self {
        case .claude: homeDirectory.appending(path: ".claude", directoryHint: .isDirectory)
        case .codex: homeDirectory.appending(path: ".codex", directoryHint: .isDirectory)
        case .grok: homeDirectory.appending(path: ".grok", directoryHint: .isDirectory)
        }
    }

    /// Command the user runs to sign in, shown in "signed out" hints.
    public var loginHint: String {
        switch self {
        case .claude: "Run `claude` to sign in or refresh"
        case .codex: "Run `codex login`"
        case .grok: "Run `grok login`"
        }
    }

    /// Background refresh interval (requirements U-12).
    public var refreshInterval: TimeInterval {
        switch self {
        case .claude, .codex: 5 * 60
        case .grok: 12 * 60
        }
    }

    /// When the popover opens, data older than this is refreshed (U-12).
    public var popoverStaleness: TimeInterval {
        switch self {
        case .claude, .codex: 60
        case .grok: 5 * 60
        }
    }
}
