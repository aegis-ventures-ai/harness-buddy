import Foundation

/// One setting on a curated form (C-2), bound to a key path in a config file.
public struct ConfigField: Identifiable, Sendable {
    public struct Choice: Hashable, Sendable {
        public var value: String
        public var label: String
        public init(_ value: String, _ label: String? = nil) {
            self.value = value
            self.label = label ?? value
        }
    }

    public enum Kind: Sendable {
        /// Free text; empty removes the key so the harness default applies.
        case text(placeholder: String, suggestions: [String])
        /// One of a fixed list; "harness default" removes the key. Unknown values in the file are kept and shown.
        case choice([Choice])
        /// A boolean with the harness's default when the key is absent.
        case toggle(defaultValue: Bool)
    }

    public var label: String
    public var help: String
    public var file: ConfigFileKind
    public var path: [String]
    public var kind: Kind

    public var id: String { file.rawValue + ":" + path.joined(separator: ".") }

    public func value(in document: ConfigDocument) -> ConfigValue? { document.value(at: path) }

    /// The edit for a new value; `nil` removes the key.
    public func operation(for value: ConfigValue?) -> ConfigOperation {
        value.map { .set(path, $0) } ?? .remove(path)
    }
}

/// The curated settings per harness. Key names come from each harness's own docs and files
/// (Claude `settings.json`, Codex `config.toml`, Grok `docs/user-guide/26-config-reference.md`).
public enum CuratedSettings {
    public static func general(_ harness: Harness) -> [ConfigField] {
        switch harness {
        case .claude:
            [
                ConfigField(label: "Model", help: "Default model for new sessions (an alias like opus or a full model id).",
                            file: .claudeSettings, path: ["model"],
                            kind: .text(placeholder: "harness default", suggestions: ["opus", "sonnet", "haiku", "opusplan"])),
                ConfigField(label: "Permission mode", help: "How tool use is approved in new sessions.",
                            file: .claudeSettings, path: ["permissions", "defaultMode"],
                            kind: .choice([.init("default", "default (ask)"), .init("acceptEdits"), .init("plan"), .init("auto"),
                                           .init("dontAsk"), .init("bypassPermissions")])),
                ConfigField(label: "Update channel", help: "Which releases Claude Code's own updater installs.",
                            file: .claudeSettings, path: ["autoUpdatesChannel"],
                            kind: .choice([.init("latest"), .init("stable")])),
            ]
        case .codex:
            [
                ConfigField(label: "Model", help: "Default model.", file: .codexConfig, path: ["model"],
                            kind: .text(placeholder: "harness default", suggestions: [])),
                ConfigField(label: "Reasoning effort", help: "How hard the model thinks by default.", file: .codexConfig, path: ["model_reasoning_effort"],
                            kind: .choice(["minimal", "low", "medium", "high", "xhigh"].map { .init($0) })),
                ConfigField(label: "Approval policy", help: "When Codex asks before running commands.",
                            file: .codexConfig, path: ["approval_policy"],
                            kind: .choice([.init("untrusted"), .init("on-failure"), .init("on-request"), .init("never")])),
                ConfigField(label: "Sandbox", help: "What commands may read and write.", file: .codexConfig, path: ["sandbox_mode"],
                            kind: .choice([.init("read-only"), .init("workspace-write"), .init("danger-full-access")])),
            ]
        case .grok:
            [
                ConfigField(label: "Model", help: "The model new sessions use.", file: .grokConfig, path: ["models", "default"],
                            kind: .text(placeholder: "harness default", suggestions: [])),
                ConfigField(label: "Reasoning effort", help: "Default effort for the default model, when it supports one.",
                            file: .grokConfig, path: ["models", "default_reasoning_effort"],
                            kind: .choice(["low", "medium", "high"].map { .init($0) })),
                ConfigField(label: "Permission mode", help: "How tool use is approved in new sessions.", file: .grokConfig, path: ["ui", "permission_mode"],
                            kind: .choice([.init("default"), .init("ask"), .init("auto"), .init("always-approve")])),
                ConfigField(label: "Sandbox", help: "What commands may read and write.", file: .grokConfig, path: ["sandbox", "profile"],
                            kind: .choice(["off", "workspace", "read-only", "strict", "minimal"].map { .init($0) })),
                ConfigField(label: "Check for updates on launch", help: "Grok's own updater; Harness Butler still shows updates either way.", file: .grokConfig, path: ["cli", "auto_update"],
                            kind: .toggle(defaultValue: true)),
            ]
        }
    }

    /// Environment variables set for every session.
    public static func envLocation(_ harness: Harness) -> (file: ConfigFileKind, path: [String], help: String) {
        switch harness {
        case .claude: (.claudeSettings, ["env"], "settings.json → env: set for every Claude Code session.")
        case .codex: (.codexConfig, ["shell_environment_policy", "set"], "config.toml → [shell_environment_policy] set: added to commands Codex runs.")
        case .grok: (.grokConfig, ["env"], "config.toml → [env]: set in every shell command.")
        }
    }

    /// Claude Code's permission rules (`permissions.allow` / `permissions.deny`).
    public static let claudePermissionLists: [(label: String, path: [String])] = [
        ("Allow", ["permissions", "allow"]),
        ("Ask", ["permissions", "ask"]),
        ("Deny", ["permissions", "deny"]),
    ]

    /// Claude Code saves `/effort` per model id under `modelSettings.<model>.effortLevel`
    /// (`max` is session-only and never written).
    public static let claudeEffortLevels = ["low", "medium", "high", "xhigh"]

    public static func claudeEfforts(in document: ConfigDocument) -> [(model: String, effort: String?)] {
        (document.value(at: ["modelSettings"])?.table?.pairs ?? []).map { ($0.key, $0.value["effortLevel"]?.string) }
    }

    public static func claudeEffortPath(model: String) -> [String] { ["modelSettings", model, "effortLevel"] }
}
