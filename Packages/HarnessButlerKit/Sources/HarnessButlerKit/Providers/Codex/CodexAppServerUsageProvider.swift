import Foundation

/// Codex subscription usage via `codex app-server` (stdio JSON-RPC, no `"jsonrpc"` field).
///
/// One short-lived process per refresh: `initialize` → `initialized` → `account/rateLimits/read` → kill.
/// Codex refreshes its own token under its own lock; the app never touches `auth.json`.
/// See docs/spikes/02-codex-usage.md.
///
/// TODO(M1): passive fallback from `$CODEX_HOME/sessions/**/rollout-*.jsonl` when offline.
public struct CodexAppServerUsageProvider: UsageProvider {
    public let harness = Harness.codex

    public init() {}

    public func fetch(_ subscription: Subscription, context: UsageFetchContext) async -> UsageReport {
        guard let codex = context.environment.locate("codex") else { return .failure(.harnessMissing(.codex)) }

        var extra: [String: String] = [:]
        if let home = subscription.homeOverride, !home.isEmpty {
            extra["CODEX_HOME"] = subscription.homeURL(homeDirectory: context.environment.homeDirectory).path(percentEncoded: false)
        }

        let session: LineJSONRPCSession
        do {
            session = try LineJSONRPCSession(
                executable: codex,
                arguments: ["app-server"],
                environment: context.environment.environment(adding: extra),
                currentDirectory: context.scratchDirectory,
                includeVersionField: false,
                timeout: .seconds(10)
            )
        } catch {
            return .failure(.harnessMissing(.codex))
        }
        defer { session.close() }

        do {
            _ = try await session.request("initialize", params: [
                "clientInfo": ["name": "harness-butler", "title": "Harness Butler", "version": context.appVersion],
            ])
            try session.notify("initialized")
            let result = try await session.request("account/rateLimits/read", params: ["excludeResetCreditDetails": true])
            guard let object = result as? [String: Any] else {
                return .failure(.unsupported("Unexpected rate-limit response from Codex"))
            }
            return UsageReport(snapshot: Self.snapshot(from: object, fetchedAt: context.now))
        } catch let error as JSONRPCError {
            return .failure(Self.issue(for: error))
        } catch JSONRPCSessionError.timedOut {
            return .failure(.unavailable("Codex didn't answer in time"))
        } catch {
            return .failure(.unavailable("Codex app-server failed"))
        }
    }

    static func issue(for error: JSONRPCError) -> UsageIssue {
        if error.code == -32600, error.message.localizedCaseInsensitiveContains("authentication") {
            return .signedOut(hint: Harness.codex.loginHint)
        }
        if error.code == -32601 {
            return .unsupported("This Codex version can't report rate limits")
        }
        if error.message.contains("http") {
            return .unavailable("Can't reach OpenAI")
        }
        return .unavailable("Codex error \(error.code)")
    }

    /// Maps an `account/rateLimits/read` result. Windows are labelled from `windowDurationMins`,
    /// not field names, and every bucket in `rateLimitsByLimitId` is included.
    static func snapshot(from result: [String: Any], fetchedAt: Date) -> UsageSnapshot {
        var buckets: [(id: String, snapshot: [String: Any])] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            // Keep `codex` first, then the rest alphabetically for stable ordering.
            for key in byID.keys.sorted(by: { ($0 == "codex" ? "" : $0) < ($1 == "codex" ? "" : $1) }) {
                if let snapshot = JSONValue.object(byID[key]) { buckets.append((key, snapshot)) }
            }
        } else if let snapshot = JSONValue.object(result["rateLimits"]) {
            buckets.append((JSONValue.string(snapshot["limitId"]) ?? "codex", snapshot))
        }

        var windows: [UsageWindow] = []
        var plan: String?
        for bucket in buckets {
            plan = plan ?? JSONValue.string(bucket.snapshot["planType"])
            let prefix = bucket.id == "codex" ? nil : (JSONValue.string(bucket.snapshot["limitName"]) ?? bucket.id)
            for slot in ["primary", "secondary"] {
                guard let window = JSONValue.object(bucket.snapshot[slot]),
                      let used = JSONValue.double(window["usedPercent"]) else { continue }
                let minutes = JSONValue.double(window["windowDurationMins"])
                let label = durationLabel(minutes: minutes)
                windows.append(UsageWindow(
                    id: "\(bucket.id):\(slot)",
                    label: prefix.map { "\(label) · \($0)" } ?? label,
                    usedPercent: used,
                    resetsAt: JSONValue.double(window["resetsAt"]).map { Date(timeIntervalSince1970: $0) },
                    duration: minutes.map { $0 * 60 }
                ))
            }
        }
        return UsageSnapshot(windows: windows, planName: plan?.lowercased(), fetchedAt: fetchedAt, source: .live)
    }

    static func durationLabel(minutes: Double?) -> String {
        guard let minutes else { return "window" }
        switch Int(minutes) {
        case 300: return "5-hour session"
        case 10080: return "weekly"
        case let m where m % 1440 == 0: return "\(m / 1440)-day"
        case let m where m % 60 == 0: return "\(m / 60)-hour"
        case let m: return "\(m)-minute"
        }
    }
}
