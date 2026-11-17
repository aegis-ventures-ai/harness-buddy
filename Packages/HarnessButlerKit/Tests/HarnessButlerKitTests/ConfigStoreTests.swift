import Foundation
import Testing
@testable import HarnessButlerKit

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "hb-config-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

private func mode(_ path: String) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

// MARK: - Documents

@Suite struct ConfigDocumentTests {
    @Test func readsAndEditsJSONKeepingEverythingElse() throws {
        var document = try ConfigDocument(format: .json, bytes: Array("{\n  \"model\": \"opus\",\n  \"theme\": \"dark\"\n}\n".utf8))
        #expect(document.value(at: ["model"]) == .string("opus"))
        try document.apply([.set(["permissions", "defaultMode"], .string("plan")), .remove(["model"]), .remove(["missing"])])
        #expect(document.text == "{\n  \"theme\": \"dark\",\n  \"permissions\": {\n    \"defaultMode\": \"plan\"\n  }\n}\n")
    }

    @Test func readsAndEditsTOMLKeepingComments() throws {
        let source = "# my model\nmodel = \"a\" # inline\n\n[cli]\nauto_update = true\n"
        var document = try ConfigDocument(format: .toml, bytes: Array(source.utf8))
        #expect(document.value(at: ["cli", "auto_update"]) == .bool(true))
        try document.apply(.set(["model"], .string("b")))
        try document.apply(.set(["models", "default"], .string("grok-x")))
        try document.apply(.remove(["cli"]))
        #expect(document.text == "# my model\nmodel = \"b\" # inline\n\n[models]\ndefault = \"grok-x\"\n")
    }

    @Test func emptyFilesStartEmpty() throws {
        var toml = ConfigDocument.empty(.toml)
        try toml.apply(.set(["model"], .string("x")))
        #expect(toml.text == "model = \"x\"\n")
        var json = try ConfigDocument(format: .json, bytes: [])
        try json.apply(.set(["env", "A"], .string("1")))
        #expect(json.value(at: ["env", "A"]) == .string("1"))
    }

    @Test(arguments: [
        "server = { command = \"x\",\n  args = [] }\n", // multi-line inline table (TOML 1.1)
        "server = { command = \"x\", }\n",              // trailing comma (TOML 1.1)
        "s = \"\"\"a\\eb\"\"\"\n",                       // \e escape (TOML 1.1)
        "s = \"\\x41\"\n",                              // \x escape (TOML 1.1)
    ])
    func rejectsTOML11(_ source: String) {
        #expect(throws: ConfigEditError.self) { try ConfigDocument(format: .toml, bytes: Array(source.utf8)) }
    }

    @Test func acceptsTOML10InlineTables() throws {
        let document = try ConfigDocument(format: .toml, bytes: Array("env = { A = \"1\", B = \"2\" }\n".utf8))
        #expect(document.value(at: ["env"])?.stringPairs?.map(\.key) == ["A", "B"])
    }
}

// MARK: - MCP servers

@Suite struct MCPServerMappingTests {
    static let codex = """
    model = "gpt"

    [mcp_servers.node_repl]
    command = "node" # keep me
    args = []
    startup_timeout_sec = 60

    [mcp_servers.node_repl.env]
    A = "1"

    [mcp_servers.remote]
    url = "https://example.com/mcp"
    enabled = false
    """ + "\n"

    @Test func readsCodexServers() throws {
        let document = try ConfigDocument(format: .toml, bytes: Array(Self.codex.utf8))
        let servers = MCPServerMapping.forHarness(.codex).servers(in: document)
        #expect(servers.map(\.name) == ["node_repl", "remote"])
        #expect(servers[0].env == [KeyValue(key: "A", value: "1")])
        #expect(servers[0].otherKeys == ["startup_timeout_sec"])
        #expect(servers[1].transport == .http && !servers[1].isEnabled)
    }

    @Test func editingOneFieldKeepsUnknownKeysAndComments() throws {
        var document = try ConfigDocument(format: .toml, bytes: Array(Self.codex.utf8))
        let mapping = MCPServerMapping.forHarness(.codex)
        let old = mapping.servers(in: document)[0]
        var new = old
        new.args = ["--inspect"]
        new.env.append(KeyValue(key: "B", value: "2"))
        try document.apply(mapping.operations(from: old, to: new, document: document))
        #expect(document.text.contains("command = \"node\" # keep me"))
        #expect(document.text.contains("startup_timeout_sec = 60"))
        #expect(document.text.contains("args = [\"--inspect\"]"))
        #expect(mapping.servers(in: document)[0].env.map(\.key) == ["A", "B"])
    }

