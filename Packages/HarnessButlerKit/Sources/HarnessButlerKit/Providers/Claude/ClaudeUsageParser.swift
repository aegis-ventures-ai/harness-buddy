import Foundation

/// Maps Claude's `/api/oauth/usage` response (also cached in `.claude.json`) to windows.
/// See docs/spikes/01-claude-code-usage.md.
enum ClaudeUsageParser {
    static let sessionDuration: TimeInterval = 5 * 3600
    static let weeklyDuration: TimeInterval = 7 * 86400

    /// The windows in a usage payload, or `nil` when it doesn't have a shape we know. A payload
    /// we can't read must not replace the last good snapshot with an empty or shorter one.
    static func windows(from usage: [String: Any]) -> [UsageWindow]? {
        if let limits = usage["limits"], !(limits is NSNull) {
            // Every row must parse: silently dropping one would hide that window.
            guard let rows = limits as? [Any] else { return nil }
            var windows: [UsageWindow] = []
            for row in rows {
                guard let row = row as? [String: Any], let window = window(fromLimit: row) else { return nil }
                windows.append(window)
            }
            // An empty list defers to the older fixed keys when they're there (spike 01).
            if !windows.isEmpty { return windows }
            return legacyWindows(from: usage) ?? []
        }
        return legacyWindows(from: usage)
    }

    /// The generic, forward-compatible `limits[]` rows.
    private static func window(fromLimit limit: [String: Any]) -> UsageWindow? {
        guard let kind = LenientJSON.string(limit["kind"]), let percent = LenientJSON.double(limit["percent"]) else { return nil }
        let group = LenientJSON.string(limit["group"])
        let scopeModel = LenientJSON.string(LenientJSON.object(LenientJSON.object(limit["scope"])?["model"])?["display_name"])
        let duration: TimeInterval? = switch group ?? kind {
        case "session": sessionDuration
        case "weekly": weeklyDuration
        default: nil
        }
        let label: String = switch kind {
        case "session": "5-hour session"
        case "weekly_all": "weekly · all models"
        case "weekly_scoped": "weekly · \(scopeModel?.lowercased() ?? "scoped")"
        default: kind.replacingOccurrences(of: "_", with: " ")
        }
        return UsageWindow(
            id: scopeModel.map { "\(kind):\($0)" } ?? kind,
            label: label,
            usedPercent: percent,
            resetsAt: ISO8601.date(LenientJSON.string(limit["resets_at"])),
            duration: duration
        )
    }

    /// Older fixed keys, used if `limits[]` is missing. `nil` when none of them is there either.
    private static func legacyWindows(from usage: [String: Any]) -> [UsageWindow]? {
        let keys: [(key: String, label: String, duration: TimeInterval)] = [
            ("five_hour", "5-hour session", sessionDuration),
            ("seven_day", "weekly · all models", weeklyDuration),
            ("seven_day_opus", "weekly · opus", weeklyDuration),
            ("seven_day_sonnet", "weekly · sonnet", weeklyDuration),
        ]
        let present = keys.filter { usage[$0.key] != nil }
        guard !present.isEmpty else { return nil }
        var windows: [UsageWindow] = []
        for entry in present where !(usage[entry.key] is NSNull) {   // null: not on this plan
            guard let bucket = LenientJSON.object(usage[entry.key]),
                  let utilization = LenientJSON.double(bucket["utilization"]) else { return nil }
            windows.append(UsageWindow(
                id: entry.key,
                label: entry.label,
                usedPercent: utilization,
                resetsAt: ISO8601.date(LenientJSON.string(bucket["resets_at"])),
                duration: entry.duration
            ))
        }
        return windows
    }

    /// Extra usage credits from `spend` (preferred) or `extra_usage`.
    static func credits(from usage: [String: Any]) -> UsageCredits? {
        if let spend = LenientJSON.object(usage["spend"]), spend["enabled"] as? Bool == true,
           let used = LenientJSON.object(spend["used"]), let usedMinor = LenientJSON.int(used["amount_minor"]) {
            let limit = LenientJSON.object(spend["limit"])
            return UsageCredits(
                usedMinor: usedMinor,
                limitMinor: LenientJSON.int(limit?["amount_minor"]),
                currency: LenientJSON.string(used["currency"]) ?? "USD",
                exponent: LenientJSON.int(used["exponent"]) ?? 2
            )
        }
        if let extra = LenientJSON.object(usage["extra_usage"]), extra["is_enabled"] as? Bool == true,
           let used = LenientJSON.double(extra["used_credits"]) {
            return UsageCredits(
                usedMinor: Int(used.rounded()),
                limitMinor: LenientJSON.int(extra["monthly_limit"]),
                currency: LenientJSON.string(extra["currency"]) ?? "USD",
                exponent: LenientJSON.int(extra["decimal_places"]) ?? 2
            )
        }
        return nil
    }

    /// Plan label: `planDisplayName`, else the subscription type plus a `rateLimitTier` multiplier.
    static func planName(displayName: String?, subscriptionType: String?, rateLimitTier: String?) -> String? {
        if let displayName, !displayName.isEmpty { return displayName.lowercased() }
        guard let type = subscriptionType?.lowercased(), !type.isEmpty else { return nil }
        let base = type.hasPrefix("claude_") ? String(type.dropFirst("claude_".count)) : type
        if let tier = rateLimitTier?.lowercased(),
           let match = tier.firstMatch(of: /_(\d+)x$/) {
            return "\(base) \(match.1)×"
        }
        return base
    }
}
