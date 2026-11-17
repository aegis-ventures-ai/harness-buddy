import Foundation

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case context, added, removed }
    public var kind: Kind
    public var text: String
    /// 1-based line numbers in the old and new text.
    public var oldLine: Int?
    public var newLine: Int?
}

public struct DiffHunk: Hashable, Sendable, Identifiable {
    public var lines: [DiffLine]
    public var id: Int { (lines.first?.oldLine ?? 0) * 100_000 + (lines.first?.newLine ?? 0) }

    /// `@@ -12,7 +12,9 @@`
    public var header: String {
        let old = lines.compactMap(\.oldLine), new = lines.compactMap(\.newLine)
        return "@@ -\(old.first ?? 0),\(old.count) +\(new.first ?? 0),\(new.count) @@"
    }
}

/// Unified line diff for the save preview (C-5).
public enum LineDiff {
    public static func hunks(old: String, new: String, context: Int = 3) -> [DiffHunk] {
        let oldLines = lines(old), newLines = lines(new)
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var all: [DiffLine] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                all.append(DiffLine(kind: .removed, text: oldLines[i], oldLine: i + 1, newLine: nil))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                all.append(DiffLine(kind: .added, text: newLines[j], oldLine: nil, newLine: j + 1))
                j += 1
            } else if i < oldLines.count, j < newLines.count {
                all.append(DiffLine(kind: .context, text: oldLines[i], oldLine: i + 1, newLine: j + 1))
                i += 1
                j += 1
            } else {
                break
            }
        }

        // Group changes with up to `context` unchanged lines around them.
        let changed = all.indices.filter { all[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var hunks: [DiffHunk] = []
        var start = max(0, changed[0] - context), end = min(all.count - 1, changed[0] + context)
        for index in changed.dropFirst() {
            if index - context <= end + 1 {
                end = min(all.count - 1, index + context)
            } else {
                hunks.append(DiffHunk(lines: Array(all[start...end])))
                start = max(0, index - context)
                end = min(all.count - 1, index + context)
            }
        }
        hunks.append(DiffHunk(lines: Array(all[start...end])))
        return hunks
    }

    public static func counts(_ hunks: [DiffHunk]) -> (added: Int, removed: Int) {
        let lines = hunks.flatMap(\.lines)
        return (lines.count { $0.kind == .added }, lines.count { $0.kind == .removed })
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.trimmingSuffix("\r")) }
        if text.hasSuffix("\n") { result.removeLast() }
        return result
    }
}

private extension Substring {
    func trimmingSuffix(_ suffix: String) -> Substring { hasSuffix(suffix) ? dropLast(suffix.count) : self }
}
