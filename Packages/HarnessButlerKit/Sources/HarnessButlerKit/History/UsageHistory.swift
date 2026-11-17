import Foundation
import SQLite3
import Synchronization

/// One recorded reading of a window.
public struct UsageSample: Hashable, Sendable {
    public var at: Date
    public var usedPercent: Double

    public init(at: Date, usedPercent: Double) {
        self.at = at
        self.usedPercent = usedPercent
    }
}

/// Usage consumed on one local calendar day, in percent of the window.
public struct DailyUsage: Hashable, Sendable {
    public var day: Date
    public var percent: Double
}

/// U-10: window readings kept in a local SQLite file for sparklines and trends.
///
/// Only percentages and times are stored, keyed by subscription ID and window ID: no names,
/// paths, plans or account data. The file is 0600 in a 0700 directory, never leaves the Mac,
/// and samples older than `retention` are deleted.
public final class UsageHistory: Sendable {
    public static let retention: TimeInterval = 35 * 86_400
    /// A reading equal to the previous one is skipped unless this long has passed.
    static let unchangedInterval: TimeInterval = 30 * 60

    private struct State: ~Copyable {
        var db: OpaquePointer?
        /// Last sample written per "subscription|window", to skip unchanged readings.
        var last: [String: UsageSample] = [:]
        var lastPrune: Date = .distantPast
    }

    private let state: Mutex<State>
    public let url: URL

    public static var standardURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "HarnessButler/history.sqlite")
    }

    /// Opens (creating if needed) the database at `url`.
    public init(url: URL = UsageHistory.standardURL) throws {
        self.url = url
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createPrivateDirectory(at: directory)
        let path = url.path(percentEncoded: false)
        // Create the file 0600 first: SQLite gives its journal files the database file's mode.
        if !fm.fileExists(atPath: path) {
            guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw HistoryError("Couldn't create \(url.lastPathComponent)")
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw HistoryError(message)
        }
        state = Mutex(State(db: db))
        try execute("""
            PRAGMA journal_mode = DELETE;
            CREATE TABLE IF NOT EXISTS samples (
                subscription TEXT NOT NULL,
                window TEXT NOT NULL,
                at REAL NOT NULL,
                used REAL NOT NULL,
                PRIMARY KEY (subscription, window, at)
            ) WITHOUT ROWID;
            """)
    }

    deinit {
        state.withLock { sqlite3_close($0.db) }
    }

    // MARK: Writing

    /// Records each window of `snapshot` (budget windows excluded: they're derived from spend,
    /// which keeps its own per-day series). Unchanged readings are thinned to one per 30 minutes.
    public func record(_ snapshot: UsageSnapshot, for subscription: UUID) {
        let windows = snapshot.windows.filter { $0.id != APISpend.budgetWindowID }
        guard !windows.isEmpty else { return }
        state.withLock { state in
            guard let db = state.db else { return }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            for window in windows {
                let key = subscription.uuidString + "|" + window.id
                let sample = UsageSample(at: snapshot.fetchedAt, usedPercent: window.usedPercent)
                if let last = state.last[key] {
                    if sample.at <= last.at { continue }
                    if sample.usedPercent == last.usedPercent, sample.at.timeIntervalSince(last.at) < Self.unchangedInterval { continue }
                }
                Self.run(db, "INSERT OR IGNORE INTO samples (subscription, window, at, used) VALUES (?, ?, ?, ?)",
                         [.text(subscription.uuidString), .text(window.id), .real(sample.at.timeIntervalSince1970), .real(sample.usedPercent)])
                state.last[key] = sample
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            if snapshot.fetchedAt.timeIntervalSince(state.lastPrune) > 86_400 {
                Self.run(db, "DELETE FROM samples WHERE at < ?", [.real(snapshot.fetchedAt.timeIntervalSince1970 - Self.retention)])
                state.lastPrune = snapshot.fetchedAt
            }
        }
    }

    /// Deletes a removed subscription's history.
    public func delete(subscription: UUID) {
        state.withLock { state in
            guard let db = state.db else { return }
            Self.run(db, "DELETE FROM samples WHERE subscription = ?", [.text(subscription.uuidString)])
            state.last = state.last.filter { !$0.key.hasPrefix(subscription.uuidString + "|") }
        }
    }

    /// Deletes samples older than the retention period.
    public func prune(now: Date = .now) {
        state.withLock { state in
            guard let db = state.db else { return }
            Self.run(db, "DELETE FROM samples WHERE at < ?", [.real(now.timeIntervalSince1970 - Self.retention)])
            state.lastPrune = now
        }
    }

    // MARK: Reading

    public func samples(subscription: UUID, window: String, since: Date) -> [UsageSample] {
        state.withLock { state in
            guard let db = state.db else { return [] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT at, used FROM samples WHERE subscription = ? AND window = ? AND at >= ? ORDER BY at",
                                     -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, [.text(subscription.uuidString), .text(window), .real(since.timeIntervalSince1970)])
            var result: [UsageSample] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(UsageSample(at: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                                          usedPercent: sqlite3_column_double(statement, 1)))
            }
            return result
        }
    }

    public func sampleCount() -> Int {
        state.withLock { state in
            guard let db = state.db else { return 0 }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples", -1, &statement, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
        }
    }

    /// Percent of `window` used on each of the last `days` local days (the U-9 sparkline):
    /// the sum of increases between consecutive readings. A drop means the window reset, so the
    /// new reading counts from zero.
    public func dailyUsage(subscription: UUID, window: String, days: Int = 7, now: Date = .now, calendar: Calendar = .current) -> [DailyUsage] {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        // One earlier reading gives the first day's baseline.
        let readings = samples(subscription: subscription, window: window, since: first.addingTimeInterval(-2 * 86_400))
        return Self.dailyIncrease(readings, from: first, days: days, calendar: calendar)
    }

    static func dailyIncrease(_ readings: [UsageSample], from first: Date, days: Int, calendar: Calendar) -> [DailyUsage] {
        var buckets = [Double](repeating: 0, count: days)
        var previous: UsageSample?
        for reading in readings.sorted(by: { $0.at < $1.at }) {
            defer { previous = reading }
            guard let previous else { continue }
            let increase = reading.usedPercent >= previous.usedPercent ? reading.usedPercent - previous.usedPercent : reading.usedPercent
            guard increase > 0, reading.at >= first else { continue }
            let index = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: reading.at)).day ?? -1
            if buckets.indices.contains(index) { buckets[index] += increase }
        }
        return buckets.enumerated().map { offset, percent in
            DailyUsage(day: calendar.date(byAdding: .day, value: offset, to: first) ?? first, percent: percent)
        }
    }

    // MARK: SQLite plumbing

    private enum Value { case text(String), real(Double) }

    private func execute(_ sql: String) throws {
        try state.withLock { state in
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(state.db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "SQLite error"
                sqlite3_free(error)
                throw HistoryError(message)
            }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bind(_ statement: OpaquePointer?, _ values: [Value]) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            case .real(let real): sqlite3_bind_double(statement, position, real)
            }
        }
    }

    @discardableResult
    private static func run(_ db: OpaquePointer, _ sql: String, _ values: [Value]) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        return sqlite3_step(statement) == SQLITE_DONE
    }
}

public struct HistoryError: Error, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}
