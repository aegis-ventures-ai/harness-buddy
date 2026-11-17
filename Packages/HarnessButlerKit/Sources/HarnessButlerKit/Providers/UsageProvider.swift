import Foundation

/// Reads one subscription's usage. One implementation per harness or API; adding one is additive.
public protocol UsageProvider: Sendable {
    var harness: Harness { get }
    /// Which subscriptions this provider reads. Defaults to the harness's logins.
    var key: UsageProviderKey { get }
    func fetch(_ subscription: Subscription, context: UsageFetchContext) async -> UsageReport
}

extension UsageProvider {
    public var key: UsageProviderKey { .harness(harness) }
}

public enum UsageProviderKey: Hashable, Sendable {
    case harness(Harness)
    case api(APIProvider)
}

public struct UsageFetchContext: Sendable {
    public var environment: HarnessEnvironment
    public var now: Date
    /// Data a harness cached itself is good enough if it is younger than this.
    public var acceptableCacheAge: TimeInterval
    public var appVersion: String
    /// Empty, app-owned directory used as the working directory of spawned harnesses,
    /// so no project-level config or hooks load.
    public var scratchDirectory: URL

    public init(environment: HarnessEnvironment, now: Date, acceptableCacheAge: TimeInterval, appVersion: String, scratchDirectory: URL) {
        self.environment = environment
        self.now = now
        self.acceptableCacheAge = acceptableCacheAge
        self.appVersion = appVersion
        self.scratchDirectory = scratchDirectory
    }
}

/// Lenient JSON accessors for undocumented, fast-moving payloads.
enum LenientJSON {
    static func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    static func string(_ value: Any?) -> String? { value as? String }
    static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func array(_ value: Any?) -> [[String: Any]]? { value as? [[String: Any]] }
}

/// ISO 8601 parsing that tolerates 0–9 fractional digits and `Z` or `±hh:mm` offsets
/// (Claude sends microseconds, Grok milliseconds).
enum ISO8601 {
    private static let base = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = try? base.parse(string) { return date }
        // Normalise the fractional part to exactly 3 digits.
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let afterDot = string[string.index(after: dot)...]
        let digits = afterDot.prefix { $0.isASCII && $0.isNumber }
        let rest = afterDot.dropFirst(digits.count)
        let millis = String((digits + "000").prefix(3))
        return try? fractional.parse(string[..<dot] + "." + millis + rest)
    }
}
