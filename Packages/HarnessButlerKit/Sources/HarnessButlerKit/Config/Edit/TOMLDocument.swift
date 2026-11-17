import TOMLDecoder

/// A TOML file held as raw bytes, edited by splicing byte ranges.
///
/// Invariants:
/// - an unedited document renders byte-for-byte identical to its input;
/// - an edit only rewrites the bytes of the value, line or table it targets;
/// - every edit result is re-parsed by an independent TOML parser (TOMLDecoder)
///   and rejected if invalid, so a scanner bug cannot produce a broken file.
///
/// Unsupported shapes (editing inside `[[array.of.tables]]`, adding keys to a
/// table defined only by dotted keys) throw instead of silently doing nothing.
public struct TOMLDocument: Sendable {
    public private(set) var bytes: [UInt8]
    private var newline: String

    public init(bytes: [UInt8]) throws {
        newline = try TOMLScanner.scan(bytes).newline   // first: it bounds nesting depth for the parser
        try Self.validate(bytes)
        self.bytes = bytes
    }

    public init(_ text: String) throws { try self.init(bytes: Array(text.utf8)) }

    public var text: String { String(decoding: bytes, as: UTF8.self) }

    /// Parsed view for reading values (TOMLDecoder's table).
    public func parsed() throws -> TOMLTable { try TOMLTable(source: bytes) }

    static func validate(_ bytes: [UInt8]) throws {
        // TOMLDecoder parses scalars lazily; converting the whole table forces every value to be checked.
        do { _ = try [String: Any](TOMLTable(source: bytes)) } catch {
            // TOMLDecoder reports "(Line 3) Ill-formed key."; keep its wording.
            throw TOMLEditError("\(error)")
        }
    }

    // MARK: edits

    /// Sets the value at a full key path (table path + key), e.g. `["cli", "auto_update"]`.
    /// - Existing key: only the value bytes are replaced; indentation, spacing and
    ///   comments above and inline are untouched.
    /// - Missing key in an existing `[table]`: a line is appended after the table's last entry.
    /// - Table value for a missing path: emitted as `[path]` sections after the last sibling table.
    /// - Table value for an existing `[path]` table: that table and its sub-tables are replaced in place.
    public mutating func set(_ path: [String], to value: TOMLValue) throws {
        precondition(!path.isEmpty)
        let sections = try TOMLScanner.scan(bytes).sections

        if case .table(let t) = value, sections.contains(where: { $0.kind == .table && $0.path == path }) {
            // Replace the first block in place (keeping the comments above it) and drop the rest.
            var ranges = ownedRanges(path, in: sections)
            if let first = sections.first(where: { $0.kind != .root && $0.path.starts(with: path) }), ranges[0].lowerBound == first.ownedStart {
                ranges[0] = first.header!.lowerBound..<ranges[0].upperBound
            }
            let trailing = ranges[0].upperBound < bytes.count ? newline : ""  // keep the blank line before the next table
            let replacement = [(ranges[0], TOMLRender.tableSections(path: path, t, newline: newline) + trailing)]
            return try splice(replacement + ranges.dropFirst().map { ($0, "") })
        }

        // Something else lives under `path` (sub-tables, dotted keys): the new value replaces all of it.
        let nested = sections.contains { $0.kind != .root && $0.path.starts(with: path) }
            || sections.contains { s in s.entries.contains { (s.path + $0.key).count > path.count && (s.path + $0.key).starts(with: path) } }
        if nested {
            var copy = self
            try copy.removeTable(path)
            try copy.set(path, to: value)
            self = copy
            return
        }

        if let (section, entry) = find(path, in: sections) {
            guard section.kind != .arrayOfTables else { throw TOMLEditError("editing inside [[array of tables]] is not supported") }
            return try splice(entry.value, with: TOMLRender.inline(value))
        }

        let parent = Array(path.dropLast()), key = path.last!
        if case .table(let t) = value {
            return try insertNewTable(path, t, sections: sections)
        }
        if let section = sections.last(where: { $0.kind == .table && $0.path == parent }) ?? (parent.isEmpty ? sections[0] : nil) {
            return try insertEntry(key, value, into: section, sections: sections)
        }
        // Parent table does not exist: create it.
        try insertNewTable(parent, [key: value], sections: sections)
    }

    /// Removes a key. Removes the whole line, including its inline comment.
    public mutating func remove(_ path: [String]) throws {
        let sections = try TOMLScanner.scan(bytes).sections
        guard let (_, entry) = find(path, in: sections) else { throw TOMLEditError("no such key: \(path)") }
        try splice(entry.line, with: "")
    }

