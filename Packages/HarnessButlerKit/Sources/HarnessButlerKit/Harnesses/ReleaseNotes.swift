import Foundation

/// H-5: what changed between the installed version and the pending one.
public struct ReleaseNotes: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var version: SemanticVersion
        public var date: String?
        public var blocks: [Block]

        public init(version: SemanticVersion, date: String? = nil, blocks: [Block]) {
            self.version = version
            self.date = date
            self.blocks = blocks
        }

        public var itemCount: Int {
            blocks.count { if case .item = $0 { true } else { false } }
        }
    }

    public enum Block: Hashable, Sendable {
        case heading(String)
        /// A bullet; `level` 0 is top level. Text keeps inline markdown (`**bold**`, `` `code` ``).
        case item(String, level: Int)
        case paragraph(String)
    }

    /// The version these notes lead up to (the latest).
    public var target: SemanticVersion
    /// Versions after the installed one up to `target`, newest first.
    public var entries: [Entry]
    /// Where to read everything (opens in the browser).
    public var fullNotesURL: URL
    /// The fetched excerpt didn't reach back to the installed version, so older entries are missing.
    public var isPartial: Bool

    public init(target: SemanticVersion, entries: [Entry], fullNotesURL: URL, isPartial: Bool) {
        self.target = target
        self.entries = entries
        self.fullNotesURL = fullNotesURL
        self.isPartial = isPartial
    }

    /// Keep the entries in `(installed, target]`, newest first.
    public static func select(_ all: [Entry], installed: SemanticVersion?, target: SemanticVersion, fullNotesURL: URL) -> ReleaseNotes {
        let entries = all
            .filter { entry in entry.version <= target && installed.map { entry.version > $0 } ?? true }
            .sorted { $0.version > $1.version }
        let oldest = all.map(\.version).min()
        let isPartial = installed.map { installed in oldest.map { $0 > installed } ?? true } ?? false
        return ReleaseNotes(target: target, entries: entries, fullNotesURL: fullNotesURL, isPartial: isPartial)
    }
}

/// Where each harness publishes its release notes. All three are public, unauthenticated URLs.
public struct ReleaseNotesSource: Hashable, Sendable {
    public enum Format: Hashable, Sendable {
        /// One markdown file with a heading per version (`## 2.1.326`, `# 1.0.88 — 2026-11-16`).
        case versionedMarkdown
        /// GitHub's releases list; one release per version, tags `<prefix><version>`.
        case githubReleases(tagPrefix: String)
    }

    public var url: URL
    public var format: Format
    public var fullNotesURL: URL
    /// Fetch only the first bytes of a large file (newest versions come first).
    public var rangeBytes: Int?

