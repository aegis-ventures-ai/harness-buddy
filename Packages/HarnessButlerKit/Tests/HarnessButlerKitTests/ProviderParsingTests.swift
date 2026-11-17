import Foundation
import Testing
@testable import HarnessButlerKit

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

@Suite struct ClaudeParsingTests {
    // Trimmed from the redacted example in docs/spikes/01-claude-code-usage.md.
    static let usage = """
    {
      "five_hour": {"utilization": 4.0, "resets_at": "2026-11-17T18:49:59.828031+00:00"},
      "seven_day": {"utilization": 17.0, "resets_at": "2026-11-20T16:59:59.828057+00:00"},
      "seven_day_opus": null, "tangelo": null,
      "extra_usage": {"is_enabled": true, "monthly_limit": 20000, "used_credits": 0.0, "currency": "USD", "decimal_places": 2},
      "limits": [
        {"kind": "session", "group": "session", "percent": 4, "severity": "normal", "resets_at": "2026-11-17T18:49:59.828031+00:00", "scope": null},
        {"kind": "weekly_all", "group": "weekly", "percent": 17, "severity": "normal", "resets_at": "2026-11-20T16:59:59.828057+00:00", "scope": null},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal", "resets_at": "2026-11-20T16:59:59.828057+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
      ],
      "spend": {"used": {"amount_minor": 1240, "currency": "USD", "exponent": 2}, "limit": {"amount_minor": 5000, "currency": "USD", "exponent": 2}, "enabled": true}
    }
    """

    @Test func prefersGenericLimitsRows() throws {
        let windows = ClaudeUsageParser.windows(from: try json(Self.usage))
        #expect(windows.map(\.id) == ["session", "weekly_all", "weekly_scoped:Fable"])
        #expect(windows.map(\.label) == ["5-hour session", "weekly · all models", "weekly · fable"])
        #expect(windows.map(\.usedPercent) == [4, 17, 0])
        #expect(windows[0].duration == TimeInterval(5 * 3600))
        #expect(windows[1].duration == TimeInterval(7 * 86400))
        let reset = try #require(windows[0].resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_794_941_399.828) < 0.01)
    }

    @Test func fallsBackToFixedKeysWithoutLimits() throws {
        var usage = try json(Self.usage)
        usage["limits"] = nil
        let windows = ClaudeUsageParser.windows(from: usage)
        #expect(windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(windows.map(\.usedPercent) == [4, 17])
    }

    @Test func readsSpendAsCredits() throws {
        let credits = try #require(ClaudeUsageParser.credits(from: try json(Self.usage)))
        #expect(credits == UsageCredits(usedMinor: 1240, limitMinor: 5000, currency: "USD", exponent: 2))
    }

    @Test func planLabels() {
        #expect(ClaudeUsageParser.planName(displayName: "Max 20x", subscriptionType: "max", rateLimitTier: nil) == "max 20x")
        #expect(ClaudeUsageParser.planName(displayName: nil, subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "max 20×")
        #expect(ClaudeUsageParser.planName(displayName: nil, subscriptionType: "claude_enterprise", rateLimitTier: nil) == "enterprise")
        #expect(ClaudeUsageParser.planName(displayName: nil, subscriptionType: nil, rateLimitTier: "default_claude_max_5x") == nil)
    }

    @Test func passiveCacheKeepsOnlyUsageAndPlan() throws {
        let root = try json("""
        {"oauthAccount": {"emailAddress": "someone@example.com", "organizationType": "claude_max", "userRateLimitTier": "default_claude_max_5x"},
         "cachedUsageUtilization": {"fetchedAtMs": 1794900000000, "accountUuid": "x", "utilization": \(Self.usage)}}
        """)
        let config = ClaudeGlobalConfig.parse(root)
        let snapshot = try #require(config.snapshot)
        #expect(snapshot.source == .harnessCache)
        #expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 1_794_900_000))
        #expect(snapshot.planName == "max 5×")
        #expect(snapshot.windows.count == 3)
    }

