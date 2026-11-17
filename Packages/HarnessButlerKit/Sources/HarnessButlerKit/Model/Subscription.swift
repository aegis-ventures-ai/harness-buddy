import Foundation

/// One tracked account: a harness login bound to a home directory, or (U-3) an organization's
/// API spend read with an Admin key.
public struct Subscription: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// User-chosen, unique name (U-2).
    public var name: String
    public var harness: Harness
    /// The value of the harness's home variable, exactly as the user's shell exports it,
    /// or `nil` for the harness default (variable unset).
    ///
    /// Stored verbatim: Claude Code hashes this string byte-for-byte to name its Keychain item.
    public var homeOverride: String?
    /// Shown in the menubar (M-1). Menubar order follows the subscription list order.
    public var isPinned: Bool
    /// Set for API-spend subscriptions (U-3). `harness` then only picks the logo and colour,
    /// and `homeOverride` is unused. The Admin key lives in the Keychain, never here.
    public var api: APIAccount?

    public init(
        id: UUID = UUID(),
        name: String,
        harness: Harness,
        homeOverride: String? = nil,
        isPinned: Bool = true,
        api: APIAccount? = nil
    ) {
        self.id = id
        self.name = name
        self.harness = api?.provider.brandHarness ?? harness
        self.homeOverride = api == nil ? homeOverride : nil
        self.isPinned = isPinned
        self.api = api
    }

    /// An API-spend subscription for `account`.
    public static func api(_ account: APIAccount, name: String, id: UUID = UUID(), isPinned: Bool = true) -> Subscription {
        Subscription(id: id, name: name, harness: account.provider.brandHarness, isPinned: isPinned, api: account)
    }

    /// True for a harness login (has a home directory, config files, a harness binary).
    public var isHarnessLogin: Bool { api == nil }

    /// Which provider reads this subscription's usage.
    public var providerKey: UsageProviderKey {
        if let api { return .api(api.provider) }
        return .harness(harness)
    }

    /// Refresh cadence (U-12): harness logins follow their harness; API spend data lags hours, so it's polled slowly.
    public var cadence: UsageCadence { api == nil ? harness.cadence : .apiSpend }

    /// Brand name shown next to the subscription, e.g. "Claude Code" or "Anthropic API".
    public var kindName: String { api?.provider.displayName ?? harness.displayName }

    /// The home directory this subscription reads from.
    public func homeURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let homeOverride, !homeOverride.isEmpty {
            return URL(filePath: PathExpansion.expandTilde(homeOverride, homeDirectory: homeDirectory), directoryHint: .isDirectory)
        }
        return harness.defaultHome(homeDirectory: homeDirectory)
    }

    /// Human-readable source, e.g. `~/.claude-work (CLAUDE_CONFIG_DIR)`.
    public func sourceDescription(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if let api { return "\(api.provider.endpointDescription) · Admin key in Keychain" }
        let path = PathExpansion.abbreviate(homeURL(homeDirectory: homeDirectory).path(percentEncoded: false), homeDirectory: homeDirectory)
        return homeOverride == nil ? "\(path) (default)" : "\(path) (\(harness.homeEnvironmentVariable))"
    }
}

/// Which organization-level usage API an API subscription reads (U-3).
public enum APIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic
    case openai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic API"
        case .openai: "OpenAI API"
        }
    }

    /// The harness whose logo and colour the row borrows.
    public var brandHarness: Harness {
        switch self {
        case .anthropic: .claude
        case .openai: .codex
        }
    }

    public var endpointDescription: String {
        switch self {
        case .anthropic: "Anthropic Usage and Cost API"
        case .openai: "OpenAI organization costs"
        }
    }

    /// Where to create the key, shown in the add sheet.
    public var keyHelp: String {
        switch self {
        case .anthropic: "An Admin API key (sk-ant-admin…) from Claude Console → Settings → Admin keys. Team plans and individual accounts can't create one."
        case .openai: "An Admin key (sk-admin-…) from platform.openai.com → Organization settings → Admin keys."
        }
    }

    public var keyPrefix: String {
        switch self {
        case .anthropic: "sk-ant-admin"
        case .openai: "sk-admin-"
        }
    }

    /// A gentle format check: admin keys have a known prefix; ordinary API keys are rejected
    /// by the endpoint anyway, so this catches the common mistake before a round trip.
    public func keyProblem(_ key: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "Paste an Admin key" }
        if key.contains(where: \.isWhitespace) { return "The key can't contain spaces" }
        if !key.hasPrefix(keyPrefix) { return "This doesn't look like an Admin key (they start with \(keyPrefix))" }
        return nil
    }
}

/// The API-subscription part of a `Subscription` (U-3, U-7).
public struct APIAccount: Codable, Hashable, Sendable {
    public var provider: APIProvider
    /// Optional monthly budget in USD (U-7). Drives the budget window and at-risk status (U-8).
    public var monthlyBudget: Double?

    public init(provider: APIProvider, monthlyBudget: Double? = nil) {
        self.provider = provider
        self.monthlyBudget = monthlyBudget
    }
}

public enum PathExpansion {
    public static func expandTilde(_ path: String, homeDirectory: URL) -> String {
        let home = homeDirectory.path(percentEncoded: false).trimmingSuffix("/")
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    public static func abbreviate(_ path: String, homeDirectory: URL) -> String {
        let home = homeDirectory.path(percentEncoded: false).trimmingSuffix("/")
        let trimmed = path.count > 1 ? path.trimmingSuffix("/") : path
        if trimmed == home { return "~" }
        if trimmed.hasPrefix(home + "/") { return "~" + trimmed.dropFirst(home.count) }
        return trimmed
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var result = self
        while result.count > 1, result.hasSuffix(suffix) { result.removeLast(suffix.count) }
        return result
    }
}
