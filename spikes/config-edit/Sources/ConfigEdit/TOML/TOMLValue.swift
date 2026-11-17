import Foundation

/// A TOML value to write. Tables keep insertion order (dictionary literals are ordered).
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table(OrderedPairs<TOMLValue>)

    var isTable: Bool { if case .table = self { true } else { false } }
}

/// Ordered key/value pairs. Used for TOML tables and JSON objects.
public struct OrderedPairs<Value: Equatable & Sendable>: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    public struct Pair: Equatable, Sendable {
        public var key: String
        public var value: Value
    }
    public var pairs: [Pair]
    public init(_ pairs: [(String, Value)]) { self.pairs = pairs.map { Pair(key: $0.0, value: $0.1) } }
    public init(dictionaryLiteral elements: (String, Value)...) { self.init(elements) }
    public subscript(key: String) -> Value? { pairs.first { $0.key == key }?.value }
}

extension TOMLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int64) { self = .integer(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(floatLiteral v: Double) { self = .float(v) }
    public init(arrayLiteral v: TOMLValue...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, TOMLValue)...) { self = .table(OrderedPairs(v)) }
}

enum TOMLRender {
    /// Inline (single-line) form of a value.
    static func inline(_ v: TOMLValue) -> String {
        switch v {
        case .string(let s): return basicString(s)
        case .integer(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .float(let d):
            if d.isNaN { return "nan" }
            if d.isInfinite { return d < 0 ? "-inf" : "inf" }
            let s = "\(d)"
            return s.contains(".") || s.contains("e") ? s : s + ".0"
        case .array(let a): return "[" + a.map(inline).joined(separator: ", ") + "]"
        case .table(let t):
            return t.pairs.isEmpty ? "{}" : "{ " + t.pairs.map { key($0.key) + " = " + inline($0.value) }.joined(separator: ", ") + " }"
        }
    }

    static func key(_ k: String) -> String {
        let bare = !k.isEmpty && k.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
        return bare ? k : basicString(k)
    }

    static func keyPath(_ p: [String]) -> String { p.map(key).joined(separator: ".") }

    static func basicString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20 || u.value == 0x7F: out += String(format: "\\u%04X", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// A table as `[header]` sections: scalar/array keys under the header, nested
    /// tables as `[header.sub]` sections (the layout Codex itself writes).
    static func tableSections(path: [String], _ t: OrderedPairs<TOMLValue>, newline: String) -> String {
        var out = "[" + keyPath(path) + "]" + newline
        for p in t.pairs where !p.value.isTable { out += key(p.key) + " = " + inline(p.value) + newline }
        for p in t.pairs { if case .table(let sub) = p.value {
            out += newline + tableSections(path: path + [p.key], sub, newline: newline)
        } }
        return out
    }
}