    /// Release notes don't depend on how the harness was installed: a brew-installed Codex
    /// is the same release as the standalone one.
    public static func forHarness(_ harness: Harness, target: SemanticVersion) -> ReleaseNotesSource {
        switch harness {
        case .claude:
            ReleaseNotesSource(
                url: URL(string: "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md")!,
                format: .versionedMarkdown,
                fullNotesURL: URL(string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md")!,
                // The whole file is over 1 MB; a few hundred KB covers the last several versions.
                rangeBytes: 256 * 1024
            )
        case .codex:
            ReleaseNotesSource(
                url: URL(string: "https://api.github.com/repos/openai/codex/releases?per_page=50")!,
                format: .githubReleases(tagPrefix: "rust-v"),
                fullNotesURL: URL(string: "https://github.com/openai/codex/releases/tag/rust-v\(target)")!
            )
        case .grok:
            // The file for a version also lists the versions before it.
            ReleaseNotesSource(
                url: URL(string: "https://x.ai/cli/changelogs/\(target).external.md")!,
                format: .versionedMarkdown,
                fullNotesURL: URL(string: "https://x.ai/cli/changelogs/\(target).external.md")!
            )
        }
    }

    /// - Parameter complete: `false` when the body was cut short by `rangeBytes`.
    public func parse(_ data: Data, complete: Bool) -> [ReleaseNotes.Entry] {
        switch format {
        case .versionedMarkdown:
            ReleaseNotesParser.versionedMarkdown(String(decoding: data, as: UTF8.self), complete: complete)
        case .githubReleases(let prefix):
            ReleaseNotesParser.githubReleases(data, tagPrefix: prefix)
        }
    }
}

public enum ReleaseNotesParser {
    /// Split a changelog into versions. A version starts at a heading whose text begins with a version number;
    /// the heading level of the first one is used for the rest, so `### 1.2.3` subsections don't split.
    /// - Parameter complete: when `false` the text was truncated, so the last version is dropped.
    public static func versionedMarkdown(_ text: String, complete: Bool = true) -> [ReleaseNotes.Entry] {
        var entries: [ReleaseNotes.Entry] = []
        var level: Int?
        var current: (version: SemanticVersion, date: String?, lines: [Substring])?

        func close() {
            guard let section = current else { return }
            entries.append(ReleaseNotes.Entry(version: section.version, date: section.date, blocks: blocks(section.lines)))
            current = nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let match = line.wholeMatch(of: /(#{1,6})\s+\[?v?(\d+\.\d+[0-9A-Za-z.\-]*)\]?(.*)/),
               level == nil || match.1.count == level,
               let version = SemanticVersion(String(match.2)) {
                close()
                level = match.1.count
                let date = match.3.firstMatch(of: /\d{4}-\d{2}-\d{2}/).map { String($0.0) }
                current = (version, date, [])
            } else if let level, line.wholeMatch(of: /(#{1,6})\s+.*/).map({ $0.1.count <= level }) == true {
                // A same-or-higher heading that isn't a version ends the section.
                close()
            } else {
                current?.lines.append(line)
            }
        }
        if complete { close() }
        return entries
    }

    /// GitHub releases JSON. Prereleases and drafts are skipped; PR references like `(#123, #456)`
    /// and the PR-list sections (`Changelog`, `Chores`, `Documentation`) are dropped.
    public static func githubReleases(_ data: Data, tagPrefix: String) -> [ReleaseNotes.Entry] {
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return releases.compactMap { release in
            guard release["prerelease"] as? Bool != true, release["draft"] as? Bool != true,
                  let tag = release["tag_name"] as? String, tag.hasPrefix(tagPrefix),
                  let version = SemanticVersion(String(tag.dropFirst(tagPrefix.count))),
                  version.prerelease == nil else { return nil }
            let body = (release["body"] as? String) ?? ""
            let date = (release["published_at"] as? String).map { String($0.prefix(10)) }
            let cleaned = body.replacing(/\s*\(#\d+(?:,\s*#\d+)*\)/, with: "")
            let parsed = blocks(cleaned.split(separator: "\n", omittingEmptySubsequences: false))
            return ReleaseNotes.Entry(version: version, date: date, blocks: dropSections(parsed, named: ["changelog", "chores", "documentation"]))
        }
    }

    /// Headings, bullets (with nesting) and paragraphs. Wrapped continuation lines join their bullet.
    static func blocks(_ lines: [Substring]) -> [ReleaseNotes.Block] {
        var result: [ReleaseNotes.Block] = []
        var continuing = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                continuing = false
                continue
            }
            if let heading = raw.wholeMatch(of: /#{1,6}\s+(.+)/) {
                result.append(.heading(heading.1.trimmingCharacters(in: .whitespaces)))
                continuing = false
            } else if let bullet = raw.wholeMatch(of: /(\s*)[-*+]\s+(.+)/) {
                let indent = bullet.1.replacing("\t", with: "    ").count
                result.append(.item(String(bullet.2).trimmingCharacters(in: .whitespaces), level: min(indent / 2, 2)))
                continuing = true
            } else if line.hasPrefix("Full Changelog:") {
                continuing = false
            } else if continuing, case .item(let text, let level)? = result.last {
                result[result.count - 1] = .item(text + " " + line, level: level)
            } else if continuing, case .paragraph(let text)? = result.last {
                result[result.count - 1] = .paragraph(text + " " + line)
            } else {
                result.append(.paragraph(line))
                continuing = true
            }
        }
        return result
    }

    static func dropSections(_ blocks: [ReleaseNotes.Block], named names: Set<String>) -> [ReleaseNotes.Block] {
        var skipping = false
        return blocks.filter { block in
            if case .heading(let title) = block { skipping = names.contains(title.lowercased()) }
            return !skipping
        }
    }
}
