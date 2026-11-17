import Foundation
import Testing
@testable import HarnessButlerKit

/// Spike 04's JSON and error-reporting hardening items.
@Suite struct ConfigHardeningTests {
    @Test func jsonWithBOMLoadsAndKeepsIt() throws {
        let source: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("{\n  \"model\": \"opus\"\n}\n".utf8)
        var document = try ConfigDocument(format: .json, bytes: source)
        #expect(document.value(at: ["model"]) == .string("opus"))
        try document.apply(.set(["model"], .string("sonnet")))
        #expect(document.bytes == [0xEF, 0xBB, 0xBF] + Array("{\n  \"model\": \"sonnet\"\n}\n".utf8))
    }

    @Test func tomlWithBOMIsHandledConsistently() throws {
        let source: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("model = \"x\"\n".utf8)
        // Either accepted and kept byte for byte, or rejected; never silently rewritten.
        if let document = try? ConfigDocument(format: .toml, bytes: source) {
            #expect(document.bytes == source)
            var edited = document
            try edited.apply(.set(["model"], .string("y")))
            #expect(edited.bytes == [0xEF, 0xBB, 0xBF] + Array("model = \"y\"\n".utf8))
        }
    }

    @Test func duplicateJSONKeysLastOneWins() throws {
        var document = try ConfigDocument(format: .json, bytes: Array(#"{"a": 1, "b": 2, "a": 3}"#.utf8))
        #expect(document.value(at: ["a"]) == .integer(3))
        #expect(document.value(at: [])?.table?["a"] == .integer(3))
        #expect(document.value(at: [])?.table?.pairs.map(\.key) == ["a", "b"])

        var edited = document
        try edited.apply(.set(["a"], .integer(4)))
        #expect(edited.value(at: ["a"]) == .integer(4))

        try document.apply(.remove(["a"]))
        #expect(document.value(at: ["a"]) == nil)
        #expect(document.text == #"{"b": 2}"#)
    }

    @Test func deepJSONNestingIsRejectedNotCrashing() throws {
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(throws: ConfigEditError.self) { try ConfigDocument(format: .json, bytes: Array(deep.utf8)) }
        let fine = "{\"a\": " + String(repeating: "[", count: 100) + String(repeating: "]", count: 100) + "}"
        #expect(try ConfigDocument(format: .json, bytes: Array(fine.utf8)).value(at: ["a"]) != nil)
    }

    @Test func deepTOMLNestingIsRejectedNotCrashing() throws {
        let deep = "a = " + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000) + "\n"
        #expect(throws: ConfigEditError.self) { try ConfigDocument(format: .toml, bytes: Array(deep.utf8)) }
    }

    @Test(arguments: [
        (ConfigFormat.json, "{\n  \"a\": 1,\n  \"é\": tru\n}\n", 3, 8),
        (.json, "{\n  \"a\": 1\n  \"b\": 2\n}", 3, 3),
        (.toml, "[a]\nx = 1\ny = { z = 1, }\n", 3, 14),
    ])
    func syntaxErrorsReportLineAndColumn(format: ConfigFormat, source: String, line: Int, column: Int) {
        do {
            _ = try ConfigDocument(format: format, bytes: Array(source.utf8))
            Issue.record("expected an error")
        } catch let error as ConfigEditError {
            #expect(error.line == line)
            #expect(error.column == column)
            #expect(error.description.contains("(line \(line), column \(column))"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func parserErrorsKeepTheirLineNumber() throws {
        do {
            _ = try ConfigDocument(format: .toml, bytes: Array("a = 1\nb = = 2\n".utf8))
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".lowercased().contains("line 2"))
        }
    }
}