    @Test func addsEnablesAndRemovesGrokServers() throws {
        var document = try ConfigDocument(format: .toml, bytes: Array("disabled_mcp_servers = [\"docs\"]\n".utf8))
        let mapping = MCPServerMapping.forHarness(.grok)
        let docs = MCPServer(name: "docs", command: "uvx", args: ["docs-mcp"], isEnabled: false)
        try document.apply(mapping.operations(from: nil, to: docs, document: document))
        #expect(mapping.servers(in: document).first?.isEnabled == false)

        var enabled = docs
        enabled.isEnabled = true
        try document.apply(mapping.operations(from: docs, to: enabled, document: document))
        #expect(mapping.servers(in: document).first?.isEnabled == true)
        #expect(document.value(at: ["disabled_mcp_servers"])?.stringArray == [])

        try document.apply(mapping.operations(from: enabled, to: nil, document: document))
        #expect(mapping.servers(in: document).isEmpty)
    }

    @Test func claudeServersAreJSONWithType() throws {
        var document = try ConfigDocument(format: .json, bytes: Array("{\n  \"numStartups\": 3\n}".utf8))
        let mapping = MCPServerMapping.forHarness(.claude)
        let server = MCPServer(name: "linear", transport: .sse, url: "https://mcp.linear.app/sse")
        try document.apply(mapping.operations(from: nil, to: server, document: document))
        #expect(document.text == "{\n  \"numStartups\": 3,\n  \"mcpServers\": {\n    \"linear\": {\n      \"type\": \"sse\",\n      \"url\": \"https://mcp.linear.app/sse\"\n    }\n  }\n}")
        #expect(mapping.servers(in: document) == [server])
    }

    @Test func renameRemovesAndReAdds() throws {
        var document = try ConfigDocument(format: .toml, bytes: Array(Self.codex.utf8))
        let mapping = MCPServerMapping.forHarness(.codex)
        let old = mapping.servers(in: document)[1]
        var new = old
        new.name = "remote2"
        try document.apply(mapping.operations(from: old, to: new, document: document))
        #expect(mapping.servers(in: document).map(\.name) == ["node_repl", "remote2"])
    }

    @Test func validation() {
        #expect(MCPServer(name: "", command: "x").validationErrors == ["Name is required"])
        #expect(MCPServer(name: "a", transport: .http, url: "ftp://x").validationErrors == ["URL must start with http:// or https://"])
        #expect(MCPServer(name: "a", command: "x").validationErrors.isEmpty)
    }
}

// MARK: - Diff

@Suite struct LineDiffTests {
    @Test func groupsChangesIntoHunksWithContext() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...20).map { "line \($0)" }
        lines[2] = "changed 3"
        lines.insert("new", at: 15)
        let hunks = LineDiff.hunks(old: old, new: lines.joined(separator: "\n") + "\n")
        #expect(hunks.count == 2)
        #expect(hunks[0].lines.filter { $0.kind != .context }.map(\.text) == ["line 3", "changed 3"])
        #expect(hunks[0].header == "@@ -1,6 +1,6 @@")
        #expect(LineDiff.counts(hunks) == (added: 2, removed: 1))
        #expect(LineDiff.hunks(old: old, new: old).isEmpty)
    }
}

// MARK: - Profiles

@Suite struct ConfigProfileTests {
    @Test func oneProfilePerHomeWithSubscriptionNames() {
        let home = URL(filePath: "/Users/u", directoryHint: .isDirectory)
        let subscriptions = [
            Subscription(name: "Work", harness: .claude, homeOverride: "~/.claude-work"),
            Subscription(name: "Personal", harness: .claude),
            Subscription(name: "Codex", harness: .codex),
            Subscription(name: "Also default", harness: .claude),
        ]
        let profiles = ConfigProfile.profiles(for: subscriptions, homeDirectory: home)
        #expect(profiles.map(\.displayName) == ["Work", "Personal, Also default", "Codex"])
        #expect(profiles[0].files(homeDirectory: home).map(\.path) == ["/Users/u/.claude-work/settings.json", "/Users/u/.claude-work/.claude.json"])
        #expect(profiles[1].files(homeDirectory: home).map(\.path) == ["/Users/u/.claude/settings.json", "/Users/u/.claude.json"])
    }
}

