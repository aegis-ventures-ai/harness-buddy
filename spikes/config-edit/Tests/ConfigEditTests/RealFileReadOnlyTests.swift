import ConfigEdit
import Foundation
import Testing

/// Opt-in smoke test against the machine's real config files: READ-ONLY, in memory.
/// Nothing is written and no content is printed (env blocks can hold secrets).
/// Run with: CONFIG_EDIT_REAL_FILES=1 swift test --filter RealFiles
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CONFIG_EDIT_REAL_FILES"] == "1"))
struct RealFiles {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    func read(_ rel: String) throws -> [UInt8]? {
        FileManager.default.contents(atPath: "\(Self.home)/\(rel)").map { [UInt8]($0) }
    }

    @Test(arguments: [".codex/config.toml", ".grok/config.toml"])
    func tomlRoundTripsAndAcceptsEdits(_ rel: String) throws {
        guard let bytes = try read(rel) else { return }
        var doc = try TOMLDocument(bytes: bytes)
        #expect(doc.bytes == bytes)
        try doc.set(["mcp_servers", "spike-probe"], to: ["command": "true", "args": [], "env": ["A": "1"]])
        try doc.removeTable(["mcp_servers", "spike-probe"])
        #expect(doc.bytes == bytes, "add then remove should restore the original bytes")
    }

    @Test(arguments: [".claude/settings.json", ".claude.json"])
    func jsonRoundTripsAndAcceptsEdits(_ rel: String) throws {
        guard let bytes = try read(rel) else { return }
        var doc = try JSONDocument(bytes: bytes)
        #expect(doc.bytes == bytes)
        let hadServers = try doc.value(at: ["mcpServers"]) != nil
        try doc.set(["mcpServers", "spike-probe"], to: ["command": "true"])
        try doc.remove(hadServers ? ["mcpServers", "spike-probe"] : ["mcpServers"])
        #expect(doc.bytes == bytes, "add then remove should restore the original bytes")
    }
}
