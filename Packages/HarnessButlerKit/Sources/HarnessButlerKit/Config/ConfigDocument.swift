import Foundation
import TOMLDecoder

/// A config value independent of the file format. Tables keep key order.
public indirect enum ConfigValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case array([ConfigValue])
    case table(OrderedPairs<ConfigValue>)

    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var array: [ConfigValue]? { if case .array(let v) = self { v } else { nil } }
    public var table: OrderedPairs<ConfigValue>? { if case .table(let v) = self { v } else { nil } }
    public var stringArray: [String]? { array?.compactMap(\.string) }

    /// String-valued pairs of a table (env vars, headers). Non-strings are shown as text.
    public var stringPairs: [KeyValue]? {
        table?.pairs.map { KeyValue(key: $0.key, value: $0.value.displayText) }
    }

    public subscript(key: String) -> ConfigValue? { table?[key] }

    /// Short text form for display.
    public var displayText: String {
        switch self {
        case .string(let v): v
        case .bool(let v): v ? "true" : "false"
        case .integer(let v): String(v)
        case .double(let v): String(v)
        case .array(let v): "[" + v.map(\.displayText).joined(separator: ", ") + "]"
        case .table(let v): "{" + v.pairs.map { "\($0.key) = \($0.value.displayText)" }.joined(separator: ", ") + "}"
        }
    }

    public static func strings(_ values: [String]) -> ConfigValue { .array(values.map(ConfigValue.string)) }

    public static func pairs(_ values: [KeyValue]) -> ConfigValue {
        .table(OrderedPairs(values.map { ($0.key, ConfigValue.string($0.value)) }))
    }
}

/// An editable key/value row (env vars, HTTP headers).
public struct KeyValue: Equatable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public static func == (lhs: KeyValue, rhs: KeyValue) -> Bool { lhs.key == rhs.key && lhs.value == rhs.value }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(value)
    }
}

/// A key-scoped edit. Operations, not byte patches: when the file changes under us they are
/// re-applied to the fresh bytes, which is a correct merge (spike 04).
public enum ConfigOperation: Equatable, Sendable {
    /// Set a value, creating missing parents.
    case set([String], ConfigValue)
    /// Remove a key or table. Removing something that isn't there does nothing.
    case remove([String])

    public var path: [String] {
        switch self {
        case .set(let path, _), .remove(let path): path
        }
    }
}

public enum ConfigFormat: String, Sendable {
    case json, toml
}

public struct ConfigEditError: Error, CustomStringConvertible, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A JSON or TOML config file held as bytes and edited in place (comments, order and unknown keys survive).
public struct ConfigDocument: Sendable {
    enum Storage: Sendable {
        case json(JSONDocument)
        case toml(TOMLDocument)
    }

    private(set) var storage: Storage
    public let format: ConfigFormat

    /// Parse (and strictly validate) a file. Empty input is treated as an empty document.
    public init(format: ConfigFormat, bytes: [UInt8]) throws {
        self.format = format
        let blank = bytes.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        switch format {
        case .json:
            do { storage = .json(try JSONDocument(bytes: blank ? Array("{}\n".utf8) : bytes)) }
            catch { throw ConfigEditError("Not valid JSON: \(error)") }
        case .toml:
            do { storage = .toml(try TOMLDocument(bytes: blank ? [] : bytes)) }
            catch { throw ConfigEditError("Not valid TOML 1.0: \(error)") }
        }
    }

    public static func empty(_ format: ConfigFormat) -> ConfigDocument {
        // swiftlint:disable:next force_try
        try! ConfigDocument(format: format, bytes: [])
    }

    public var bytes: [UInt8] {
        switch storage {
        case .json(let document): document.bytes
        case .toml(let document): document.bytes
        }
    }

    public var text: String { String(decoding: bytes, as: UTF8.self) }

    // MARK: Reading

    public func value(at path: [String]) -> ConfigValue? {
        switch storage {
        case .json(let document):
            return (try? document.value(at: path)).flatMap { $0.flatMap(ConfigValue.init(json:)) }
        case .toml(let document):
            guard let root = try? document.parsed() else { return nil }
            var table = root
            for key in path.dropLast() {
                guard let next = try? table.table(forKey: key) else { return nil }
                table = next
            }
            guard let last = path.last else { return ConfigValue(toml: root) }
            return ConfigValue(toml: table, key: last)
        }
    }

    // MARK: Editing

