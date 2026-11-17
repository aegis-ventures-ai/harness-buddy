import Foundation

/// Grok Build subscription usage via `grok agent stdio` (ACP) and the undocumented `_x.ai/billing` method.
///
/// One short-lived process per refresh, telemetry and auto-update disabled, working directory set to an
/// empty app-owned folder so no project config loads. Never sends `session/new`.
/// See docs/spikes/03-grok-usage.md.
public struct GrokACPUsageProvider: UsageProvider {
    public let harness = Harness.grok

    public init() {}

    public func fetch(_ subscription: Subscription, context: UsageFetchContext) async -> UsageReport {
        let home = subscription.homeURL(homeDirectory: context.environment.homeDirectory)
        let preferred = [
            home.appending(path: "bin/grok"),
            context.environment.homeDirectory.appending(path: ".grok/bin/grok"),
        ]
        guard let grok = context.environment.locate("grok", preferring: preferred) else {
            return .failure(.harnessMissing(.grok))
        }

        var extra = [
            "GROK_TELEMETRY_ENABLED": "0",
            "GROK_TELEMETRY_MIXPANEL_ENABLED": "false",
            "GROK_DISABLE_AUTOUPDATER": "1",
        ]
        if let override = subscription.homeOverride, !override.isEmpty {
            extra["GROK_HOME"] = home.path(percentEncoded: false)
        }

        let session: LineJSONRPCSession
        do {
            session = try LineJSONRPCSession(
                executable: grok,
                arguments: ["agent", "stdio"],
                environment: context.environment.environment(adding: extra),
                currentDirectory: context.scratchDirectory,
                includeVersionField: true,
                timeout: .seconds(10)
            )
        } catch {
            return .failure(.harnessMissing(.grok))
        }
        defer { session.close() }

        do {
            _ = try await session.request("initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "harness-butler", "title": "Harness Butler", "version": context.appVersion],
            ])
            let result = try await session.request("_x.ai/billing")
            guard let object = result as? [String: Any], let snapshot = Self.snapshot(from: object, fetchedAt: context.now) else {
                return .failure(Self.unsupported)
            }
            return UsageReport(snapshot: snapshot)
        } catch let error as JSONRPCError {
            if error.code == -32601 { return .failure(Self.unsupported) }
            if error.message.localizedCaseInsensitiveContains("grok login") || error.message.localizedCaseInsensitiveContains("auth") {
                return .failure(.signedOut(hint: Harness.grok.loginHint))
            }
            return .failure(.unavailable("Grok error \(error.code)"))
        } catch JSONRPCSessionError.timedOut {
            return .failure(.unavailable("Grok didn't answer in time"))
        } catch {
            return .failure(.unavailable("Grok agent failed"))
        }
    }

    static let unsupported = UsageIssue.unsupported("Grok usage unavailable in this version. Run /usage in grok")

    /// Maps a `_x.ai/billing` result to one window (weekly on the plans seen so far).
    static func snapshot(from result: [String: Any], fetchedAt: Date) -> UsageSnapshot? {
        guard let config = LenientJSON.object(result["config"]),
              let used = LenientJSON.double(config["creditUsagePercent"]) else { return nil }
        let period = LenientJSON.object(config["currentPeriod"])
        let start = ISO8601.date(LenientJSON.string(period?["start"]))
        let end = ISO8601.date(LenientJSON.string(period?["end"]))
        let type = LenientJSON.string(period?["type"]) ?? ""
        let label = switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY": "weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY": "monthly"
        case "USAGE_PERIOD_TYPE_DAILY": "daily"
        default: "usage period"
        }
        let duration: TimeInterval? = if let start, let end, end > start { end.timeIntervalSince(start) } else { nil }
        let tier = LenientJSON.string(result["subscription_tier"]).map { $0.lowercased() }
        return UsageSnapshot(
            windows: [UsageWindow(id: "credits", label: label, usedPercent: used, resetsAt: end, duration: duration)],
            planName: tier,
            fetchedAt: fetchedAt,
            source: .live
        )
    }
}
