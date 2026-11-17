import Foundation
import Testing
@testable import HarnessButlerKit

/// The toml-lang/toml-test corpus (spike 04's hardening item): every valid TOML 1.0 file must load
/// byte-for-byte, every key in it must be editable in place, and invalid or TOML 1.1-only files
/// must be rejected (Codex parses TOML 1.0 only).
@Suite struct TOMLCorpusTests {
    static let root = Bundle.module.url(forResource: "toml-test", withExtension: nil)!

    static func cases(_ folder: String) -> [String] {
        let base = root.appending(path: folder)
        let paths = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.path(percentEncoded: false) }
            .filter { $0.hasSuffix(".toml") } ?? []
        let prefix = base.path(percentEncoded: false)
        return paths.map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.sorted()
    }

    static func bytes(_ folder: String, _ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: root.appending(path: folder).appending(path: name)))
    }

    @Test func corpusIsPresent() {
        #expect(Self.cases("valid").count == 208)
        #expect(Self.cases("invalid").count > 400)
    }

    @Test(arguments: cases("valid"))
    func validFileLoads(_ name: String) throws {
        let source = try Self.bytes("valid", name)
        let document = try ConfigDocument(format: .toml, bytes: source)
        #expect(document.bytes == source)
    }

    /// Set every key (outside arrays of tables) to a new string: only that value may change.
    @Test(arguments: cases("valid"))
    func everyKeyIsEditableInPlace(_ name: String) throws {
        let source = try Self.bytes("valid", name)
        let original = try ConfigDocument(format: .toml, bytes: source)
        guard let model = original.value(at: []) else { return }
        let sections = try TOMLScanner.scan(source).sections
        let arrayTables = sections.filter { $0.kind == .arrayOfTables }.map(\.path)
        for section in sections where !arrayTables.contains(where: { section.path.starts(with: $0) }) {
            for entry in section.entries {
                let path = section.path + entry.key
                var edited = original
                try edited.apply(.set(path, .string("hb-edited")))
                #expect(edited.value(at: path) == .string("hb-edited"), "\(name): \(path)")
                #expect(Normalized(edited.value(at: [])) == Normalized(model.setting(path, to: .string("hb-edited"))), "\(name): \(path)")
            }
        }
    }

    @Test(arguments: cases("invalid"))
    func invalidFileIsRejected(_ name: String) throws {
        let source = try Self.bytes("invalid", name)
        #expect(throws: (any Error).self, "\(name) should be rejected") { try ConfigDocument(format: .toml, bytes: source) }
    }

    @Test(arguments: cases("only-1.1"))
    func toml11OnlyFileIsRejected(_ name: String) throws {
        let source = try Self.bytes("only-1.1", name)
        #expect(throws: (any Error).self, "\(name) is TOML 1.1 only") { try ConfigDocument(format: .toml, bytes: source) }
    }
}

/// Key order differs between the parser and our model, so compare tables as sorted.
struct Normalized: Equatable, CustomStringConvertible {
    let value: ConfigValue?
    /// `prunesEmptyTables`: TOML drops a parent that only existed through `[parent.child]`
    /// once the child is removed, so empty tables don't count.
    init(_ value: ConfigValue?, prunesEmptyTables: Bool = false) {
        self.value = value.map { Self.sort($0, prune: prunesEmptyTables) }
    }

    static func sort(_ value: ConfigValue, prune: Bool) -> ConfigValue {
        switch value {
        case .table(let pairs):
            .table(OrderedPairs(pairs.pairs.sorted { $0.key < $1.key }
                .map { ($0.key, sort($0.value, prune: prune)) }
                .filter { !prune || $0.1.table.map { !$0.pairs.isEmpty } ?? true }))
        case .array(let values): .array(values.map { sort($0, prune: prune) })
        case .double(let d) where d.isNaN: .string("nan")
        default: value
        }
    }

    var description: String { value?.displayText ?? "nil" }
}
