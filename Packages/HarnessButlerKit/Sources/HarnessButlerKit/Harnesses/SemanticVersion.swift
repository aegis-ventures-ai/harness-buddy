import Foundation

/// A dotted version pulled out of free-form output such as `codex-cli 0.167.2`,
/// `grok 1.0.88 (2fe3608f7398) [stable]`, `2.1.326 (Claude Code)` or `rust-v0.169.0`.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?/) else { return nil }
        // Each component must fit an Int: a 30-digit run isn't a version.
        let digits = [match.1, match.2] + [match.3, match.4].compactMap { $0 }
        let parts = digits.compactMap { Int($0) }
        guard parts.count == digits.count else { return nil }
        components = parts
        prerelease = match.5.map(String.init)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        // A prerelease sorts before its release: 1.0.0-alpha < 1.0.0.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (l?, r?): return l.compare(r, options: .numeric) == .orderedAscending
        }
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }
}
