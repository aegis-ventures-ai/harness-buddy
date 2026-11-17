import Foundation

/// Updater output as a terminal would show it: `\r` rewrites the current line (progress bars),
/// ANSI escape sequences are dropped, and only the last `limit` lines are kept.
public struct TerminalLog: Hashable, Sendable {
    public private(set) var lines: [String] = []
    private var current = ""
    private var pendingCarriageReturn = false
    public var limit: Int

    public init(limit: Int = 400) {
        self.limit = limit
    }

    /// Completed lines plus the line in progress.
    public var displayLines: [String] {
        current.isEmpty ? lines : lines + [current]
    }

    public var text: String { displayLines.joined(separator: "\n") }

    public mutating func append(_ chunk: String) {
        for character in Self.stripANSI(chunk) {
            switch character {
            case "\r\n", "\n":
                lines.append(current)
                current = ""
                pendingCarriageReturn = false
            case "\r":
                pendingCarriageReturn = true
            default:
                if pendingCarriageReturn {
                    current = ""
                    pendingCarriageReturn = false
                }
                current.append(character)
            }
        }
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    /// Append a line written by the app itself (e.g. the command being run).
    public mutating func appendLine(_ line: String) {
        if !current.isEmpty {
            lines.append(current)
            current = ""
        }
        lines.append(line)
    }

    static func stripANSI(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]|\u{1B}\][^\u{07}]*\u{07}|\u{1B}[@-Z\\-_]/, with: "")
    }
}
