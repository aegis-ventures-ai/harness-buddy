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
        try Self.validate(bytes)
        self.bytes = bytes
        newline = try TOMLScanner.scan(bytes).newline
    }

    public init(_ text: String) throws { try self.init(bytes: Array(text.utf8)) }

    public var text: String { String(decoding: bytes, as: UTF8.self) }

    /// Parsed view for reading values (TOMLDecoder's table).
    public func parsed() throws -> TOMLTable { try TOMLTable(source: bytes) }

    static func validate(_ bytes: [UInt8]) throws {
        do { _ = try TOMLTable(source: bytes) } catch {
            throw TOMLEditError("not valid TOML: \(error)")
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

        if case .table(let t) = value, let range = tableBlockRange(path, in: sections, keepAttachedComments: true) {
            let start = range.lowerBound, end = range.upperBound
            let trailing = end < bytes.count ? newline : ""  // keep the blank line before the next table
            return try splice(start..<end, with: TOMLRender.tableSections(path: path, t, newline: newline) + trailing)
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

    /// Removes `[path]`, all of its sub-tables (`[path.*]`), and the comment lines
    /// directly attached above each header. The sub-tables must follow the table
    /// contiguously (the normal layout); otherwise this throws.
    public mutating func removeTable(_ path: [String]) throws {
        let sections = try TOMLScanner.scan(bytes).sections
        guard var range = tableBlockRange(path, in: sections) else { throw TOMLEditError("no such table: \(path)") }
        if range.upperBound == bytes.count {
            // Last block in the file: also drop the blank lines that separated it.
            var s = range.lowerBound
            func endsWithBlankLine(_ s: Int) -> Bool {   // bytes[..<s] ends "\n\n" or "\n\r\n"
                s >= 2 && bytes[s - 1] == 0x0A && (bytes[s - 2] == 0x0A || (s >= 3 && bytes[s - 2] == 0x0D && bytes[s - 3] == 0x0A))
            }
            while endsWithBlankLine(s) { s -= bytes[s - 2] == 0x0D ? 2 : 1 }
            range = s..<range.upperBound
        }
        try splice(range, with: "")
    }

    // MARK: internals

    private func find(_ path: [String], in sections: [TOMLSection]) -> (TOMLSection, TOMLEntry)? {
        for s in sections { for e in s.entries where s.path + e.key == path { return (s, e) } }
        return nil
    }

    /// Byte range of `[path]` plus its contiguous `[path.*]` sub-tables, from the first
    /// header's attached comments up to the next unrelated section's attached comments.
    private func tableBlockRange(_ path: [String], in sections: [TOMLSection], keepAttachedComments: Bool = false) -> Range<Int>? {
        guard let idx = sections.firstIndex(where: { $0.kind == .table && $0.path == path }) else { return nil }
        var j = idx + 1
        while j < sections.count, sections[j].path.starts(with: path) { j += 1 }
        let end = j < sections.count ? sections[j].ownedStart : bytes.count
        let start = keepAttachedComments ? sections[idx].header!.lowerBound : sections[idx].ownedStart
        return start..<end
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
        var next = bytes
        next.replaceSubrange(range, with: Array(text.utf8))
        try Self.validate(next)
        bytes = next
    }
}
