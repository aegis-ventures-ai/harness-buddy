import Foundation

/// An ordered JSON value. Objects keep key order; numbers keep their literal text.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(OrderedPairs<JSONValue>)

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { o[key] } else { nil }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(String(v)) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral v: JSONValue...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, JSONValue)...) { self = .object(OrderedPairs(v)) }
    public init(nilLiteral: ()) { self = .null }
}

/// Renders in the style of `JSON.stringify(value, null, indent)`, which is what
/// Claude Code writes: `"key": value`, one member per line, `{}` / `[]` when empty.
struct JSONRender {
    var unit: String   // one indentation level, e.g. "  " or "\t"
    var newline: String

    func render(_ v: JSONValue, indent: String) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return Self.string(s)
        case .array(let a):
            if a.isEmpty { return "[]" }
            let inner = indent + unit
            return "[" + newline + a.map { inner + render($0, indent: inner) }.joined(separator: "," + newline) + newline + indent + "]"
        case .object(let o):
            if o.pairs.isEmpty { return "{}" }
            let inner = indent + unit
            return "{" + newline + o.pairs.map { inner + Self.string($0.key) + ": " + render($0.value, indent: inner) }
                .joined(separator: "," + newline) + newline + indent + "}"
        }
    }

    /// Single-line form, used when inserting into an object/array written on one line.
    static func compact(_ v: JSONValue) -> String {
        switch v {
        case .array(let a): return "[" + a.map(compact).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.pairs.map { string($0.key) + ": " + compact($0.value) }.joined(separator: ", ") + "}"
        default: return JSONRender(unit: "", newline: "").render(v, indent: "")
        }
    }

    static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}
