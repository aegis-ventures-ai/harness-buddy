import Foundation
import Testing
@testable import HarnessButlerKit

/// Random edit sequences checked against a plain `ConfigValue` model (spike 04's hardening item).
/// After every step the document must parse, read back exactly as the model predicts, and a
/// rejected edit must leave the document untouched.
@Suite struct ConfigPropertyTests {
    static let fixtures: [(String, ConfigFormat, String)] = [
        ("codex", .toml, """
        # Codex settings
        model = "gpt-5.5"   # default model
        approval_policy = "on-request"

        [shell_environment_policy]
        inherit = "core"
        set = { PATH = "/usr/bin", "MY VAR" = "x" }

        # MCP servers
        [mcp_servers.docs]
        command = "npx"
        args = ["-y", "docs-mcp"]

        [mcp_servers.docs.env]
        TOKEN_FILE = "~/.docs"

        [mcp_servers."web search"]
        url = "https://example.com/mcp"

        [profiles.fast]
        model = "gpt-5.5-mini"
        """),
        ("grok", .toml, "[models]\r\ndefault = \"grok-5\"\r\n\r\n[ui]\r\ncompact_mode = false\r\nwidth = 120\r\n"),
        ("empty-toml", .toml, ""),
        ("settings", .json, """
        {
          "model": "opus",
          "permissions": {
            "allow": ["Bash(ls:*)", "Read"],
            "defaultMode": "plan"
          },
          "env": { "A": "1" },
          "hooks": {}
        }
        """),
        ("compact-json", .json, #"{"a":{"b":[1,2,{"c":true}]},"d":null}"#),
    ]

    @Test(arguments: fixtures.map(\.0))
    func randomEditsMatchModel(_ name: String) throws {
        let (_, format, source) = Self.fixtures.first { $0.0 == name }!
        var applied = 0, rejected = 0
        for seed in UInt64(1)...40 {
            var rng = SplitMix64(seed: seed &* 0x9E37_79B9 &+ UInt64(name.utf8.count))
            var document = try ConfigDocument(format: format, bytes: Array(source.utf8))
            var model = try #require(document.value(at: []))
            for step in 0..<30 {
                let operation = Self.randomOperation(model: model, format: format, rng: &rng)
                let before = document.bytes
                do {
                    try document.apply(operation)
                } catch {
                    rejected += 1
                    #expect(document.bytes == before, "seed \(seed) step \(step): a rejected edit changed the file")
                    continue
                }
                applied += 1
                model = model.applying(operation)
                let context = "seed \(seed) step \(step) \(operation)\nBEFORE:\n\(String(decoding: before, as: UTF8.self))\nAFTER:\n\(document.text)\nACTUAL \(Normalized(document.value(at: []), prunesEmptyTables: true))\nEXPECTED \(Normalized(model, prunesEmptyTables: true))"
                let actual = Normalized(document.value(at: []), prunesEmptyTables: true)
                let expected = Normalized(model, prunesEmptyTables: true)
                #expect(actual == expected, "\(context)")
                let reparsed = try ConfigDocument(format: format, bytes: document.bytes)
                #expect(reparsed.bytes == document.bytes, "\(context)")
                if actual != expected { return }
                model = try #require(document.value(at: []))   // carry TOML's dropped parents forward
            }
        }
        // Most edits must go through, or the test proves nothing.
        #expect(applied > rejected * 4, "applied \(applied), rejected \(rejected)")
    }

    // MARK: Generators

    static let keys = ["model", "name", "x", "with space", "dotted.key", "ünï", "quote\"d", "back\\slash", "n2"]

    static func randomOperation(model: ConfigValue, format: ConfigFormat, rng: inout SplitMix64) -> ConfigOperation {
        let tables = tablePaths(model).filter { format == .json || !$0.contains(where: { $0.isEmpty }) }
        let leaves = leafPaths(model)
        switch rng.next(5) {
        case 0 where !leaves.isEmpty:
            return .set(leaves[rng.next(leaves.count)], randomValue(&rng, depth: 0))
        case 1 where !leaves.isEmpty:
            return .remove(leaves[rng.next(leaves.count)])
        case 2 where tables.count > 1:
            return .remove(tables[1 + rng.next(tables.count - 1)])
        case 3:
            let parent = tables[rng.next(tables.count)]
            return .set(parent + [keys[rng.next(keys.count)]], .table(OrderedPairs([("k", randomScalar(&rng))])))
        default:
            let parent = tables[rng.next(tables.count)]
            return .set(parent + [keys[rng.next(keys.count)]], randomValue(&rng, depth: 0))
        }
    }

    static func randomScalar(_ rng: inout SplitMix64) -> ConfigValue {
        switch rng.next(6) {
        case 0: .bool(rng.next(2) == 0)
        case 1: .integer(Int64(rng.next(2000)) - 1000)
        case 2: .double([0.5, -2.25, 1e-3, 12345.75][rng.next(4)])
        case 3: .string(["", "plain", "line\nbreak", "tab\there", "quote \" and \\", "émoji 🎉", "# not a comment", "'single'"][rng.next(8)])
        default: .string("v\(rng.next(100))")
        }
    }

    static func randomValue(_ rng: inout SplitMix64, depth: Int) -> ConfigValue {
        switch rng.next(depth > 0 ? 4 : 6) {
        case 4: .array((0..<rng.next(4)).map { _ in randomScalar(&rng) })
        case 5: .strings((0..<rng.next(3)).map { "a\($0)" })
        default: randomScalar(&rng)
        }
    }

    /// Paths of every table reachable without going through an array (root included).
    static func tablePaths(_ value: ConfigValue, prefix: [String] = []) -> [[String]] {
        guard let table = value.table else { return [] }
        return [prefix] + table.pairs.flatMap { tablePaths($0.value, prefix: prefix + [$0.key]) }
    }

    static func leafPaths(_ value: ConfigValue, prefix: [String] = []) -> [[String]] {
        guard let table = value.table else { return prefix.isEmpty ? [] : [prefix] }
        return table.pairs.flatMap { leafPaths($0.value, prefix: prefix + [$0.key]) }
    }
}

/// Small deterministic PRNG so failures reproduce from the seed.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ bound: Int) -> Int { bound <= 0 ? 0 : Int(next() % UInt64(bound)) }
}
