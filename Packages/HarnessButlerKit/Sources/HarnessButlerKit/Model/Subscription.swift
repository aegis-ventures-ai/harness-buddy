import Foundation

/// One tracked account, bound to a harness home directory.
///
/// API-key subscriptions (Anthropic/OpenAI admin) arrive in M4; the `source` enum leaves room for them.
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

    public init(
        id: UUID = UUID(),
        name: String,
        harness: Harness,
        homeOverride: String? = nil,
        isPinned: Bool = true
    ) {
        self.id = id
        self.name = name
        self.harness = harness
        self.homeOverride = homeOverride
        self.isPinned = isPinned
    }

    /// The home directory this subscription reads from.
    public func homeURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let homeOverride, !homeOverride.isEmpty {
            return URL(filePath: PathExpansion.expandTilde(homeOverride, homeDirectory: homeDirectory), directoryHint: .isDirectory)
        }
        return harness.defaultHome(homeDirectory: homeDirectory)
    }

    /// Human-readable source, e.g. `~/.claude-work (CLAUDE_CONFIG_DIR)`.
    public func sourceDescription(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = PathExpansion.abbreviate(homeURL(homeDirectory: homeDirectory).path(percentEncoded: false), homeDirectory: homeDirectory)
        return homeOverride == nil ? "\(path) (default)" : "\(path) (\(harness.homeEnvironmentVariable))"
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