// MARK: - Store: save, conflicts, backups

@MainActor
@Suite(.serialized) struct ConfigStoreTests {
    @Test func saveBacksUpWritesAndVerifies() async throws {
        let dir = try tempDir()
        let file = dir.appending(path: "config.toml")
        try write("# keep\nmodel = \"a\"\n", to: file)
        let store = ConfigStore(backups: ConfigBackupStore(root: dir.appending(path: "Backups")))
        let ref = ConfigFileRef(kind: .codexConfig, url: file)
        store.load(ref)
        try store.stage([.set(["model"], .string("b"))], in: ref)

        let preview = try #require(store.preview(ref))
        #expect(preview.added == 1 && preview.removed == 1)
        #expect(await store.save(ref))
        #expect(try text(file) == "# keep\nmodel = \"b\"\n")

        let backup = try #require(store.backupList(ref).first)
        #expect(try store.backups.read(backup) == Array("# keep\nmodel = \"a\"\n".utf8))
        #expect(try mode(backup.url.path(percentEncoded: false)) == 0o600)
        #expect(try mode(store.backups.directory(for: ref).path(percentEncoded: false)) == 0o700)
        #expect(store.state(ref)?.hasChanges == false)

        // Restore puts the old content back (and backs up the current one first).
        #expect(await store.restore(backup, to: ref))
        #expect(try text(file) == "# keep\nmodel = \"a\"\n")
        #expect(store.backupList(ref).count == 2)
    }

    @Test func outsideChangeBlocksSaveUntilReloaded() async throws {
        let dir = try tempDir()
        let file = dir.appending(path: "settings.json")
        try write("{\n  \"model\": \"opus\"\n}\n", to: file)
        let store = ConfigStore(backups: ConfigBackupStore(root: dir.appending(path: "Backups")))
        let ref = ConfigFileRef(kind: .claudeSettings, url: file)
        store.load(ref)
        try store.stage([.set(["theme"], .string("dark"))], in: ref)

        try write("{\n  \"model\": \"sonnet\"\n}\n", to: file) // another program edits it
        #expect(await store.save(ref) == false)
        #expect(store.state(ref)?.externalChange == true)
        #expect(try text(file) == "{\n  \"model\": \"sonnet\"\n}\n")

        store.reload(ref, keepChanges: true) // merge: re-apply the pending edit to the new file
        #expect(await store.save(ref))
        #expect(try text(file) == "{\n  \"model\": \"sonnet\",\n  \"theme\": \"dark\"\n}\n")
    }

    @Test func claudeGlobalMergesUnderLockAndOnlyTouchesMCPServers() async throws {
        let dir = try tempDir()
        let file = dir.appending(path: ".claude.json")
        try write("{\n  \"numStartups\": 1,\n  \"mcpServers\": {}\n}", to: file)
        let store = ConfigStore(backups: ConfigBackupStore(root: dir.appending(path: "Backups")))
        let ref = ConfigFileRef(kind: .claudeGlobal, url: file)
        store.load(ref)
        let mapping = MCPServerMapping.forHarness(.claude)
        let document = try #require(store.document(ref))
        try store.stage(mapping.operations(from: nil, to: MCPServer(name: "docs", command: "uvx"), document: document), in: ref)

        // The CLI rewrites an unrelated key meanwhile: our change still applies on top.
        try write("{\n  \"numStartups\": 2,\n  \"mcpServers\": {}\n}", to: file)
        let preview = try #require(store.preview(ref))
        #expect(preview.scopeNote != nil)
        #expect(preview.hunks.flatMap(\.lines).allSatisfy { !$0.text.contains("numStartups") })
        #expect(await store.save(ref))
        let saved = try ConfigDocument(format: .json, bytes: Array(text(file).utf8))
        #expect(saved.value(at: ["numStartups"]) == .integer(2))
        #expect(mapping.servers(in: saved).map(\.name) == ["docs"])
        #expect(!FileManager.default.fileExists(atPath: ref.lockPath!))
    }

