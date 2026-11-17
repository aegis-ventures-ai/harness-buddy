/// Lossless structural scanner for TOML. It does not build values; it records
/// byte spans of headers, keys and values so edits can splice bytes in place.
/// Everything it does not touch (comments, whitespace, quoting, number spelling)
/// is preserved because untouched bytes are never re-serialized.

public struct TOMLEditError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public var offset: Int?
    public var description: String { offset.map { "\(message) (at byte \($0))" } ?? message }
    init(_ message: String, at offset: Int? = nil) { self.message = message; self.offset = offset }
}

struct TOMLEntry {
    var line: Range<Int>      // indentation through the line terminator (or EOF)
    var key: [String]         // decoded key segments, relative to the section
    var value: Range<Int>     // the value expression only
}

struct TOMLSection {
    enum Kind { case root, table, arrayOfTables }
    var kind: Kind
    var path: [String]
    var header: Range<Int>?   // header line, nil for root
    var ownedStart: Int       // header start, extended back over attached comment lines
    var entries: [TOMLEntry] = []
    var contentEnd: Int       // end of the last header/entry line in this section
}

struct TOMLScanner {
    let b: [UInt8]
    var i = 0
    init(_ bytes: [UInt8]) { b = bytes }

    static func scan(_ bytes: [UInt8]) throws(TOMLEditError) -> (sections: [TOMLSection], newline: String) {
        var s = TOMLScanner(bytes)
        return try s.run()
    }

    private mutating func run() throws(TOMLEditError) -> ([TOMLSection], String) {
        var sections = [TOMLSection(kind: .root, path: [], header: nil, ownedStart: 0, contentEnd: 0)]
        var commentRunStart: Int? = nil   // start of contiguous comment lines directly above the current line
        while i < b.count {
            let lineStart = i
            skipSpaces()
            if atEOL {
                consumeEOL(); commentRunStart = nil; continue
            }
            if b[i] == UInt8(ascii: "#") {
                skipToEOL(); consumeEOL()
                if commentRunStart == nil { commentRunStart = lineStart }
                continue
            }
            if b[i] == UInt8(ascii: "[") {
                let aot = i + 1 < b.count && b[i + 1] == UInt8(ascii: "[")
                i += aot ? 2 : 1
                skipSpaces()
                let path = try key()
                skipSpaces()
                try expect("]"); if aot { try expect("]") }
                try endOfLine()
                sections.append(TOMLSection(kind: aot ? .arrayOfTables : .table, path: path, header: lineStart..<i,
                                            ownedStart: commentRunStart ?? lineStart, contentEnd: i))
            } else {
                let k = try key()
                skipSpaces(); try expect("="); skipSpaces()
                let vs = i
                try value()
                let ve = i
                try endOfLine()
                sections[sections.count - 1].entries.append(TOMLEntry(line: lineStart..<i, key: k, value: vs..<ve))
                sections[sections.count - 1].contentEnd = i
            }
            commentRunStart = nil
        }
        let nl = b.firstIndex(of: 0x0A)
        return (sections, nl.map { $0 > 0 && b[$0 - 1] == 0x0D } == true ? "\r\n" : "\n")
    }

    // MARK: lexing helpers

    private var atEOL: Bool { i >= b.count || b[i] == 0x0A || (b[i] == 0x0D && i + 1 < b.count && b[i + 1] == 0x0A) }
    private mutating func skipSpaces() { while i < b.count, b[i] == 0x20 || b[i] == 0x09 { i += 1 } }
    private mutating func skipToEOL() { while !atEOL { i += 1 } }
    private mutating func consumeEOL() { if i < b.count { i += b[i] == 0x0D ? 2 : 1 } }
    private mutating func expect(_ c: Unicode.Scalar) throws(TOMLEditError) {
        guard i < b.count, b[i] == UInt8(ascii: c) else { throw TOMLEditError("expected '\(c)'", at: i) }
        i += 1
    }
    /// After a header or key/value: optional whitespace, optional comment, then EOL/EOF.
    private mutating func endOfLine() throws(TOMLEditError) {
        skipSpaces()
        if i < b.count, b[i] == UInt8(ascii: "#") { skipToEOL() }
        guard atEOL else { throw TOMLEditError("unexpected content after value", at: i) }
        consumeEOL()
    }
    /// Whitespace, newlines and comments (inside arrays / TOML 1.1 inline tables).
    private mutating func skipTrivia() {
        while i < b.count {
            if b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
            else if b[i] == UInt8(ascii: "#") { skipToEOL() }
            else { return }
        }
    }

