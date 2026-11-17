@testable import HarnessButlerKit
import Foundation
import Testing
import TOMLDecoder

/// `fixture` with exactly one occurrence of `old` replaced by `new`.
func replacingOnce(_ fixture: String, _ old: String, _ new: String) -> String {
    let parts = fixture.components(separatedBy: old)
    precondition(parts.count == 2, "expected exactly one occurrence of \(old)")
    return parts.joined(separator: new)
}

@Suite struct TOMLRoundTrip {
    @Test(arguments: [Fixtures.codex, Fixtures.grok])
    func untouchedDocumentIsByteIdentical(_ fixture: String) throws {
        #expect(try TOMLDocument(fixture).bytes == fixture.bytes)
    }

    @Test func crlfAndMissingFinalNewlineSurvive() throws {
        let crlf = Fixtures.grok.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try TOMLDocument(crlf).bytes == crlf.bytes)
        let noEOL = String(Fixtures.grok.dropLast())   // ends "...privacy_banner_acked = true"
        var doc = try TOMLDocument(noEOL)
        #expect(doc.bytes == noEOL.bytes)
        try doc.set(["privacy", "telemetry"], to: false)
        #expect(doc.text == noEOL + "\ntelemetry = false\n")

        var crlfDoc = try TOMLDocument(crlf)
        try crlfDoc.set(["ui", "theme"], to: "dark")
        #expect(crlfDoc.text == replacingOnce(crlf, "compact_mode = false\r\n", "compact_mode = false\r\ntheme = \"dark\"\r\n"))
    }

    @Test func invalidTOMLIsRejectedAtLoad() {
        #expect(throws: TOMLEditError.self) { try TOMLDocument("model = \n[cli\n") }
    }
}

@Suite struct TOMLEdits {
    @Test func setScalarKeepsCommentsAboveAndInline() throws {
        var doc = try TOMLDocument(Fixtures.codex)
        try doc.set(["model"], to: "gpt-6-mini")
        // Only the value token changes; "# Default model…" above and "# bumped…" inline stay.
        #expect(doc.text == replacingOnce(Fixtures.codex, #"model = "gpt-6"   # bumped"#, #"model = "gpt-6-mini"   # bumped"#))
        #expect(try doc.parsed().string(forKey: "model") == "gpt-6-mini")
    }

    @Test func setScalarInNestedAndQuotedTables() throws {
        var doc = try TOMLDocument(Fixtures.codex)
        try doc.set(["desktop", "appearanceDarkChromeTheme", "accent"], to: "#000000")
        try doc.set(["plugins", "browser@openai-bundled", "enabled"], to: false)
        var expected = replacingOnce(Fixtures.codex, ##"accent = "#6E56CF"  # real"##, ##"accent = "#000000"  # real"##)
        expected = replacingOnce(expected, "[plugins.\"browser@openai-bundled\"]\nenabled = true", "[plugins.\"browser@openai-bundled\"]\nenabled = false")
        #expect(doc.text == expected)
    }

    @Test func toggleBoolKeepsComments() throws {
        var doc = try TOMLDocument(Fixtures.grok)
        try doc.set(["cli", "auto_update"], to: false)
        #expect(doc.text == replacingOnce(Fixtures.grok, "auto_update = true # set by", "auto_update = false # set by"))
    }

    @Test func addMcpServerTableWithArgsAndNestedEnv() throws {
        var doc = try TOMLDocument(Fixtures.codex)
        try doc.set(["mcp_servers", "docs-search"], to: [
            "command": "npx",
            "args": ["-y", "@example/docs-search-mcp", "--port=0"],
            "env": ["DOCS_INDEX": "~/docs", "LOG_LEVEL": "warn"],
        ])
        // Inserted after the last [mcp_servers.*] table; nothing else moves.
        let inserted = """

        [mcp_servers.docs-search]
        command = "npx"
        args = ["-y", "@example/docs-search-mcp", "--port=0"]

        [mcp_servers.docs-search.env]
        DOCS_INDEX = "~/docs"
        LOG_LEVEL = "warn"

        """
        #expect(doc.text == replacingOnce(Fixtures.codex, "enabled = false\n", "enabled = false\n" + inserted))

        let env = try doc.parsed().table(forKey: "mcp_servers").table(forKey: "docs-search").table(forKey: "env")
        #expect(try env.string(forKey: "LOG_LEVEL") == "warn")
    }

    @Test func replaceExistingMcpServerTable() throws {
        var doc = try TOMLDocument(Fixtures.codex)
        try doc.set(["mcp_servers", "node_repl"], to: ["command": "/opt/new", "args": ["--stdio"]])
        let old = Fixtures.codex.components(separatedBy: "[mcp_servers.node_repl]\n")[1].components(separatedBy: "[mcp_servers.computer-use]")[0]
        let expected = replacingOnce(Fixtures.codex, "[mcp_servers.node_repl]\n" + old,
                                     "[mcp_servers.node_repl]\ncommand = \"/opt/new\"\nargs = [\"--stdio\"]\n\n")
        #expect(doc.text == expected)   // the "# Local REPL helper" comment above the header is kept
    }

    @Test func removeTableTakesSubTablesAndAttachedComment() throws {
        var doc = try TOMLDocument(Fixtures.codex)
        try doc.removeTable(["mcp_servers", "node_repl"])
        let start = Fixtures.codex.range(of: "# Local REPL helper\n")!.lowerBound
        let end = Fixtures.codex.range(of: "[mcp_servers.computer-use]")!.lowerBound
        var expected = Fixtures.codex
        expected.removeSubrange(start..<end)
        #expect(doc.text == expected)
        #expect(try !doc.parsed().table(forKey: "mcp_servers").contains(key: "node_repl"))
    }

    @Test func removeLastTableLeavesSingleTrailingNewline() throws {
        var doc = try TOMLDocument(Fixtures.grok)
        try doc.removeTable(["privacy"])
        #expect(doc.text == Fixtures.grok.components(separatedBy: "\n[privacy]")[0])
        #expect(doc.text.hasSuffix("compact_mode = false\n"))
    }

    @Test func addKeyToExistingTableAndCreateMissingTable() throws {
        var doc = try TOMLDocument(Fixtures.codex)
        try doc.set(["mcp_servers", "computer-use", "startup_timeout_sec"], to: 45)
        try doc.set(["profiles", "work", "model"], to: "gpt-6")
        var expected = replacingOnce(Fixtures.codex, "args = []\nenabled = false\n", "args = []\nenabled = false\nstartup_timeout_sec = 45\n")
        expected += "\n[profiles.work]\nmodel = \"gpt-6\"\n"
        #expect(doc.text == expected)
    }

    @Test func removeKeyRemovesItsLine() throws {
        var doc = try TOMLDocument(Fixtures.codex)
        try doc.remove(["sandbox_mode"])
        #expect(doc.text == replacingOnce(Fixtures.codex, "sandbox_mode = 'workspace-write'\n", ""))
    }

    @Test func unsupportedAndInvalidEditsThrowAndLeaveDocumentUnchanged() throws {
        var doc = try TOMLDocument(Fixtures.grok)
        #expect(throws: TOMLEditError.self) { try doc.set(["marketplace", "sources", "name"], to: "x") }  // inside [[…]]
        #expect(throws: TOMLEditError.self) { try doc.set(["ui"], to: 1) }   // would redefine a table: rejected by the validator
        #expect(throws: TOMLEditError.self) { try doc.removeTable(["nope"]) }
        #expect(doc.bytes == Fixtures.grok.bytes)
    }
}
