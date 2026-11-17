import Foundation

/// U-1: find harness logins on first launch.
///
/// Default homes (`~/.claude`, `~/.codex`, `~/.grok`) plus extra Claude config dirs (`~/.claude*`)
/// that contain their own `.claude.json`. Only checks that files exist; reads nothing.
public enum SubscriptionDiscovery {
    public static func discover(homeDirectory: URL, fileManager: FileManager = .default) -> [Subscription] {
        let home = homeDirectory.path(percentEncoded: false).trimmingSuffix("/")
        func exists(_ relative: String) -> Bool { fileManager.fileExists(atPath: "\(home)/\(relative)") }

        var found: [Subscription] = []
        func add(_ harness: Harness, override: String? = nil, suffix: String? = nil) {
            let base = suffix.map { "\(harness.displayName) (\($0))" } ?? harness.displayName
            found.append(Subscription(
                name: SubscriptionNames.unique(base, among: found),
                harness: harness,
                homeOverride: override
            ))
        }

        if exists(".claude.json") || exists(".claude") { add(.claude) }

        let entries = (try? fileManager.contentsOfDirectory(atPath: home)) ?? []
        for entry in entries.sorted() where entry.hasPrefix(".claude") && entry != ".claude" && entry != ".claude.json" {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: "\(home)/\(entry)", isDirectory: &isDirectory), isDirectory.boolValue,
                  exists("\(entry)/.claude.json") else { continue }
            // Stored as the absolute path a shell would export; Claude hashes this exact string.
            add(.claude, override: "\(home)/\(entry)", suffix: String(entry.dropFirst()))
        }

        if exists(".codex/auth.json") || exists(".codex/config.toml") { add(.codex) }
        if exists(".grok/auth.json") || exists(".grok/config.toml") { add(.grok) }
        return found
    }
}