    @Test func claudeGlobalKeepsOnlyMCPServersInMemoryAndBackups() async throws {
        let dir = try tempDir()
        let file = dir.appending(path: ".claude.json")
        let sentinel = "identity-sentinel-7f3a"
        try write("{\n  \"oauthAccount\": {\"emailAddress\": \"\(sentinel)\"},\n  \"projects\": {\"/\(sentinel)\": {}},\n  \"mcpServers\": {\"a\": {\"command\": \"x\"}}\n}", to: file)
        let backupRoot = dir.appending(path: "Backups")
        let store = ConfigStore(backups: ConfigBackupStore(root: backupRoot))
        let ref = ConfigFileRef(kind: .claudeGlobal, url: file)
        store.load(ref)
        let state = try #require(store.state(ref))
        #expect(!state.original.text.contains(sentinel))
        let loadedText = String(decoding: state.loaded?.bytes ?? [], as: UTF8.self)
        #expect(!loadedText.contains(sentinel))
        #expect(MCPServerMapping.forHarness(.claude).servers(in: state.original).map(\.name) == ["a"])

        try store.stage([.set(["mcpServers", "b"], .table(["command": .string("y")]))], in: ref)
        #expect(await store.save(ref))
        #expect(try text(file).contains(sentinel))   // the file itself keeps everything
        #expect(!(store.state(ref)?.original.text.contains(sentinel) ?? true))
        let backup = try #require(store.backupList(ref).first)
        let backupText = String(decoding: try store.backups.read(backup), as: UTF8.self)
        #expect(!backupText.contains(sentinel))
        #expect(backupText.contains("\"a\""))

        // Restoring that backup brings back only the old servers; the rest of the file stays.
        #expect(await store.restore(backup, to: ref))
        let restored = try ConfigDocument(format: .json, bytes: Array(text(file).utf8))
        #expect(MCPServerMapping.forHarness(.claude).servers(in: restored).map(\.name) == ["a"])
        #expect(try text(file).contains(sentinel))
    }

    @Test func oldFullBackupsOfClaudeGlobalAreScrubbed() throws {
        let dir = try tempDir()
        let store = ConfigBackupStore(root: dir.appending(path: "Backups"))
        let ref = ConfigFileRef(kind: .claudeGlobal, url: dir.appending(path: ".claude.json"))
        try store.prepare(for: ref)
        let old = store.directory(for: ref).appending(path: ".claude.json.20261101-000000.000.abcd1234.bak")
        try write("{\"oauthAccount\": {\"emailAddress\": \"someone\"}, \"mcpServers\": {\"a\": {}}}", to: old)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: old.path(percentEncoded: false))
        let settings = ConfigFileRef(kind: .claudeSettings, url: dir.appending(path: "settings.json"))
        try store.prepare(for: settings)
        let other = store.directory(for: settings).appending(path: "settings.json.20261101-000000.000.abcd1234.bak")
        try write("{\"env\": {\"emailAddress\": \"kept\"}}", to: other)

