@testable import HarnessButlerKit
import Foundation
import Testing

@Suite struct JSONEdits {
    @Test(arguments: [Fixtures.claudeSettings, Fixtures.claudeJSON])
    func untouchedDocumentIsByteIdentical(_ fixture: String) throws {
        #expect(try JSONDocument(fixture).bytes == fixture.bytes)
    }

    @Test func largeFixtureIsLarge() { #expect(Fixtures.claudeJSON.utf8.count > 150_000) }

    @Test func setModel() throws {
        var doc = try JSONDocument(Fixtures.claudeSettings)
        try doc.set(["model"], to: "sonnet")
        #expect(doc.text == replacingOnce(Fixtures.claudeSettings, #""model": "opus""#, #""model": "sonnet""#))
    }

    @Test func addPermissionAllowRuleOnce() throws {
        var doc = try JSONDocument(Fixtures.claudeSettings)
        try doc.append("Bash(npm test:*)", to: ["permissions", "allow"])
        try doc.append("Bash(npm test:*)", to: ["permissions", "allow"])   // already present: no-op
        #expect(doc.text == replacingOnce(Fixtures.claudeSettings, "      \"WebSearch\"\n",
                                          "      \"WebSearch\",\n      \"Bash(npm test:*)\"\n"))
    }

    @Test func addDenyRuleCreatesArrayInPlaceStyle() throws {
        var doc = try JSONDocument(Fixtures.claudeSettings)
        try doc.append("Read(./.env)", to: ["permissions", "deny"])
        #expect(doc.text == replacingOnce(Fixtures.claudeSettings, "    \"defaultMode\": \"default\"\n",
                                          "    \"defaultMode\": \"default\",\n    \"deny\": [\n      \"Read(./.env)\"\n    ]\n"))
    }

    static let docsSearch: JSONValue = [
        "type": "stdio",
        "command": "npx",
        "args": ["-y", "@example/docs-search-mcp"],
        "env": ["LOG_LEVEL": "warn"],
    ]

    @Test func addMcpServerLeavesRestOfLargeFileByteIdentical() throws {
        let original = Fixtures.claudeJSON.bytes
        var doc = try JSONDocument(bytes: original)
        try doc.set(["mcpServers", "docs-search"], to: Self.docsSearch)

        let insertion = """
        ,
            "docs-search": {
              "type": "stdio",
              "command": "npx",
              "args": [
                "-y",
                "@example/docs-search-mcp"
              ],
              "env": {
                "LOG_LEVEL": "warn"
              }
            }
        """
        let anchor = "      \"env\": {}\n    }"   // end of the existing "notes-server" entry
        #expect(doc.text == replacingOnce(Fixtures.claudeJSON, anchor, anchor + insertion))
        #expect(!doc.text.hasSuffix("\n"))   // the file had no trailing newline; still none
    }

    @Test func replaceMcpServerEntry() throws {
        var doc = try JSONDocument(Fixtures.claudeJSON)
        try doc.set(["mcpServers", "notes-server"], to: ["type": "http", "url": "https://example.invalid/mcp"])
        let old = """
        "notes-server": {
              "type": "stdio",
              "command": "/opt/tools/notes-server",
              "args": [
                "serve"
              ],
              "env": {}
            }
        """
        let new = """
        "notes-server": {
              "type": "http",
              "url": "https://example.invalid/mcp"
            }
        """
        #expect(doc.text == replacingOnce(Fixtures.claudeJSON, old, new))
        #expect(try doc.value(at: ["mcpServers", "notes-server", "type"]) == "http")
    }

    @Test func removeMcpServerAndInsertIntoEmptyObject() throws {
        var doc = try JSONDocument(Fixtures.claudeJSON)
        try doc.remove(["mcpServers", "notes-server"])
        #expect(try doc.value(at: ["mcpServers"]) == .object([:]))
        try doc.set(["mcpServers", "a"], to: ["command": "x"])
        #expect(doc.text.contains("  \"mcpServers\": {\n    \"a\": {\n      \"command\": \"x\"\n    }\n  },\n  \"cachedFeatureFlags\""))
    }

    @Test func missingMcpServersKeyIsAppendedToRoot() throws {
        var doc = try JSONDocument("{\n  \"numStartups\": 1\n}")
        try doc.set(["mcpServers", "a"], to: ["command": "x"])
        #expect(doc.text == "{\n  \"numStartups\": 1,\n  \"mcpServers\": {\n    \"a\": {\n      \"command\": \"x\"\n    }\n  }\n}")
    }

    @Test func detectsTabIndentAndInlineObjects() throws {
        var doc = try JSONDocument("{\n\t\"a\": {\"x\": 1},\n\t\"b\": [1, 2]\n}\n")
        try doc.set(["a", "y"], to: 2)
        try doc.append(3, to: ["b"])
        try doc.set(["c"], to: ["k": "v"])
        #expect(doc.text == "{\n\t\"a\": {\"x\": 1, \"y\": 2},\n\t\"b\": [1, 2, 3],\n\t\"c\": {\n\t\t\"k\": \"v\"\n\t}\n}\n")
    }

    @Test func unknownKeysAndOddNumberSpellingsSurviveEdits() throws {
        var doc = try JSONDocument(Fixtures.claudeSettings)
        try doc.set(["theme"], to: "light")
        #expect(doc.text.contains(#""nested": [1, 2.50, -3e2, null, "é\/"]"#))
        #expect(try doc.value(at: ["unknownFutureKey", "nested"]) == [1, .number("2.50"), .number("-3e2"), nil, "é/"])
    }

    @Test func invalidInputIsRejected() {
        #expect(throws: JSONEditError.self) { try JSONDocument("{\"a\": 1,}") }
        #expect(throws: JSONEditError.self) { try JSONDocument("{\"a\": 01}") }
    }
}
