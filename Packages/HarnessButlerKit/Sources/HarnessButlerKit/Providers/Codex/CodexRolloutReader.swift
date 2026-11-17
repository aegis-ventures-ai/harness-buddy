import Foundation

/// Passive Codex fallback: the newest `token_count` event's `rate_limits` in
/// `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`, written while the user works in Codex.
///
/// Rollout files contain prompts and replies, so only the tail of the newest file is read, and only
/// lines that carry `"rate_limits"` are parsed.
enum CodexRolloutReader {
    static let tailBytes = 512 * 1024
    static let maxFilesToScan = 5

    static func latestSnapshot(codexHome: URL, fileManager: FileManager = .default) -> UsageSnapshot? {
        for file in newestRollouts(in: codexHome.appending(path: "sessions", directoryHint: .isDirectory), fileManager: fileManager) {
            if let snapshot = snapshot(fromTailOf: file) { return snapshot }
        }
        return nil
    }

    /// Newest files first. Directory names are dates, so walk the newest day folders only.
    static func newestRollouts(in sessions: URL, fileManager: FileManager) -> [URL] {
        func children(_ url: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var files: [(url: URL, modified: Date)] = []
        outer: for year in children(sessions) {
            for month in children(year) {
                for day in children(month) {
                    for file in children(day) where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        files.append((file, modified))
                    }
                    if files.count >= maxFilesToScan { break outer }
                }
            }
        }
        return files.sorted { $0.modified > $1.modified }.map(\.url)
    }

    static func snapshot(fromTailOf file: URL) -> UsageSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }

        let marker = Data(#""rate_limits""#.utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
            if let snapshot = snapshot(fromLine: Data(line)) { return snapshot }
        }
        return nil
    }

    static func snapshot(fromLine line: Data) -> UsageSnapshot? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = JSONValue.object(event["payload"]),
              JSONValue.string(payload["type"]) == "token_count",
              let limits = JSONValue.object(payload["rate_limits"]),
              let timestamp = ISO8601.date(JSONValue.string(event["timestamp"])) else { return nil }

        func window(_ raw: Any?) -> [String: Any]? {
            guard let raw = JSONValue.object(raw) else { return nil }
            var window: [String: Any] = [:]
            window["usedPercent"] = raw["used_percent"]
            window["windowDurationMins"] = raw["window_minutes"]
            window["resetsAt"] = raw["resets_at"]
            return window
        }
        var normalized: [String: Any] = [:]
        normalized["limitId"] = limits["limit_id"]
        normalized["limitName"] = limits["limit_name"]
        normalized["planType"] = limits["plan_type"]
        normalized["primary"] = window(limits["primary"])
        normalized["secondary"] = window(limits["secondary"])

        var snapshot = CodexAppServerUsageProvider.snapshot(from: ["rateLimits": normalized], fetchedAt: timestamp)
        guard !snapshot.windows.isEmpty else { return nil }
        snapshot.source = .harnessCache
        return snapshot
    }
}
