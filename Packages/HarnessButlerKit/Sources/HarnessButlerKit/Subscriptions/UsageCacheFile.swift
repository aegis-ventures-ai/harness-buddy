import Foundation

/// Last good snapshot per subscription, so the popover isn't empty after a relaunch (NFR: resilience).
/// Holds percentages, reset times and plan names only.
public struct UsageCacheFile: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: UsageCacheFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return UsageCacheFile(url: support.appending(path: "HarnessButler/usage-cache.json"))
    }

    private struct Payload: Codable {
        var version = 1
        var snapshots: [UUID: UsageSnapshot]
    }

    public func load() -> [UUID: UsageSnapshot] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder.cache.decode(Payload.self, from: data) else { return [:] }
        return payload.snapshots
    }

    public func save(_ snapshots: [UUID: UsageSnapshot]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder.cache.encode(Payload(snapshots: snapshots)).write(to: url, options: [.atomic])
    }
}

private extension JSONEncoder {
    static var cache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var cache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
