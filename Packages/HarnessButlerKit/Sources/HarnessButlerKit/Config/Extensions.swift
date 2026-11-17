import Foundation

/// A hook handler from a user-level hook source (C-8, read-only).
public struct HookEntry: Hashable, Sendable, Identifiable {
    public var event: String
    public var matcher: String?
    /// `command`, `http`, `prompt`, … as written.
    public var type: String
    /// The command line, or the URL for HTTP hooks.
    public var target: String
    public var timeout: Int?
    /// File it was read from.
    public var source: String
    public var id: String { [source, event, matcher ?? "", type, target].joined(separator: "\u{1F}") }
}

public struct PluginEntry: Hashable, Sendable, Identifiable {
    public var name: String
    /// The marketplace after `@`, if any.
    public var marketplace: String?
    /// `nil` when the harness lists the plugin without an on/off state.
    public var isEnabled: Bool?
    public var version: String?
    public var source: String
    public var id: String { source + ":" + name + "@" + (marketplace ?? "") }

    /// `name@marketplace`.
    init(qualified: String, isEnabled: Bool?, version: String? = nil, source: String) {
        let parts = qualified.split(separator: "@", maxSplits: 1).map(String.init)
        name = parts.first ?? qualified
        marketplace = parts.count > 1 ? parts[1] : nil
        self.isEnabled = isEnabled
        self.version = version
        self.source = source
    }
}

public struct SkillEntry: Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String
    /// The skill's folder (or `SKILL.md` for a file entry).
    public var path: String
    /// Where it comes from, e.g. "~/.claude/skills" or "bundled".
    public var origin: String
    /// A symlink whose target is missing, or a folder without a readable `SKILL.md`.
    public var isBroken: Bool
    public var id: String { path }
}

/// Everything C-8 shows for one profile.
public struct ExtensionsInventory: Equatable, Sendable {
    public var hooks: [HookEntry] = []
    public var plugins: [PluginEntry] = []
    public var skills: [SkillEntry] = []
    /// Sources that exist but couldn't be read, as "path: reason".
    public var problems: [String] = []
    /// Places the harness also loads from that this view doesn't list.
    public var notes: [String] = []

    public init() {}
}

