import Foundation
import Testing
@testable import HarnessButlerKit

/// C-9: copying an MCP server definition from one harness to another.
@Suite struct MCPCopyTests {
    let claude = MCPServerMapping.forHarness(.claude)
    let codex = MCPServerMapping.forHarness(.codex)
    let grok = MCPServerMapping.forHarness(.grok)

    func toml(_ text: String) throws -> ConfigDocument { try ConfigDocument(format: .toml, bytes: Array(text.utf8)) }
    func json(_ text: String) throws -> ConfigDocument { try ConfigDocument(format: .json, bytes: Array(text.utf8)) }

    @Test func claudeStdioServerLandsInCodexAsTOML() throws {
        let source = try json(#"{"mcpServers": {"docs": {"type": "stdio", "command": "npx", "args": ["-y", "docs"], "env": {"TOKEN": "t"}, "timeout": 30}}}"#)
        let server = try #require(claude.servers(in: source).first)
        var target = try toml("model = \"x\"\n")
        let plan = try codex.copyPlan(server, into: target)
        try target.apply(plan.operations)
        #expect(target.text == """
        model = "x"

        [mcp_servers.docs]
        command = "npx"
        args = ["-y", "docs"]

        [mcp_servers.docs.env]
        TOKEN = "t"

        """)
        #expect(codex.servers(in: target).first?.summary == "npx -y docs")
        #expect(plan.notes.count == 1 && plan.notes[0].contains("timeout"))
    }

    @Test func codexHTTPServerKeepsHeadersInClaude() throws {
        let source = try toml("[mcp_servers.api]\nurl = \"https://example.com/mcp\"\nhttp_headers = { X-Key = \"k\" }\n")
        let server = try #require(codex.servers(in: source).first)
        var target = try json("{}\n")
        try target.apply(try claude.copyPlan(server, into: target).operations)
        let copied = try #require(claude.servers(in: target).first)
        #expect(copied.transport == .http && copied.url == "https://example.com/mcp")
        #expect(copied.headers == [KeyValue(key: "X-Key", value: "k")])
        #expect(target.value(at: ["mcpServers", "api", "type"]) == .string("http"))
    }

    @Test func sseIsRefusedForCodex() throws {
        let server = MCPServer(name: "events", transport: .sse, url: "https://example.com/sse")
        #expect(throws: ConfigEditError.self) { try codex.copyPlan(server, into: try toml("")) }
        // Grok takes it and records the transport.
        var target = try toml("")
        try target.apply(try grok.copyPlan(server, into: target).operations)
        #expect(target.value(at: ["mcp_servers", "events", "transport"]) == .string("sse"))
    }

    @Test func nameConflictIsRefusedUnlessRenamed() throws {
        let server = MCPServer(name: "docs", command: "npx")
        let target = try toml("[mcp_servers.docs]\ncommand = \"other\"\n")
        #expect(throws: ConfigEditError.self) { try codex.copyPlan(server, into: target) }
        #expect(throws: ConfigEditError.self) { try codex.copyPlan(server, into: target, as: "bad.name") }
        let plan = try codex.copyPlan(server, into: target, as: "docs-2")
        #expect(plan.server.name == "docs-2")
    }

    @Test func disabledServerIsEnabledInClaudeWithANote() throws {
        let server = MCPServer(name: "x", command: "x", isEnabled: false)
        let plan = try claude.copyPlan(server, into: try json("{}"))
        #expect(plan.server.isEnabled && plan.notes.contains { $0.contains("no off switch") })
        // Codex keeps it off.
        var target = try toml("")
        try target.apply(try codex.copyPlan(server, into: target).operations)
        #expect(target.value(at: ["mcp_servers", "x", "enabled"]) == .bool(false))
    }

    @MainActor @Test func storeStagesTheCopyInTheTargetProfileOnly() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try Data("model = \"x\"\n".utf8).write(to: home.appending(path: ".codex/config.toml"))
        let store = ConfigStore(backups: ConfigBackupStore(root: home.appending(path: "Backups")), homeDirectory: home)
        let target = ConfigProfile(harness: .codex, home: home.appending(path: ".codex"), homeOverride: nil, subscriptionNames: [])
        let ref = try #require(store.mcpFile(of: target))

        try store.copy(MCPServer(name: "docs", command: "npx"), to: target)
        #expect(store.state(ref)?.hasChanges == true)
        #expect(store.document(ref)?.value(at: ["mcp_servers", "docs", "command"]) == .string("npx"))
        // Nothing is written until the user reviews and saves.
        #expect(try String(contentsOf: ref.url, encoding: .utf8) == "model = \"x\"\n")
        #expect(throws: ConfigEditError.self) { try store.copy(MCPServer(name: "docs", command: "npx"), to: target) }
        store.closeAll()
    }
}
