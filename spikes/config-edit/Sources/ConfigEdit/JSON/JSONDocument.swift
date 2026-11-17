import Foundation

public struct JSONEditError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public var offset: Int?
    public var description: String { offset.map { "\(message) (at byte \($0))" } ?? message }
    init(_ message: String, at offset: Int? = nil) { self.message = message; self.offset = offset }
}

/// Span tree for a JSON text: every node knows its byte range.
struct JSONNode {
    indirect enum Kind {
        case object([Member])
        case array([JSONNode])
        case scalar
    }
    struct Member { var key: String; var keyRange: Range<Int>; var value: JSONNode }
    var range: Range<Int>
    var kind: Kind
}

/// A JSON file held as raw bytes, edited by splicing the byte range of the
/// targeted value. Nothing outside that range is re-serialized, so key order,
/// whitespace, the trailing newline (or its absence) and unknown keys survive.
/// New values are rendered to match the file's detected indent unit.
public struct JSONDocument: Sendable {
    public private(set) var bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        _ = try root()
    }
    public init(_ text: String) throws { try self.init(bytes: Array(text.utf8)) }
    public var text: String { String(decoding: bytes, as: UTF8.self) }

    /// Decoded, ordered value at `path` (object keys only), or nil if absent.
    public func value(at path: [String]) throws -> JSONValue? {
        guard let n = try node(at: path, in: root()) else { return nil }
        return try JSONParser(bytes).decode(n)
    }

    // MARK: edits

    /// Replaces the value at `path`, or inserts it as the last member of the parent object.
    /// Missing intermediate objects are created.
    public mutating func set(_ path: [String], to value: JSONValue) throws {
        precondition(!path.isEmpty)
        let r = try root()
        if let n = try node(at: path, in: r) {
            return try splice(n.range, with: renderer.render(value, indent: lineIndent(n.range.lowerBound)))
        }
        // Walk to the deepest existing object, then insert the remaining path as nested objects.
        var depth = path.count - 1
        while depth > 0, try node(at: Array(path.prefix(depth)), in: r) == nil { depth -= 1 }
        var nested = value
        for k in path[(depth + 1)...].reversed() { nested = .object(OrderedPairs([(k, nested)])) }
        guard let parent = try node(at: Array(path.prefix(depth)), in: r), case .object(let members) = parent.kind else {
            throw JSONEditError("parent of \(path) is not an object")
        }
        try insert(member: path[depth], nested, into: parent, members: members)
    }

    /// Appends to the array at `path` (creating it if missing). With `unique`, an
    /// element that is already present is not added again.
    public mutating func append(_ element: JSONValue, to path: [String], unique: Bool = true) throws {
        let r = try root()
        guard let arr = try node(at: path, in: r) else { return try set(path, to: .array([element])) }
        guard case .array(let elements) = arr.kind else { throw JSONEditError("\(path) is not an array") }
        let p = JSONParser(bytes)
        if unique, try elements.contains(where: { try p.decode($0) == element }) { return }
        guard let last = elements.last else {
            return try splice(arr.range, with: renderer.render(.array([element]), indent: lineIndent(arr.range.lowerBound)))
        }
        if isMultiline(arr.range.lowerBound, elements[0].range.lowerBound) {
            let ind = lineIndent(last.range.lowerBound)
            try splice(last.range.upperBound..<last.range.upperBound, with: "," + newline + ind + renderer.render(element, indent: ind))
        } else {
            try splice(last.range.upperBound..<last.range.upperBound, with: ", " + JSONRender.compact(element))
        }
    }

    /// Removes the member at `path`, including its separating comma.
    public mutating func remove(_ path: [String]) throws {
        let r = try root()
        guard let parent = try node(at: Array(path.dropLast()), in: r), case .object(let members) = parent.kind,
              let idx = members.firstIndex(where: { $0.key == path.last! }) else { throw JSONEditError("no such key: \(path)") }
        let m = members[idx]
        let range: Range<Int>
        if idx > 0 { range = members[idx - 1].value.range.upperBound..<m.value.range.upperBound }
        else if members.count > 1 { range = m.keyRange.lowerBound..<members[1].keyRange.lowerBound }
        else { range = (parent.range.lowerBound + 1)..<(parent.range.upperBound - 1) }
        try splice(range, with: "")
    }

    // MARK: internals

    private func root() throws -> JSONNode { var p = JSONParser(bytes); return try p.parseDocument() }

    private func node(at path: [String], in n: JSONNode) throws -> JSONNode? {
        var cur = n
        for k in path {
            guard case .object(let ms) = cur.kind, let m = ms.last(where: { $0.key == k }) else { return nil }
            cur = m.value
        }
        return cur
    }

    private mutating func insert(member key: String, _ value: JSONValue, into obj: JSONNode, members: [JSONNode.Member]) throws {
        guard let last = members.last else {
            let ind = lineIndent(obj.range.lowerBound)
            return try splice(obj.range, with: renderer.render(.object(OrderedPairs([(key, value)])), indent: ind))
        }
        if isMultiline(obj.range.lowerBound, members[0].keyRange.lowerBound) {
            let ind = lineIndent(last.keyRange.lowerBound)
            let text = "," + newline + ind + JSONRender.string(key) + ": " + renderer.render(value, indent: ind)
            try splice(last.value.range.upperBound..<last.value.range.upperBound, with: text)
        } else {
            let text = ", " + JSONRender.string(key) + ": " + JSONRender.compact(value)
            try splice(last.value.range.upperBound..<last.value.range.upperBound, with: text)
        }
    }

    private func isMultiline(_ from: Int, _ to: Int) -> Bool { bytes[from..<to].contains(0x0A) }

    /// Leading whitespace of the line containing `offset`.
    private func lineIndent(_ offset: Int) -> String {
        var s = offset
        while s > 0, bytes[s - 1] != 0x0A { s -= 1 }
        var e = s
        while e < bytes.count, bytes[e] == 0x20 || bytes[e] == 0x09 { e += 1 }
        return String(decoding: bytes[s..<e], as: UTF8.self)
    }

    /// Indent unit detected from the first indented line (defaults to two spaces).
    private var renderer: JSONRender {
        var unit = "  "
        if let nl = bytes.firstIndex(of: 0x0A) {
            var e = nl + 1
            while e < bytes.count, bytes[e] == 0x20 || bytes[e] == 0x09 { e += 1 }
            if e > nl + 1 { unit = String(decoding: bytes[(nl + 1)..<e], as: UTF8.self) }
        }
        return JSONRender(unit: unit, newline: newline)
    }

    private var newline: String {
        guard let nl = bytes.firstIndex(of: 0x0A) else { return "\n" }
        return nl > 0 && bytes[nl - 1] == 0x0D ? "\r\n" : "\n"
    }

    private mutating func splice(_ range: Range<Int>, with text: String) throws {
        var next = bytes
        next.replaceSubrange(range, with: Array(text.utf8))
        do { _ = try JSONSerialization.jsonObject(with: Data(next), options: [.fragmentsAllowed]) }
        catch { throw JSONEditError("edit produced invalid JSON: \(error)") }
        bytes = next
    }
}