        #expect(store.scrubScopedBackups() == 1)
        #expect(!(try text(old)).contains("someone"))
        #expect(try text(old).contains("mcpServers"))
        #expect(try mode(old.path(percentEncoded: false)) == 0o600)
        #expect(try text(other).contains("kept"))   // unscoped files are backed up whole
        #expect(store.scrubScopedBackups() == 0)
    }

    @Test func creatingAFileRefusesOneThatAppeared() throws {
        let dir = try tempDir()
        let file = dir.appending(path: "config.toml")
        let ref = ConfigFileRef(kind: .grokConfig, url: file)
        try write("model = \"theirs\"\n", to: file)
        #expect(throws: SafeWriteError.externalChange(current: nil)) {
            try ConfigStore.create(ref, bytes: Array("model = \"ours\"\n".utf8), validate: { _ in })
        }
        #expect(try text(file) == "model = \"theirs\"\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).filter { $0.contains(".hb-") }
        #expect(leftovers.isEmpty)
    }

    @Test func claudeGlobalConflictsWhenServersChangedElsewhere() async throws {
        let dir = try tempDir()
        let file = dir.appending(path: ".claude.json")
        try write("{\n  \"mcpServers\": {}\n}", to: file)
        let store = ConfigStore(backups: ConfigBackupStore(root: dir.appending(path: "Backups")))
        let ref = ConfigFileRef(kind: .claudeGlobal, url: file)
        store.load(ref)
        try store.stage([.set(["mcpServers", "a"], .table(["command": .string("x")]))], in: ref)
        try write("{\n  \"mcpServers\": {\n    \"b\": {}\n  }\n}", to: file)
        #expect(await store.save(ref) == false)
        #expect(store.state(ref)?.externalChange == true)
    }

    @Test func rawEditsMustBeValidAndBlockFormEdits() async throws {
        let dir = try tempDir()
        let file = dir.appending(path: "config.toml")
        try write("model = \"a\"\n", to: file)
        let store = ConfigStore(backups: ConfigBackupStore(root: dir.appending(path: "Backups")))
        let ref = ConfigFileRef(kind: .grokConfig, url: file)
        store.load(ref)

        store.setRawText("model = ", in: ref)
        #expect(store.state(ref)?.rawError != nil)
        #expect(store.state(ref)?.canSave == false)
        #expect(throws: ConfigEditError.self) { try store.stage([.set(["x"], .bool(true))], in: ref) }

        store.setRawText("model = \"b\" # typed by hand\n", in: ref)
        #expect(store.state(ref)?.canSave == true)
        #expect(await store.save(ref))
        #expect(try text(file) == "model = \"b\" # typed by hand\n")
    }

    @Test func createsMissingFilesWithPrivateMode() async throws {
        let dir = try tempDir()
        let file = dir.appending(path: "config.toml")
        let store = ConfigStore(backups: ConfigBackupStore(root: dir.appending(path: "Backups")))
        let ref = ConfigFileRef(kind: .grokConfig, url: file)
        store.load(ref)
        #expect(store.state(ref)?.exists == false)
        try store.stage([.set(["cli", "auto_update"], .bool(false))], in: ref)
        #expect(await store.save(ref))
        #expect(try text(file) == "[cli]\nauto_update = false\n")
        #expect(try mode(file.path(percentEncoded: false)) == 0o600)
    }

    @Test func savingThroughASymlinkKeepsTheLink() async throws {
        let dir = try tempDir()
        let target = dir.appending(path: "dotfiles-settings.json")
        let link = dir.appending(path: "settings.json")
        try write("{}\n", to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = ConfigStore(backups: ConfigBackupStore(root: dir.appending(path: "Backups")))
        let ref = ConfigFileRef(kind: .claudeSettings, url: link)
        store.load(ref)
        #expect(store.state(ref)?.isSymlink == true)
        try store.stage([.set(["model"], .string("opus"))], in: ref)
        #expect(await store.save(ref))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)) == target.path(percentEncoded: false))
        #expect(try text(target).contains("opus"))
    }

    @Test func prunesOldBackups() throws {
        let dir = try tempDir()
        let store = ConfigBackupStore(root: dir.appending(path: "Backups"))
        let ref = ConfigFileRef(kind: .codexConfig, url: dir.appending(path: "config.toml"))
        try store.prepare(for: ref)
        let old = store.directory(for: ref).appending(path: "config.toml.old.bak")
        try write("x", to: old)
        try FileManager.default.setAttributes([.creationDate: Date.now.addingTimeInterval(-40 * 86400)], ofItemAtPath: old.path(percentEncoded: false))
        try write("y", to: store.directory(for: ref).appending(path: "config.toml.new.bak"))
        #expect(store.prune(for: ref) == 1)
        #expect(store.list(for: ref).count == 1)
    }
}

@Suite struct InlineTableEditTests {
    @Test func editsInsideInlineTableRewriteOnlyThatValue() throws {
        var document = try ConfigDocument(format: .toml, bytes: Array("""
        # keep me
        [mcp_servers.docs]
        command = "npx"   # trailing
        env = { A = "1", 'B C' = "2" }
        """.utf8))
        try document.apply([.set(["mcp_servers", "docs", "env", "D"], .string("4")), .remove(["mcp_servers", "docs", "env", "A"])])
        #expect(document.text == """
        # keep me
        [mcp_servers.docs]
        command = "npx"   # trailing
        env = { "B C" = "2", D = "4" }
        """)
    }

    @Test func refusesLossyInlineRewrite() throws {
        let source = "t = { when = 1979-05-27T07:32:00Z, a = 1 }\n"
        var document = try ConfigDocument(format: .toml, bytes: Array(source.utf8))
        #expect(throws: ConfigEditError.self) { try document.apply(.set(["t", "a"], .integer(2))) }
        #expect(document.text == source)
    }
}