    @Test func credentialParsingKeepsOnlyClaudeFields() throws {
        let data = Data("""
        {"claudeAiOauth": {"accessToken": "tok", "refreshToken": "never", "expiresAt": 1794900000000,
                           "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"},
         "mcpOAuth": {"plugin:x:y|1": {"accessToken": "other"}}}
        """.utf8)
        let creds = try #require(ClaudeCredentials.parse(data))
        #expect(creds.accessToken == "tok")
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_794_900_000))
        #expect(creds.subscriptionType == "max")
        #expect(ClaudeCredentials.parse(Data(#"{"mcpOAuth": {}}"#.utf8)) == nil)
    }

    @Test func keychainServiceNaming() {
        #expect(ClaudeKeychain.serviceName(configDirOverride: nil) == "Claude Code-credentials")
        #expect(ClaudeKeychain.serviceName(configDirOverride: "") == "Claude Code-credentials")
        // sha256("/Users/test/.claude-work")[:8], computed with shasum.
        #expect(ClaudeKeychain.serviceName(configDirOverride: "/Users/test/.claude-work") == "Claude Code-credentials-03abf0ee")
        // Hashed raw: a trailing slash names a different item.
        #expect(ClaudeKeychain.serviceName(configDirOverride: "/Users/test/.claude-work/") != "Claude Code-credentials-03abf0ee")
    }

    @Test func keychainAccountFallsBackForOddUsernames() {
        #expect(ClaudeKeychain.account(environment: ["USER": "jane.doe"]) == "jane.doe")
        #expect(ClaudeKeychain.account(environment: ["USER": "jane doe"]) == "claude-code-user")
    }

    @Test func globalConfigLocation() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let standard = Subscription(name: "a", harness: .claude)
        let custom = Subscription(name: "b", harness: .claude, homeOverride: "/Users/test/.claude-work")
        #expect(ClaudeUsageProvider.globalConfigURL(for: standard, homeDirectory: home).path(percentEncoded: false) == "/Users/test/.claude.json")
        #expect(ClaudeUsageProvider.globalConfigURL(for: custom, homeDirectory: home).path(percentEncoded: false) == "/Users/test/.claude-work/.claude.json")
    }
}

@Suite struct CodexParsingTests {
    // From the redacted schema in docs/spikes/02-codex-usage.md.
    static let result = """
    {"accountId": "x", "rateLimits": {"limitId": "codex", "planType": "team",
       "primary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1794925834},
       "secondary": {"usedPercent": 8, "windowDurationMins": 10080, "resetsAt": 1795159250}},
     "rateLimitsByLimitId": {
       "codex": {"limitId": "codex", "planType": "team",
         "primary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1794925834},
         "secondary": {"usedPercent": 8, "windowDurationMins": 10080, "resetsAt": 1795159250}},
       "codex_review": {"limitId": "codex_review", "limitName": "code review",
         "primary": {"usedPercent": 50, "windowDurationMins": 1440, "resetsAt": 1795000000}}}}
    """

    @Test func mapsEveryBucketByDuration() throws {
        let snapshot = CodexAppServerUsageProvider.snapshot(from: try json(Self.result), fetchedAt: .now)
        #expect(snapshot.planName == "team")
        #expect(snapshot.windows.map(\.id) == ["codex:primary", "codex:secondary", "codex_review:primary"])
        #expect(snapshot.windows.map(\.label) == ["5-hour session", "weekly", "1-day · code review"])
        #expect(snapshot.windows[1].duration == TimeInterval(10080 * 60))
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_794_925_834))
    }

    @Test func fallsBackToSingleRateLimits() throws {
        var result = try json(Self.result)
        result["rateLimitsByLimitId"] = nil
        #expect(CodexAppServerUsageProvider.snapshot(from: result, fetchedAt: .now).windows.count == 2)
    }

    @Test func errorMapping() {
        #expect(CodexAppServerUsageProvider.issue(for: JSONRPCError(code: -32600, message: "codex account authentication required to read rate limits"))
            == .signedOut(hint: Harness.codex.loginHint))
        #expect(CodexAppServerUsageProvider.issue(for: JSONRPCError(code: -32603, message: "failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)"))
            == .unavailable("Can't reach OpenAI"))
    }
}

@Suite struct GrokParsingTests {
    @Test func mapsWeeklyCreditWindow() throws {
        let result = try json("""
        {"config": {"creditUsagePercent": 2.0,
           "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-11-12T09:15:07.330+00:00", "end": "2026-11-19T09:15:07.330+00:00"},
           "prepaidBalance": {"val": 0}},
         "subscription_tier": "SuperGrok"}
        """)
        let snapshot = try #require(GrokACPUsageProvider.snapshot(from: result, fetchedAt: .now))
        #expect(snapshot.planName == "supergrok")
        let window = try #require(snapshot.windows.first)
        #expect(window.label == "weekly")
        #expect(window.usedPercent == 2)
        #expect(abs((window.duration ?? 0) - 7 * 86400) < 0.001)
    }

    @Test func rejectsUnexpectedShape() throws {
        #expect(GrokACPUsageProvider.snapshot(from: try json(#"{"something": 1}"#), fetchedAt: .now) == nil)
    }
}

@Suite struct ISO8601Tests {
    @Test(arguments: [
        ("2026-11-17T18:49:59+00:00", 1_794_941_399.0),
        ("2026-11-17T18:49:59Z", 1_794_941_399.0),
        ("2026-11-17T18:49:59.5Z", 1_794_941_399.5),
        ("2026-11-17T18:49:59.828031+00:00", 1_794_941_399.828),
        ("2026-11-17T20:49:59.828+02:00", 1_794_941_399.828),
    ])
    func parsesVariants(input: String, expected: Double) throws {
        let date = try #require(ISO8601.date(input))
        #expect(abs(date.timeIntervalSince1970 - expected) < 0.001)
    }

    @Test func rejectsGarbage() {
        #expect(ISO8601.date("soon") == nil)
        #expect(ISO8601.date(nil) == nil)
    }
}