/// Read-only scan of user-level hooks, plugins and skills (C-8). Project-level files are never
/// read (C-11), and from `installed_plugins.json` only the version and scope are used.
public enum ExtensionsScanner {
    public static func scan(_ profile: ConfigProfile, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ExtensionsInventory {
        var inventory = ExtensionsInventory()
        let home = profile.home
        func abbr(_ url: URL) -> String { PathExpansion.abbreviate(url.path(percentEncoded: false), homeDirectory: homeDirectory) }
        func document(_ url: URL, _ format: ConfigFormat) -> ConfigDocument? {
            guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { return nil }
            do { return try ConfigDocument(format: format, bytes: [UInt8](data)) } catch {
                inventory.problems.append("\(abbr(url)): \(error)")
                return nil
            }
        }

        switch profile.harness {
        case .claude:
            let settingsURL = home.appending(path: "settings.json")
            if let settings = document(settingsURL, .json) {
                inventory.hooks += hooks(in: settings.value(at: ["hooks"]), source: abbr(settingsURL))
                for pair in settings.value(at: ["enabledPlugins"])?.table?.pairs ?? [] {
                    inventory.plugins.append(PluginEntry(qualified: pair.key, isEnabled: pair.value.bool, source: abbr(settingsURL)))
                }
            }
            let installedURL = home.appending(path: "plugins/installed_plugins.json")
            if let installed = document(installedURL, .json) {
                for pair in installed.value(at: ["plugins"])?.table?.pairs ?? [] {
                    // One entry per scope; only user-scope installs are user-level (C-11).
                    guard let entry = pair.value.array?.compactMap(\.table).first(where: { ($0["scope"]?.string ?? "user") == "user" }) else { continue }
                    let version = entry["version"]?.string
                    if let index = inventory.plugins.firstIndex(where: { $0.name + "@" + ($0.marketplace ?? "") == pair.key || $0.name == pair.key }) {
                        inventory.plugins[index].version = version
                    } else {
                        inventory.plugins.append(PluginEntry(qualified: pair.key, isEnabled: nil, version: version, source: abbr(installedURL)))
                    }
                }
            }
            inventory.skills = skills(in: home.appending(path: "skills"), origin: abbr(home.appending(path: "skills")))

        case .codex:
            let configURL = home.appending(path: "config.toml")
            if let config = document(configURL, .toml) {
                if let notify = config.value(at: ["notify"])?.stringArray, !notify.isEmpty {
                    inventory.hooks.append(HookEntry(event: "notify", matcher: nil, type: "command", target: notify.joined(separator: " "),
                                                     timeout: nil, source: abbr(configURL)))
                }
                inventory.hooks += hooks(in: config.value(at: ["hooks"]), source: abbr(configURL))
                for pair in config.value(at: ["plugins"])?.table?.pairs ?? [] {
                    inventory.plugins.append(PluginEntry(qualified: pair.key, isEnabled: pair.value["enabled"]?.bool ?? true, source: abbr(configURL)))
                }
            }
            let hooksURL = home.appending(path: "hooks.json")
            if let file = document(hooksURL, .json) { inventory.hooks += hooks(in: file.value(at: ["hooks"]), source: abbr(hooksURL)) }
            let skillsDir = home.appending(path: "skills")
            inventory.skills = skills(in: skillsDir, origin: abbr(skillsDir))
                + skills(in: skillsDir.appending(path: ".system"), origin: "bundled")

        case .grok:
            let configURL = home.appending(path: "config.toml")
            if let config = document(configURL, .toml) {
                inventory.hooks += hooks(in: config.value(at: ["hooks"]), source: abbr(configURL))
                for name in config.value(at: ["plugins", "enabled"])?.stringArray ?? [] {
                    inventory.plugins.append(PluginEntry(qualified: name, isEnabled: true, source: abbr(configURL)))
                }
                for name in config.value(at: ["plugins", "disabled"])?.stringArray ?? [] {
                    inventory.plugins.append(PluginEntry(qualified: name, isEnabled: false, source: abbr(configURL)))
                }
            }
            let hooksDir = home.appending(path: "hooks")
            for url in files(in: hooksDir).filter({ $0.pathExtension == "json" }) {
                if let file = document(url, .json) { inventory.hooks += hooks(in: file.value(at: ["hooks"]), source: abbr(url)) }
            }
            let skillsDir = home.appending(path: "skills")
            inventory.skills = skills(in: skillsDir, origin: abbr(skillsDir), nested: true)
            let agents = homeDirectory.appending(path: ".agents/skills")
            inventory.skills += skills(in: agents, origin: abbr(agents), nested: true)
            inventory.notes.append("Grok also loads skills and hooks from ~/.claude and ~/.cursor, and plugins installed for Claude Code, unless [compat] turns that off.")
        }
        return inventory
    }

    // MARK: Hooks

    /// `{ Event: [ { matcher, hooks: [ { type, command | url, timeout } ] } ] }`, the shape Claude
    /// Code, Codex `hooks.json` and Grok (JSON or `[[hooks.Event]]` TOML) share.
    static func hooks(in value: ConfigValue?, source: String) -> [HookEntry] {
        guard let events = value?.table else { return [] }
        var result: [HookEntry] = []
        for event in events.pairs {
            for group in event.value.array ?? [] {
                let matcher = group["matcher"].flatMap { $0.string ?? $0.stringArray?.joined(separator: ", ") }
                for handler in group["hooks"]?.array ?? [] {
                    let type = handler["type"]?.string ?? "command"
                    var target = handler["command"]?.string ?? handler["url"]?.string ?? handler["prompt"]?.string ?? ""
                    if let args = handler["args"]?.stringArray, !args.isEmpty { target += " " + args.joined(separator: " ") }
                    let timeout: Int? = switch handler["timeout"] {
                    case .integer(let v): Int(exactly: v)
                    case .double(let v): v.isFinite && abs(v) < 1e9 ? Int(v) : nil
                    default: nil
                    }
                    result.append(HookEntry(event: event.key, matcher: matcher?.isEmpty == true ? nil : matcher, type: type,
                                            target: target, timeout: timeout, source: source))
                }
            }
        }
        return result
    }

    // MARK: Skills

    /// Folders holding a `SKILL.md`. Hidden entries are skipped (callers add `.system` explicitly).
    static func skills(in directory: URL, origin: String, nested: Bool = false, depth: Int = 0) -> [SkillEntry] {
        var result: [SkillEntry] = []
        for url in files(in: directory) where !url.lastPathComponent.hasPrefix(".") {
            let path = url.path(percentEncoded: false)
            let skillFile = url.appending(path: "SKILL.md")
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)   // follows symlinks
            if !exists {
                // A dangling symlink.
                result.append(SkillEntry(name: url.lastPathComponent, description: "", path: path, origin: origin, isBroken: true))
            } else if isDirectory.boolValue, let text = head(of: skillFile) {
                let front = frontmatter(text)
                result.append(SkillEntry(name: front["name"] ?? url.lastPathComponent, description: front["description"] ?? "",
                                         path: path, origin: origin, isBroken: false))
            } else if isDirectory.boolValue, nested, depth < 3 {
                result += skills(in: url, origin: origin, nested: true, depth: depth + 1)
            } else if isDirectory.boolValue, !nested {
                result.append(SkillEntry(name: url.lastPathComponent, description: "No SKILL.md", path: path, origin: origin, isBroken: true))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `name:` and `description:` from YAML frontmatter (single-line, quoted, or folded `>` / `|`).
    static func frontmatter(_ text: String) -> [String: String] {
        // "\r\n" is a single Character in Swift, so normalise before splitting.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        var index = 1
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(">") || value.hasPrefix("|") || value.isEmpty {
                var parts: [String] = []
                while index < lines.count, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") {
                    parts.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = parts.joined(separator: " ")
            } else if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    // MARK: Helpers

    private static func files(in directory: URL) -> [URL] {
        // Rebuilt from `directory` so paths keep the caller's prefix (not a resolved /private/var/…).
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [])
            .sorted()
            .map { directory.appending(path: $0) }
    }

    /// The first 16 KB: enough for frontmatter, and a huge file is never read whole.
    private static func head(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16_384)).map { String(decoding: $0, as: UTF8.self) }
    }
}
