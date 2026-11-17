import Foundation

/// The user-level config files Harness Butler edits (requirements §5.3). Project-level files are never touched (C-11).
public enum ConfigFileKind: String, Sendable, Hashable, CaseIterable {
    /// `settings.json`: model, permissions, env, hooks.
    case claudeSettings
    /// `.claude.json`: live CLI state with identity fields. Only `mcpServers` is read or written.
    case claudeGlobal
    /// Codex `config.toml`.
    case codexConfig
    /// Grok Build `config.toml`.
    case grokConfig

    public var format: ConfigFormat {
        switch self {
        case .claudeSettings, .claudeGlobal: .json
        case .codexConfig, .grokConfig: .toml
        }
    }

    public var fileName: String {
        switch self {
        case .claudeSettings: "settings.json"
        case .claudeGlobal: ".claude.json"
        case .codexConfig, .grokConfig: "config.toml"
        }
    }

    /// Keys the app may read and write. `nil` means the whole file.
    public var scopedKeys: [String]? { self == .claudeGlobal ? ["mcpServers"] : nil }

    /// Whether the raw editor and full-file diffs are offered. Not for `.claude.json`, which holds identity data.
    public var allowsRawEditing: Bool { scopedKeys == nil }
}

/// One config file of one profile.
public struct ConfigFileRef: Hashable, Sendable, Identifiable {
    public var kind: ConfigFileKind
    public var url: URL

    public init(kind: ConfigFileKind, url: URL) {
        self.kind = kind
        self.url = url
    }

    public var id: String { kind.rawValue + ":" + url.path(percentEncoded: false) }
    public var path: String { url.path(percentEncoded: false) }

    /// The CLI's own lock directory (Claude Code's proper-lockfile lock on `.claude.json`).
    public var lockPath: String? { kind == .claudeGlobal ? path + ".lock" : nil }
}

/// A harness home directory ("profile") and the subscriptions bound to it (C-1).
public struct ConfigProfile: Hashable, Sendable, Identifiable {
    public var harness: Harness
    public var home: URL
    /// The home variable's value, or `nil` for the harness default.
    public var homeOverride: String?
    /// Names of the subscriptions bound to this directory.
    public var subscriptionNames: [String]

    public var id: String { harness.rawValue + ":" + home.standardizedFileURL.path(percentEncoded: false) }

    public var displayName: String {
        subscriptionNames.isEmpty ? harness.displayName : subscriptionNames.joined(separator: ", ")
    }

    /// The files this profile's settings live in.
    public func files(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ConfigFileRef] {
        switch harness {
        case .claude:
            // With CLAUDE_CONFIG_DIR set, `.claude.json` lives inside that dir; otherwise in the home directory.
            let global = homeOverride == nil
                ? homeDirectory.appending(path: ".claude.json")
                : home.appending(path: ".claude.json")
            return [
                ConfigFileRef(kind: .claudeSettings, url: home.appending(path: "settings.json")),
                ConfigFileRef(kind: .claudeGlobal, url: global),
            ]
        case .codex:
            return [ConfigFileRef(kind: .codexConfig, url: home.appending(path: "config.toml"))]
        case .grok:
            return [ConfigFileRef(kind: .grokConfig, url: home.appending(path: "config.toml"))]
        }
    }

    public func file(_ kind: ConfigFileKind, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ConfigFileRef? {
        files(homeDirectory: homeDirectory).first { $0.kind == kind }
    }

    /// One profile per (harness, home directory) across the subscriptions, in subscription order.
    public static func profiles(for subscriptions: [Subscription], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ConfigProfile] {
        var result: [ConfigProfile] = []
        for harness in Harness.allCases {
            for subscription in subscriptions where subscription.harness == harness {
                let home = subscription.homeURL(homeDirectory: homeDirectory).standardizedFileURL
                if let index = result.firstIndex(where: { $0.harness == harness && $0.home == home }) {
                    result[index].subscriptionNames.append(subscription.name)
                } else {
                    let override = subscription.homeOverride.flatMap { $0.isEmpty ? nil : $0 }
                    result.append(ConfigProfile(harness: harness, home: home, homeOverride: override, subscriptionNames: [subscription.name]))
                }
            }
        }
        return result
    }
}