    /// Removes `[path]`, all of its sub-tables (`[path.*]`, wherever they are), dotted keys under
    /// `path` in other tables, and the comment lines directly attached above each removed header.
    public mutating func removeTable(_ path: [String]) throws {
        let sections = try TOMLScanner.scan(bytes).sections
        var ranges = ownedRanges(path, in: sections)
        guard !ranges.isEmpty else { throw TOMLEditError("no such table: \(path)") }
        if let last = ranges.last, last.upperBound == bytes.count {
            // Last block in the file: also drop the blank lines that separated it.
            var s = last.lowerBound
            func endsWithBlankLine(_ s: Int) -> Bool {   // bytes[..<s] ends "\n\n" or "\n\r\n"
                s >= 2 && bytes[s - 1] == 0x0A && (bytes[s - 2] == 0x0A || (s >= 3 && bytes[s - 2] == 0x0D && bytes[s - 3] == 0x0A))
            }
            while endsWithBlankLine(s) { s -= bytes[s - 2] == 0x0D ? 2 : 1 }
            ranges[ranges.count - 1] = s..<last.upperBound
        }
        try splice(ranges.map { ($0, "") })
    }

    /// The full key of an entry whose inline-table value (`key = { … }`) contains `path`.
    func inlineTableKey(containing path: [String]) throws -> [String]? {
        for section in try TOMLScanner.scan(bytes).sections where section.kind != .arrayOfTables {
            for entry in section.entries {
                let full = section.path + entry.key
                if full.count < path.count, path.starts(with: full), bytes[entry.value.lowerBound] == UInt8(ascii: "{") { return full }
            }
        }
        return nil
    }

    // MARK: internals

    private func find(_ path: [String], in sections: [TOMLSection]) -> (TOMLSection, TOMLEntry)? {
        for s in sections { for e in s.entries where s.path + e.key == path { return (s, e) } }
        return nil
    }

    /// Every byte range that defines something under `path`: each `[path]` / `[path.*]` /
    /// `[[path.*]]` section (from its attached comments to the next section's), and each entry line
    /// elsewhere whose dotted key lands under `path`. Sorted, adjacent ranges merged.
    private func ownedRanges(_ path: [String], in sections: [TOMLSection]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for (index, section) in sections.enumerated() {
            if section.kind != .root, section.path.starts(with: path) {
                let end = index + 1 < sections.count ? sections[index + 1].ownedStart : bytes.count
                ranges.append(section.ownedStart..<end)
            } else {
                for entry in section.entries where (section.path + entry.key).starts(with: path) { ranges.append(entry.line) }
            }
        }
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private mutating func insertEntry(_ key: String, _ value: TOMLValue, into section: TOMLSection, sections: [TOMLSection]) throws {
        var at = section.contentEnd
        var indent = ""
        if let last = section.entries.last {
            indent = String(decoding: bytes[last.line].prefix { $0 == 0x20 || $0 == 0x09 }, as: UTF8.self)
        } else if section.kind == .root {
            at = sections.count > 1 ? sections[1].ownedStart : bytes.count  // root keys must precede the first header
        }
        var text = indent + TOMLRender.key(key) + " = " + TOMLRender.inline(value) + newline
        if at > 0, at == bytes.count, bytes[at - 1] != 0x0A { text = newline + text }
        if section.kind == .root, section.entries.isEmpty, at < bytes.count { text += newline }
        try splice(at..<at, with: text)
    }

    private mutating func insertNewTable(_ path: [String], _ t: OrderedPairs<TOMLValue>, sections: [TOMLSection]) throws {
        // Place after the last table sharing the parent prefix (e.g. after the last
        // [mcp_servers.*]); otherwise at the end of the file.
        let parent = Array(path.dropLast())
        let anchor = parent.isEmpty ? nil : sections.lastIndex { $0.kind != .root && $0.path.starts(with: parent) }
        let at = anchor.map { sections[$0].contentEnd } ?? bytes.count
        var text = TOMLRender.tableSections(path: path, t, newline: newline)
        if at > 0 { text = newline + text }                         // blank line before the header
        if at > 0, bytes[at - 1] != 0x0A { text = newline + text }   // file lacked a final newline
        try splice(at..<at, with: text)
    }

    private mutating func splice(_ range: Range<Int>, with text: String) throws {
        try splice([(range, text)])
    }

    /// Replace non-overlapping ranges in one validated step.
    private mutating func splice(_ edits: [(Range<Int>, String)]) throws {
        var next = bytes
        for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            next.replaceSubrange(range, with: Array(text.utf8))
        }
        try Self.validate(next)
        bytes = next
    }
}