/// Strict RFC 8259 recursive-descent parser that records spans.
struct JSONParser {
    let b: [UInt8]
    var i = 0
    init(_ bytes: [UInt8]) { b = bytes }

    mutating func parseDocument() throws -> JSONNode {
        ws()
        let n = try value(depth: 0)
        ws()
        guard i == b.count else { throw JSONEditError("trailing content", at: i) }
        return n
    }

    private mutating func ws() { while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 } }

    private mutating func value(depth: Int) throws -> JSONNode {
        guard depth < 512 else { throw JSONEditError("nesting too deep", at: i) }
        guard i < b.count else { throw JSONEditError("unexpected end", at: i) }
        let s = i
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1; ws()
            var ms: [JSONNode.Member] = []
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return JSONNode(range: s..<i, kind: .object(ms)) }
            while true {
                ws()
                let ks = i
                let k = try string()
                let kr = ks..<i
                ws(); try expect(":"); ws()
                ms.append(.init(key: k, keyRange: kr, value: try value(depth: depth + 1)))
                ws()
                if try comma(or: "}") { continue }
                return JSONNode(range: s..<i, kind: .object(ms))
            }
        case UInt8(ascii: "["):
            i += 1; ws()
            var es: [JSONNode] = []
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return JSONNode(range: s..<i, kind: .array(es)) }
            while true {
                ws(); es.append(try value(depth: depth + 1)); ws()
                if try comma(or: "]") { continue }
                return JSONNode(range: s..<i, kind: .array(es))
            }
        case UInt8(ascii: "\""):
            _ = try string()
        default:
            while i < b.count, !(b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 || b[i] == UInt8(ascii: ",")
                                 || b[i] == UInt8(ascii: "}") || b[i] == UInt8(ascii: "]")) { i += 1 }
            let lit = String(decoding: b[s..<i], as: UTF8.self)
            guard lit == "true" || lit == "false" || lit == "null" || Self.isNumber(lit) else { throw JSONEditError("invalid literal", at: s) }
        }
        return JSONNode(range: s..<i, kind: .scalar)
    }

    private mutating func comma(or close: Unicode.Scalar) throws -> Bool {
        guard i < b.count else { throw JSONEditError("unexpected end", at: i) }
        if b[i] == UInt8(ascii: ",") { i += 1; return true }
        if b[i] == UInt8(ascii: close) { i += 1; return false }
        throw JSONEditError("expected ',' or '\(close)'", at: i)
    }

    private mutating func expect(_ c: Unicode.Scalar) throws {
        guard i < b.count, b[i] == UInt8(ascii: c) else { throw JSONEditError("expected '\(c)'", at: i) }
        i += 1
    }

    /// RFC 8259 number grammar: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
    /// (hand-written; Swift Regex was the parse bottleneck on a 200 KB file).
    static func isNumber(_ s: String) -> Bool {
        let u = Array(s.utf8)
        var i = 0
        func digits() -> Int { let s = i; while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1 }; return i - s }
        if i < u.count, u[i] == UInt8(ascii: "-") { i += 1 }
        guard i < u.count else { return false }
        if u[i] == UInt8(ascii: "0") { i += 1 } else if digits() == 0 { return false }
        if i < u.count, u[i] == UInt8(ascii: ".") { i += 1; if digits() == 0 { return false } }
        if i < u.count, u[i] == UInt8(ascii: "e") || u[i] == UInt8(ascii: "E") {
            i += 1
            if i < u.count, u[i] == UInt8(ascii: "+") || u[i] == UInt8(ascii: "-") { i += 1 }
            if digits() == 0 { return false }
        }
        return i == u.count
    }

    mutating func string() throws -> String {
        try expect("\"")
        var out = String.UnicodeScalarView()
        var run = i
        func flush(_ to: Int) { out.append(contentsOf: String(decoding: b[run..<to], as: UTF8.self).unicodeScalars) }
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") { flush(i); i += 1; return String(out) }
            if c < 0x20 { throw JSONEditError("control character in string", at: i) }
            if c == UInt8(ascii: "\\") {
                flush(i)
                guard i + 1 < b.count else { break }
                let e = b[i + 1]; i += 2
                switch e {
                case UInt8(ascii: "\""): out.append("\"")
                case UInt8(ascii: "\\"): out.append("\\")
                case UInt8(ascii: "/"): out.append("/")
                case UInt8(ascii: "b"): out.append("\u{08}")
                case UInt8(ascii: "f"): out.append("\u{0C}")
                case UInt8(ascii: "n"): out.append("\n")
                case UInt8(ascii: "r"): out.append("\r")
                case UInt8(ascii: "t"): out.append("\t")
                case UInt8(ascii: "u"):
                    var v = try hex4()
                    if (0xD800..<0xDC00).contains(v), i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let lo = try hex4()
                        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                    }
                    out.append(Unicode.Scalar(v) ?? "\u{FFFD}")
                default: throw JSONEditError("bad escape", at: i - 2)
                }
                run = i
            } else { i += 1 }
        }
        throw JSONEditError("unterminated string", at: i)
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<(i + 4)], as: UTF8.self), radix: 16) else {
            throw JSONEditError("bad \\u escape", at: i)
        }
        i += 4
        return v
    }

    /// Decodes a node (from this parser's bytes) into an ordered value.
    func decode(_ n: JSONNode) throws -> JSONValue {
        switch n.kind {
        case .object(let ms): return .object(OrderedPairs(try ms.map { ($0.key, try decode($0.value)) }))
        case .array(let es): return .array(try es.map(decode))
        case .scalar:
            let lit = String(decoding: b[n.range], as: UTF8.self)
            switch lit {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default:
                if b[n.range.lowerBound] == UInt8(ascii: "\"") { var p = JSONParser(b); p.i = n.range.lowerBound; return .string(try p.string()) }
                return .number(lit)
            }
        }
    }
}
