import Foundation

public enum SubscriptionNameError: Error, Hashable, Sendable {
    case empty
    case duplicate(existing: String)

    public var message: String {
        switch self {
        case .empty: "Enter a name."
        case .duplicate(let existing): "“\(existing)” is already used. Names must be unique."
        }
    }
}

/// U-2: names are required and unique, compared case-insensitively after trimming whitespace.
public enum SubscriptionNames {
    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func validate(_ name: String, among subscriptions: [Subscription], excluding id: UUID? = nil) -> SubscriptionNameError? {
        let candidate = normalized(name)
        guard !candidate.isEmpty else { return .empty }
        if let clash = subscriptions.first(where: {
            $0.id != id && normalized($0.name).caseInsensitiveCompare(candidate) == .orderedSame
        }) {
            return .duplicate(existing: clash.name)
        }
        return nil
    }

    /// `base`, or `base 2`, `base 3`, … — the first that is unique.
    public static func unique(_ base: String, among subscriptions: [Subscription]) -> String {
        if validate(base, among: subscriptions) == nil { return normalized(base) }
        var n = 2
        while validate("\(base) \(n)", among: subscriptions) != nil { n += 1 }
        return "\(normalized(base)) \(n)"
    }
}
