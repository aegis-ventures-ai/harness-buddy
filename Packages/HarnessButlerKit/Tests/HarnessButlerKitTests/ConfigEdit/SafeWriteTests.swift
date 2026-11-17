@testable import HarnessButlerKit
import Darwin
import Foundation
import Testing

/// Every test works in its own temporary directory; real harness files are never touched.
struct Sandbox {
    let dir: URL
    let writer: SafeFileWriter
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("config-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writer = SafeFileWriter(backupDirectory: dir.appendingPathComponent("backups"))
    }
    func file(_ name: String, _ text: String, mode: Int = 0o600) throws -> String {
        let p = dir.appendingPathComponent(name).path
        try Data(text.utf8).write(to: URL(fileURLWithPath: p))
        chmod(p, mode_t(mode))
        return p
    }
    func mode(_ p: String) -> mode_t { var st = stat(); stat(p, &st); return st.st_mode & 0o7777 }
    func isSymlink(_ p: String) -> Bool { var st = stat(); lstat(p, &st); return (st.st_mode & S_IFMT) == S_IFLNK }
    func read(_ p: String) -> String { String(decoding: FileManager.default.contents(atPath: p)!, as: UTF8.self) }
    func leftovers() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".hb-") } }
}

@Suite struct SafeWrite {
    @Test(arguments: [0o600, 0o644])
    func writesBackupPreservesModeAndVerifies(mode: Int) throws {
        let sb = try Sandbox()
        let p = try sb.file("config.toml", Fixtures.grok, mode: mode)
        let loaded = try sb.writer.load(p)
        var doc = try TOMLDocument(bytes: loaded.bytes)
        try doc.set(["cli", "auto_update"], to: false)
        let result = try sb.writer.write(doc.bytes, over: loaded) { _ = try TOMLDocument(bytes: $0) }

        #expect(sb.read(p) == doc.text)
        #expect(sb.mode(p) == mode_t(mode))
        #expect(sb.read(result.backupPath) == Fixtures.grok)
        #expect(sb.mode(result.backupPath) == 0o600)   // backups may hold secrets
        #expect(try sb.leftovers().isEmpty)
    }

    @Test func externalChangeBlocksTheWrite() throws {
        let sb = try Sandbox()
        let p = try sb.file("settings.json", Fixtures.claudeSettings)
        let loaded = try sb.writer.load(p)
        try Data("{\"changed\": true}\n".utf8).write(to: URL(fileURLWithPath: p))   // another process writes
        #expect(throws: SafeWriteError.self) { try sb.writer.write(Array("{}".utf8), over: loaded) }
        #expect(sb.read(p) == "{\"changed\": true}\n")
        #expect(!FileManager.default.fileExists(atPath: sb.dir.appendingPathComponent("backups").path))
    }

    @Test func invalidContentNeverReachesDisk() throws {
        let sb = try Sandbox()
        let p = try sb.file("config.toml", Fixtures.grok)
        let loaded = try sb.writer.load(p)
        #expect(throws: SafeWriteError.self) {
            try sb.writer.write(Array("[cli\n".utf8), over: loaded) { _ = try TOMLDocument(bytes: $0) }
        }
        #expect(sb.read(p) == Fixtures.grok)
    }

    @Test func symlinkIsKeptAndTargetIsUpdated() throws {
        let sb = try Sandbox()
        try FileManager.default.createDirectory(at: sb.dir.appendingPathComponent("dotfiles"), withIntermediateDirectories: true)
        let target = try sb.file("dotfiles/settings.json", Fixtures.claudeSettings, mode: 0o644)
        let link = sb.dir.appendingPathComponent("settings.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let loaded = try sb.writer.load(link)
        var doc = try JSONDocument(bytes: loaded.bytes)
        try doc.set(["model"], to: "sonnet")
        try sb.writer.write(doc.bytes, over: loaded)

        #expect(sb.isSymlink(link))
        #expect(sb.read(target) == doc.text)
        #expect(sb.mode(target) == 0o644)
        #expect(try sb.leftovers().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sb.dir.appendingPathComponent("dotfiles").path) == ["settings.json"])
    }

    /// Evidence for the doc: Foundation's atomic write replaces a symlink with a regular file.
    @Test func foundationAtomicWriteBreaksSymlinks() throws {
        let sb = try Sandbox()
        let target = try sb.file("real.json", "{}")
        let link = sb.dir.appendingPathComponent("link.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        try Data("{\"a\":1}".utf8).write(to: URL(fileURLWithPath: link), options: .atomic)
        #expect(!sb.isSymlink(link))
        #expect(sb.read(target) == "{}")
    }

    @Test func lockDirectoryBlocksAndStaleLocksAreBroken() throws {
        let sb = try Sandbox()
        let p = try sb.file(".claude.json", "{}")
        let lock = p + ".lock"
        mkdir(lock, 0o755)   // a live lock held by "the CLI"
        #expect(throws: SafeWriteError.lockTimeout) { try sb.writer.withLock(lock, timeout: 0.2) { 1 } }

        var old = [timespec(tv_sec: time(nil) - 60, tv_nsec: 0), timespec(tv_sec: time(nil) - 60, tv_nsec: 0)]
        utimensat(AT_FDCWD, lock, &old, 0)   // abandoned for a minute: treated as stale
        let r = try sb.writer.withLock(lock, timeout: 0.2) {
            try sb.writer.update(p) { _ in Array("{\"a\": 1}".utf8) }
        }
        #expect(sb.read(r.snapshot.resolvedPath) == "{\"a\": 1}")
        #expect(!FileManager.default.fileExists(atPath: lock))   // released
    }

    @Test func updateRetriesAndMergesWhenFileChangesUnderneath() throws {
        let sb = try Sandbox()
        let p = try sb.file(".claude.json", Fixtures.claudeJSON)
        var attempt = 0
        try sb.writer.update(p, validate: { _ = try JSONDocument(bytes: $0) }) { bytes in
            attempt += 1
            if attempt == 1 {   // simulate the CLI rewriting the file between our load and write
                var cli = try JSONDocument(bytes: bytes)
                try cli.set(["numStartups"], to: 70)
                try Data(cli.bytes).write(to: URL(fileURLWithPath: p))
            }
            var doc = try JSONDocument(bytes: bytes)
            try doc.set(["mcpServers", "docs-search"], to: JSONEdits.docsSearch)
            return doc.bytes
        }
        let final = try JSONDocument(sb.read(p))
        #expect(attempt == 2)
        #expect(try final.value(at: ["numStartups"]) == 70)                       // CLI's change kept
        #expect(try final.value(at: ["mcpServers", "docs-search", "command"]) == "npx")   // ours applied
    }
}
