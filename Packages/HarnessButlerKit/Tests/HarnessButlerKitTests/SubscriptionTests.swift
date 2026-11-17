import Foundation
import Testing
@testable import HarnessButlerKit

@Suite struct SubscriptionNameTests {
    let existing = [
        Subscription(name: "Acme Claude", harness: .claude),
        Subscription(name: "Codex", harness: .codex),
    ]

    @Test func requiresNonEmptyName() {
        #expect(SubscriptionNames.validate("   ", among: existing) == .empty)
    }

    @Test func rejectsCaseAndWhitespaceInsensitiveDuplicates() {
        #expect(SubscriptionNames.validate("  acme CLAUDE ", among: existing) == .duplicate(existing: "Acme Claude"))
        #expect(SubscriptionNames.validate("Acme Claude 2", among: existing) == nil)
    }

    @Test func renameToOwnNameIsAllowed() {
        #expect(SubscriptionNames.validate("ACME claude", among: existing, excluding: existing[0].id) == nil)
    }

    @Test func uniqueAppendsCounter() {
        #expect(SubscriptionNames.unique("Codex", among: existing) == "Codex 2")
        #expect(SubscriptionNames.unique("Grok Build", among: existing) == "Grok Build")
    }
}

@Suite struct SubscriptionStorageTests {
    func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hb-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func discoversDefaultHomesAndExtraClaudeDirs() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        func touch(_ path: String) throws {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }
        try touch(".claude.json")
        try touch(".claude-work/.claude.json")
        try fm.createDirectory(at: home.appending(path: ".claude-empty"), withIntermediateDirectories: true) // no .claude.json: skipped
        try touch(".codex/auth.json")

        let found = SubscriptionDiscovery.discover(homeDirectory: home)
        #expect(found.map(\.name) == ["Claude Code", "Claude Code (claude-work)", "Codex"])
        #expect(found[0].homeOverride == nil)
        let homePath = home.path(percentEncoded: false).trimmingSuffix("/")
        #expect(found[1].homeOverride == "\(homePath)/.claude-work")
        #expect(found.allSatisfy { $0.isPinned })
    }

    @Test func fileRoundTripsAndReportsFirstLaunch() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = SubscriptionFile(url: dir.appending(path: "nested/subscriptions.json"))
        let initial = try file.load()
        #expect(initial == nil)
        let subs = [Subscription(name: "A", harness: .grok, homeOverride: "/tmp/g", isPinned: false)]
        try file.save(subs)
        let loaded = try file.load()
        #expect(loaded == subs)
    }

    @Test func homeResolution() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        #expect(Subscription(name: "a", harness: .codex).homeURL(homeDirectory: home).path(percentEncoded: false) == "/Users/test/.codex/")
        #expect(Subscription(name: "a", harness: .grok, homeOverride: "~/g").homeURL(homeDirectory: home).path(percentEncoded: false) == "/Users/test/g/")
        #expect(Subscription(name: "a", harness: .claude, homeOverride: "/Users/test/.claude-work").sourceDescription(homeDirectory: home)
            == "~/.claude-work (CLAUDE_CONFIG_DIR)")
    }
}