    // MARK: keys

    mutating func key() throws(TOMLEditError) -> [String] {
        var parts: [String] = []
        while true {
            skipSpaces()
            parts.append(try keySegment())
            skipSpaces()
            guard i < b.count, b[i] == UInt8(ascii: ".") else { return parts }
            i += 1
        }
    }

    private mutating func keySegment() throws(TOMLEditError) -> String {
        guard i < b.count else { throw TOMLEditError("expected key", at: i) }
        if b[i] == UInt8(ascii: "\"") { return try basicString() }
        if b[i] == UInt8(ascii: "'") {
            let s = i + 1
            i = s
            while i < b.count, b[i] != UInt8(ascii: "'") { if b[i] == 0x0A { break }; i += 1 }
            guard i < b.count, b[i] == UInt8(ascii: "'") else { throw TOMLEditError("unterminated literal key", at: s) }
            i += 1
            return String(decoding: b[s..<(i - 1)], as: UTF8.self)
        }
        let s = i
        while i < b.count, Self.isBare(b[i]) { i += 1 }
        guard i > s else { throw TOMLEditError("invalid key", at: s) }
        return String(decoding: b[s..<i], as: UTF8.self)
    }

    static func isBare(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D
    }

    /// Decodes a single-line basic string (used for quoted keys).
    private mutating func basicString() throws(TOMLEditError) -> String {
        let start = i
        i += 1
        var out = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() { out.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars); raw.removeAll() }
        while i < b.count, b[i] != UInt8(ascii: "\"") {
            if b[i] == 0x0A { break }
            if b[i] == UInt8(ascii: "\\"), i + 1 < b.count {
                flush()
                let e = b[i + 1]; i += 2
                switch e {
                case UInt8(ascii: "n"): out.append("\n")
                case UInt8(ascii: "t"): out.append("\t")
                case UInt8(ascii: "r"): out.append("\r")
                case UInt8(ascii: "b"): out.append("\u{08}")
                case UInt8(ascii: "f"): out.append("\u{0C}")
                case UInt8(ascii: "\""): out.append("\"")
                case UInt8(ascii: "\\"): out.append("\\")
                case UInt8(ascii: "u"), UInt8(ascii: "U"):
                    let n = e == UInt8(ascii: "u") ? 4 : 8
                    guard i + n <= b.count, let v = UInt32(String(decoding: b[i..<(i + n)], as: UTF8.self), radix: 16),
                          let sc = Unicode.Scalar(v) else { throw TOMLEditError("bad unicode escape", at: i) }
                    out.append(sc); i += n
                default: throw TOMLEditError("bad escape", at: i - 2)
                }
            } else { raw.append(b[i]); i += 1 }
        }
        guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw TOMLEditError("unterminated string", at: start) }
        flush(); i += 1
        return String(out)
    }

    // MARK: values (span only)

    /// Config files nest a handful of levels; the limit keeps recursion (here and in TOMLDecoder,
    /// which only sees files that pass the scanner) far from the stack's end.
    static let maxDepth = 128

    mutating func value(depth: Int = 0) throws(TOMLEditError) {
        guard depth < Self.maxDepth else { throw TOMLEditError("nested more than \(Self.maxDepth) levels deep", at: i) }
        guard i < b.count else { throw TOMLEditError("expected value", at: i) }
        let start = i
        switch b[i] {
        case UInt8(ascii: "\""):
            if hasPrefix("\"\"\"") { try multiline(quote: UInt8(ascii: "\""), escapes: true) }
            else { _ = try basicString() }
        case UInt8(ascii: "'"):
            if hasPrefix("'''") { try multiline(quote: UInt8(ascii: "'"), escapes: false) }
            else { _ = try keySegment() }   // a literal string scans like a literal key
        case UInt8(ascii: "["):
            i += 1
            while true {
                skipTrivia()
                guard i < b.count else { throw TOMLEditError("unterminated array", at: start) }
                if b[i] == UInt8(ascii: "]") { i += 1; return }
                try value(depth: depth + 1)
                skipTrivia()
                if i < b.count, b[i] == UInt8(ascii: ",") { i += 1 }
            }
        case UInt8(ascii: "{"):
            // TOML 1.0: inline tables are one line with no trailing comma. TOMLDecoder accepts the
            // TOML 1.1 forms, but Codex (toml_edit 0.23) rejects them, so the scanner enforces 1.0.
            i += 1
            var afterComma = false
            while true {
                skipSpaces()
                guard i < b.count, !atEOL else {
                    throw TOMLEditError("TOML 1.0 doesn't allow line breaks inside an inline table { … }", at: start)
                }
                if b[i] == UInt8(ascii: "}") {
                    if afterComma { throw TOMLEditError("TOML 1.0 doesn't allow a trailing comma in an inline table", at: i) }
                    i += 1; return
                }
                _ = try key(); skipSpaces(); try expect("="); skipSpaces()
                try value(depth: depth + 1)
                skipSpaces()
                afterComma = false
                if i < b.count, b[i] == UInt8(ascii: ",") { i += 1; afterComma = true }
                else if i < b.count, b[i] != UInt8(ascii: "}") {
                    guard !atEOL else { throw TOMLEditError("TOML 1.0 doesn't allow line breaks inside an inline table { … }", at: start) }
                    throw TOMLEditError("expected ',' or '}' in inline table", at: i)
                }
            }
        default:
            // Bare scalar: number, bool, date/time. A date-time may contain one space.
            while i < b.count, !Self.terminatesScalar(b[i]) { i += 1 }
            if i - start == 10, i + 3 < b.count, b[i] == 0x20, isDigit(i + 1), isDigit(i + 2), b[i + 3] == UInt8(ascii: ":") {
                i += 1
                while i < b.count, !Self.terminatesScalar(b[i]) { i += 1 }
            }
            guard i > start else { throw TOMLEditError("expected value", at: start) }
            // TOML 1.0 times need seconds (`07:32:00`); TOMLDecoder also accepts the 1.1 form `07:32`.
            if let colon = b[start..<i].firstIndex(of: UInt8(ascii: ":")), !(colon + 3 < i && b[colon + 3] == UInt8(ascii: ":")) {
                throw TOMLEditError("TOML 1.0 times need seconds (HH:MM:SS)", at: start)
            }
        }
    }

    private func isDigit(_ j: Int) -> Bool { b[j] >= 0x30 && b[j] <= 0x39 }
    private static func terminatesScalar(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == UInt8(ascii: "#") || c == UInt8(ascii: ",")
            || c == UInt8(ascii: "]") || c == UInt8(ascii: "}")
    }
    private func hasPrefix(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return i + u.count <= b.count && Array(b[i..<(i + u.count)]) == u
    }
    private mutating func multiline(quote q: UInt8, escapes: Bool) throws(TOMLEditError) {
        let start = i
        i += 3
        while i < b.count {
            if escapes, b[i] == UInt8(ascii: "\\") {
                if i + 1 < b.count, b[i + 1] == UInt8(ascii: "e") || b[i + 1] == UInt8(ascii: "x") {
                    throw TOMLEditError("TOML 1.0 doesn't support the \\e or \\x escapes", at: i)
                }
                i += 2; continue
            }
            if b[i] == q, i + 2 < b.count, b[i + 1] == q, b[i + 2] == q {
                var run = 3
                while run < 5, i + run < b.count, b[i + run] == q { run += 1 }  // up to two quotes may end the content
                i += run
                return
            }
            i += 1
        }
        throw TOMLEditError("unterminated multi-line string", at: start)
    }
}