    public mutating func apply(_ operation: ConfigOperation) throws {
        precondition(!operation.path.isEmpty)
        switch (storage, operation) {
        case (.json(var document), .set(let path, let value)):
            try wrap { try document.set(path, to: JSONValue(value)) }
            storage = .json(document)
        case (.json(var document), .remove(let path)):
            guard value(at: path) != nil else { return }
            try wrap { try document.remove(path) }
            storage = .json(document)
        case (.toml(var document), .set(let path, let value)):
            try wrap { try document.set(path, to: TOMLValue(value)) }
            storage = .toml(document)
        case (.toml(var document), .remove(let path)):
            guard value(at: path) != nil else { return }
            // A `[table]` goes with its sub-tables; a key (or inline table) is one line.
            do { try document.removeTable(path) } catch { try wrap { try document.remove(path) } }
            storage = .toml(document)
        }
    }

    public mutating func apply(_ operations: [ConfigOperation]) throws {
        var copy = self
        for operation in operations { try copy.apply(operation) }
        self = copy
    }

    private func wrap(_ body: () throws -> Void) throws {
        do { try body() } catch let error as ConfigEditError { throw error } catch {
            throw ConfigEditError("Couldn't apply the change safely: \(error)")
        }
    }
}

// MARK: - Conversions

extension ConfigValue {
    init?(json: JSONValue) {
        switch json {
        case .null: return nil
        case .bool(let v): self = .bool(v)
        case .string(let v): self = .string(v)
        case .number(let text):
            if let int = Int64(text) { self = .integer(int) } else { self = .double(Double(text) ?? 0) }
        case .array(let values): self = .array(values.compactMap(ConfigValue.init(json:)))
        case .object(let pairs): self = .table(OrderedPairs(pairs.pairs.compactMap { pair in ConfigValue(json: pair.value).map { (pair.key, $0) } }))
        }
    }

    init(toml table: TOMLTable) {
        self = .table(OrderedPairs(table.keys.compactMap { key in ConfigValue(toml: table, key: key).map { (key, $0) } }))
    }

    init?(toml table: TOMLTable, key: String) {
        guard table.contains(key: key) else { return nil }
        if let v = try? table.table(forKey: key) { self = ConfigValue(toml: v) }
        else if let v = try? table.array(forKey: key) { self = ConfigValue(toml: v) }
        else if let v = try? table.string(forKey: key) { self = .string(v) }
        else if let v = try? table.bool(forKey: key) { self = .bool(v) }
        else if let v = try? table.integer(forKey: key) { self = .integer(v) }
        else if let v = try? table.float(forKey: key) { self = .double(v) }
        else if let v = try? table.offsetDateTime(forKey: key) { self = .string(v.description) }
        else if let v = try? table.localDateTime(forKey: key, exactMatch: false) { self = .string(v.description) }
        else if let v = try? table.localDate(forKey: key, exactMatch: false) { self = .string(v.description) }
        else if let v = try? table.localTime(forKey: key, exactMatch: false) { self = .string(v.description) }
        else { return nil }
    }

    init(toml array: TOMLArray) {
        self = .array((0..<array.count).compactMap { index in
            if let v = try? array.table(atIndex: index) { return ConfigValue(toml: v) }
            if let v = try? array.array(atIndex: index) { return ConfigValue(toml: v) }
            if let v = try? array.string(atIndex: index) { return .string(v) }
            if let v = try? array.bool(atIndex: index) { return .bool(v) }
            if let v = try? array.integer(atIndex: index) { return .integer(v) }
            if let v = try? array.float(atIndex: index) { return .double(v) }
            return nil
        })
    }
}

extension JSONValue {
    init(_ value: ConfigValue) {
        switch value {
        case .string(let v): self = .string(v)
        case .bool(let v): self = .bool(v)
        case .integer(let v): self = .number(String(v))
        case .double(let v): self = .number(v.isFinite ? String(v) : "0")
        case .array(let v): self = .array(v.map(JSONValue.init))
        case .table(let v): self = .object(OrderedPairs(v.pairs.map { ($0.key, JSONValue($0.value)) }))
        }
    }
}

extension TOMLValue {
    init(_ value: ConfigValue) {
        switch value {
        case .string(let v): self = .string(v)
        case .bool(let v): self = .bool(v)
        case .integer(let v): self = .integer(v)
        case .double(let v): self = .float(v)
        case .array(let v): self = .array(v.map(TOMLValue.init))
        case .table(let v): self = .table(OrderedPairs(v.pairs.map { ($0.key, TOMLValue($0.value)) }))
        }
    }
}
