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
        /// Back-off of subscriptions whose last read failed, so a relaunch doesn't retry early.
        var retries: [UUID: RetryRecord]?
        /// Written by earlier builds: rate-limit quiet periods only.
        var blockedUntil: [UUID: Date]?
    }

    private func payload() -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.cache.decode(Payload.self, from: data)
    }

    public func load() -> [UUID: UsageSnapshot] {
        payload()?.snapshots ?? [:]
    }

    public func loadRetries() -> [UUID: RetryRecord] {
        guard let payload = payload() else { return [:] }
        var retries = payload.retries ?? [:]
        for (id, until) in payload.blockedUntil ?? [:] where retries[id] == nil {
            retries[id] = RetryRecord(lastAttempt: .distantPast, failures: 0, blockedUntil: until, issue: .rateLimited(retryAfter: nil))
        }
        return retries
    }

    public func save(_ snapshots: [UUID: UsageSnapshot], retries: [UUID: RetryRecord] = [:]) throws {
        try FileManager.default.createPrivateDirectory(at: url.deletingLastPathComponent())
        // Private to the user, like the rest of the app's data (spend totals, budgets).
        try JSONEncoder.cache.encode(Payload(snapshots: snapshots, retries: retries.isEmpty ? nil : retries)).writePrivately(to: url)
    }
}

/// A failing subscription's back-off state (U-12), persisted so relaunching the app doesn't reset it.
/// Holds times, a count and the row's issue (a short status message): no tokens or response data.
public struct RetryRecord: Codable, Hashable, Sendable {
    public var lastAttempt: Date
    public var failures: Int
    public var blockedUntil: Date?
    public var issue: UsageIssue

    public init(lastAttempt: Date, failures: Int, blockedUntil: Date?, issue: UsageIssue) {
        self.lastAttempt = lastAttempt
        self.failures = failures
        self.blockedUntil = blockedUntil
        self.issue = issue
    }
}

extension Data {
    /// Writes atomically with mode 0600 from the start: a temp file from mkstemp (always 0600) in the
    /// same folder, fsync, rename. `.atomic` would create it with the umask's mode first.
    public func writePrivately(to url: URL) throws {
        let path = url.path(percentEncoded: false)
        var template = Array("\(path).hb-XXXXXX".utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw SafeWriteError.posix("mkstemp", errno) }
        let tmp = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var renamed = false
        defer { if !renamed { unlink(tmp) } }
        do {
            defer { close(fd) }
            try SafeFileWriter.writeAll([UInt8](self), to: fd)
            guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw SafeWriteError.posix("fsync", errno) }
        }
        guard rename(tmp, path) == 0 else { throw SafeWriteError.posix("rename", errno) }
        renamed = true
    }
}

extension FileManager {
    /// Creates `url` (and parents) if needed and makes sure it is 0700, also when it already existed,
    /// e.g. created by another app or an earlier build.
    public func createPrivateDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
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
