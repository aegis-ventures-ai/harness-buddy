import Foundation

/// Persists the subscription list (order = menubar order) as JSON in Application Support.
/// Holds no secrets: subscriptions reference harness homes, never tokens.
public struct SubscriptionFile: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: SubscriptionFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SubscriptionFile(url: support.appending(path: "HarnessButler/subscriptions.json"))
    }

    private struct Payload: Codable {
        var version = 1
        var subscriptions: [Subscription]
    }

    /// `nil` when the file doesn't exist yet (first launch).
    public func load() throws -> [Subscription]? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Payload.self, from: data).subscriptions
    }

    public func save(_ subscriptions: [Subscription]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createPrivateDirectory(at: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Payload(subscriptions: subscriptions)).write(to: url, options: [.atomic])
        // Private to the user, like the rest of the app's data (spend totals, budgets).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}
