import Foundation

/// Claude Code subscription usage.
///
/// 1. **Passive:** `cachedUsageUtilization` in the dir's global `.claude.json`, kept fresh by the CLI.
/// 2. **Active:** OAuth token via `/usr/bin/security`, then `GET /api/oauth/usage`.
///
/// Never refreshes the token (requirements §5.1). See docs/spikes/01-claude-code-usage.md.
public struct ClaudeUsageProvider: UsageProvider {
    public let harness = Harness.claude
    let session: URLSession
    let credentialSource: any ClaudeCredentialSource
    let rejected = ClaudeRejectedCredentials()
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init(session: URLSession = .shared) {
        self.init(session: session, credentialSource: SystemClaudeCredentialSource())
    }

    init(session: URLSession, credentialSource: any ClaudeCredentialSource) {
        self.session = session
        self.credentialSource = credentialSource
    }

    public func fetch(_ subscription: Subscription, context: UsageFetchContext) async -> UsageReport {
        let home = context.environment.homeDirectory
        let configDir = subscription.homeURL(homeDirectory: home)
        let cache = ClaudeGlobalConfig.read(Self.globalConfigURL(for: subscription, homeDirectory: home))

        if let cached = cache.snapshot, context.now.timeIntervalSince(cached.fetchedAt) < context.acceptableCacheAge {
            return UsageReport(snapshot: cached)
        }

        // A token the API already rejected stays rejected until Claude Code rewrites it.
        let service = ClaudeKeychain.serviceName(configDirOverride: subscription.homeOverride)
        let environment = context.environment.baseEnvironment
        let credentialDate = credentialSource.modificationDate(
            configDirOverride: subscription.homeOverride, configDir: configDir, environment: environment
        )
        if rejected.isRejected(service, credentialDate: credentialDate) {
            return UsageReport(snapshot: cache.snapshot, issue: .tokenExpired(hint: Harness.claude.loginHint))
        }

        let credentials: ClaudeCredentials
        do {
            credentials = try await credentialSource.read(
                configDirOverride: subscription.homeOverride,
                configDir: configDir,
                environment: environment
            )
        } catch {
            let issue: UsageIssue = switch error {
            case .notFound: .signedOut(hint: Harness.claude.loginHint)
            case .keychainLocked: .unavailable("Keychain is locked")
            case .unreadable(let detail): .unavailable("Couldn't read Claude credentials (\(detail))")
            }
            return UsageReport(snapshot: cache.snapshot, issue: issue)
        }

        if let expiresAt = credentials.expiresAt, expiresAt <= context.now.addingTimeInterval(60) {
            rejected.reject(service, credentialDate: credentialDate)
            return UsageReport(snapshot: cache.snapshot, issue: .tokenExpired(hint: Harness.claude.loginHint))
        }

        let plan = ClaudeUsageParser.planName(
            displayName: cache.planDisplayName,
            subscriptionType: credentials.subscriptionType ?? cache.organizationType,
            rateLimitTier: credentials.rateLimitTier ?? cache.rateLimitTier
        )

        var request = URLRequest(url: Self.usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("HarnessButler/\(context.appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return UsageReport(snapshot: cache.snapshot, issue: .unavailable("Can't reach Anthropic"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            guard let usage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return UsageReport(snapshot: cache.snapshot, issue: .unsupported("Unexpected usage response from Anthropic"))
            }
            rejected.clear(service)
            return UsageReport(snapshot: UsageSnapshot(
                windows: ClaudeUsageParser.windows(from: usage),
                planName: plan ?? cache.snapshot?.planName,
                credits: ClaudeUsageParser.credits(from: usage),
                fetchedAt: context.now,
                source: .live
            ))
        case 401:
            rejected.reject(service, credentialDate: credentialDate)
            return UsageReport(snapshot: cache.snapshot, issue: .tokenExpired(hint: Harness.claude.loginHint))
        case 403, 429:
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            return UsageReport(snapshot: cache.snapshot, issue: .rateLimited(retryAfter: retryAfter))
        default:
            return UsageReport(snapshot: cache.snapshot, issue: .unavailable("Anthropic returned HTTP \(status)"))
        }
    }

    /// `$CLAUDE_CONFIG_DIR/.claude.json` when set, else `~/.claude.json` (not inside `~/.claude`).
    static func globalConfigURL(for subscription: Subscription, homeDirectory: URL) -> URL {
        if subscription.homeOverride?.isEmpty == false {
            return subscription.homeURL(homeDirectory: homeDirectory).appending(path: ".claude.json")
        }
        return homeDirectory.appending(path: ".claude.json")
    }
}

/// The few keys read from Claude's global `.claude.json`. The file also holds identity data
/// (email, org names); nothing else is kept.
struct ClaudeGlobalConfig {
    var snapshot: UsageSnapshot?
    var planDisplayName: String?
    var organizationType: String?
    var rateLimitTier: String?

    static func read(_ url: URL) -> ClaudeGlobalConfig {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ClaudeGlobalConfig() }
        return parse(root)
    }

    static func parse(_ root: [String: Any]) -> ClaudeGlobalConfig {
        let account = LenientJSON.object(root["oauthAccount"])
        var config = ClaudeGlobalConfig(
            planDisplayName: LenientJSON.string(account?["planDisplayName"]),
            organizationType: LenientJSON.string(account?["organizationType"]),
            rateLimitTier: LenientJSON.string(account?["userRateLimitTier"]) ?? LenientJSON.string(account?["organizationRateLimitTier"])
        )
        if let cached = LenientJSON.object(root["cachedUsageUtilization"]),
           let fetchedAtMs = LenientJSON.double(cached["fetchedAtMs"]),
           let usage = LenientJSON.object(cached["utilization"]) {
            config.snapshot = UsageSnapshot(
                windows: ClaudeUsageParser.windows(from: usage),
                planName: ClaudeUsageParser.planName(
                    displayName: config.planDisplayName,
                    subscriptionType: config.organizationType,
                    rateLimitTier: config.rateLimitTier
                ),
                credits: ClaudeUsageParser.credits(from: usage),
                fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000),
                source: .harnessCache
            )
        }
        return config
    }
}

extension ClaudeUsageProvider {
    /// When this subscription's Claude credential last changed (attributes only, never prompts).
    public func credentialModificationDate(for subscription: Subscription, environment: HarnessEnvironment) -> Date? {
        credentialSource.modificationDate(
            configDirOverride: subscription.homeOverride,
            configDir: subscription.homeURL(homeDirectory: environment.homeDirectory),
            environment: environment.baseEnvironment
        )
    }
}
