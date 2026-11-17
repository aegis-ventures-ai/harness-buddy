import Foundation

/// Maps Claude's `/api/oauth/usage` response (also cached in `.claude.json`) to windows.
/// See docs/spikes/01-claude-code-usage.md.
enum ClaudeUsageParser {
    static let sessionDuration: TimeInterval = 5 * 3600
    static let weeklyDuration: TimeInterval = 7 * 86400

    static func windows(from usage: [String: Any]) -> [UsageWindow] {
        if let limits = LenientJSON.array(usage["limits"]), !limits.isEmpty {
            let windows = limits.compactMap(window(fromLimit:))
            if !windows.isEmpty { return windows }
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

    /// Older fixed keys, used if `limits[]` is missing.
    private static func legacyWindows(from usage: [String: Any]) -> [UsageWindow] {
        let keys: [(key: String, label: String, duration: TimeInterval)] = [
            ("five_hour", "5-hour session", sessionDuration),
            ("seven_day", "weekly · all models", weeklyDuration),
            ("seven_day_opus", "weekly · opus", weeklyDuration),
            ("seven_day_sonnet", "weekly · sonnet", weeklyDuration),
        ]
        return keys.compactMap { entry in
            guard let bucket = LenientJSON.object(usage[entry.key]),
                  let utilization = LenientJSON.double(bucket["utilization"]) else { return nil }
            return UsageWindow(
                id: entry.key,
                label: entry.label,
                usedPercent: utilization,
                resetsAt: ISO8601.date(LenientJSON.string(bucket["resets_at"])),
                duration: entry.duration
            )
        }
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
