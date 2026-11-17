import Foundation
import Synchronization
import Testing
@testable import HarnessButlerKit

// MARK: - Codex rollout fallback

@Suite struct CodexRolloutTests {
    static func tokenCountLine(timestamp: String, used: Double) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":\#(used),"window_minutes":300,"resets_at":1794855133},"secondary":{"used_percent":6.0,"window_minutes":10080,"resets_at":1795159250},"plan_type":"team"}}}"#
    }

    @Test func parsesSnakeCaseRateLimits() throws {
        let line = Data(Self.tokenCountLine(timestamp: "2026-11-16T13:58:00.123Z", used: 8).utf8)
        let snapshot = try #require(CodexRolloutReader.snapshot(fromLine: line))
        #expect(snapshot.source == .harnessCache)
        #expect(snapshot.planName == "team")
        #expect(snapshot.windows.map(\.label) == ["5-hour session", "weekly"])
        #expect(snapshot.windows.map(\.usedPercent) == [8, 6])
        #expect(abs(snapshot.fetchedAt.timeIntervalSince1970 - 1_794_837_480.123) < 0.001)
    }

    @Test func picksTheLastEventInTheNewestFile() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ relative: String, _ lines: [String], modified: Date) throws {
            let url = home.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        }
        try write("sessions/2026/11/15/rollout-a.jsonl", [Self.tokenCountLine(timestamp: "2026-11-15T10:00:00Z", used: 50)], modified: .now.addingTimeInterval(-86400))
        try write("sessions/2026/11/16/rollout-b.jsonl", [
            Self.tokenCountLine(timestamp: "2026-11-16T10:00:00Z", used: 20),
            Self.tokenCountLine(timestamp: "2026-11-16T11:00:00Z", used: 30),
            #"{"timestamp":"2026-11-16T11:01:00Z","type":"response_item","payload":{"type":"message","content":"mentions \"rate_limits\" in text"}}"#,
        ], modified: .now)

        let snapshot = try #require(CodexRolloutReader.latestSnapshot(codexHome: home))
        #expect(snapshot.windows.first?.usedPercent == 30)
    }

    @Test func noSessionsMeansNoSnapshot() {
        #expect(CodexRolloutReader.latestSnapshot(codexHome: URL(filePath: "/nonexistent")) == nil)
    }
}

// MARK: - Claude rejected-credential gating

final class FakeCredentials: ClaudeCredentialSource {
    let state = Mutex((date: Date?(Date(timeIntervalSince1970: 1)), expiresAt: Date.distantFuture, reads: 0, token: "token"))

    func modificationDate(configDirOverride: String?, configDir: URL, environment: [String: String]) -> Date? {
        state.withLock { $0.date }
    }

    func read(configDirOverride: String?, configDir: URL, environment: [String: String]) async throws(ClaudeCredentialError) -> ClaudeCredentials {
        let (expiresAt, token) = state.withLock { state in
            state.reads += 1
            return (state.expiresAt, state.token)
        }
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt, subscriptionType: "max", rateLimitTier: nil)
    }

    var reads: Int { state.withLock { $0.reads } }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["retry-after": "120"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"limits":[{"kind":"session","group":"session","percent":12,"resets_at":"2026-11-17T18:49:59Z"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct ClaudeGatingTests {
    let fake = FakeCredentials()
    let provider: ClaudeUsageProvider
    let home: URL
    let subscription = Subscription(name: "c", harness: .claude, homeOverride: "/nonexistent/.claude-test")

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        provider = ClaudeUsageProvider(session: URLSession(configuration: config), credentialSource: fake)
        home = URL(filePath: "/nonexistent-home", directoryHint: .isDirectory)
        StubURLProtocol.requests = 0
        StubURLProtocol.status = 200
    }

    func context() -> UsageFetchContext {
        UsageFetchContext(
            environment: HarnessEnvironment(homeDirectory: home, searchPath: [], baseEnvironment: ["USER": "test"]),
            now: .now, acceptableCacheAge: 300, appVersion: "test", scratchDirectory: home
        )
    }

    @Test func liveReadSucceeds() async {
        let report = await provider.fetch(subscription, context: context())
        #expect(report.issue == nil)
        #expect(report.snapshot?.windows.first?.usedPercent == 12)
        #expect(report.snapshot?.planName == "max")
    }

    @Test func rejectedTokenIsNotRetriedUntilTheCredentialChanges() async {
        StubURLProtocol.status = 401
        let first = await provider.fetch(subscription, context: context())
        #expect(first.issue == .tokenExpired(hint: Harness.claude.loginHint))
        #expect(fake.reads == 1 && StubURLProtocol.requests == 1)

        // Same credential version: no Keychain read, no request.
        StubURLProtocol.status = 200
        let second = await provider.fetch(subscription, context: context())
        #expect(second.issue == .tokenExpired(hint: Harness.claude.loginHint))
        #expect(fake.reads == 1 && StubURLProtocol.requests == 1)

        // Claude Code refreshed the token: try again.
        fake.state.withLock { $0.date = Date(timeIntervalSince1970: 2) }
        let third = await provider.fetch(subscription, context: context())
        #expect(third.issue == nil)
        #expect(fake.reads == 2 && StubURLProtocol.requests == 2)
    }

    @Test func expiredTokenIsGatedTheSameWay() async {
        fake.state.withLock { $0.expiresAt = .now.addingTimeInterval(-10) }
        _ = await provider.fetch(subscription, context: context())
        _ = await provider.fetch(subscription, context: context())
        #expect(fake.reads == 1)
        #expect(StubURLProtocol.requests == 0)
    }

    @Test func unknownCredentialVersionGatesOnTheToken() async {
        fake.state.withLock { $0.date = nil }
        StubURLProtocol.status = 401
        _ = await provider.fetch(subscription, context: context())
        let second = await provider.fetch(subscription, context: context())
        #expect(second.issue == .tokenExpired(hint: Harness.claude.loginHint))
        #expect(StubURLProtocol.requests == 1)
        // A new token is a new credential version: try again.
        fake.state.withLock { $0.token = "new-token" }
        StubURLProtocol.status = 200
        let third = await provider.fetch(subscription, context: context())
        #expect(third.issue == nil)
        #expect(StubURLProtocol.requests == 2)
    }

    @Test func rateLimitHonoursRetryAfter() async {
        StubURLProtocol.status = 429
        let report = await provider.fetch(subscription, context: context())
        #expect(report.issue == .rateLimited(retryAfter: 120))
    }
}

// MARK: - Grouping, back-off and snapshot cache

@Suite struct StoreRulesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func usage(age: TimeInterval, used: Double = 10, issue: UsageIssue? = nil) -> SubscriptionUsage {
        let window = UsageWindow(id: "w", label: "w", usedPercent: used, resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400)
        return SubscriptionUsage(snapshot: UsageSnapshot(windows: [window], planName: nil, fetchedAt: now.addingTimeInterval(-age), source: .live), issue: issue)
    }

    @Test func grouping() {
        #expect(SubscriptionGroup.classify(SubscriptionUsage(), harness: .codex, at: now) == .onTrack)
        #expect(SubscriptionGroup.classify(SubscriptionUsage(issue: .harnessMissing(.codex)), harness: .codex, at: now) == .stale)
        #expect(SubscriptionGroup.classify(usage(age: 60), harness: .codex, at: now) == .onTrack)
        #expect(SubscriptionGroup.classify(usage(age: 60, used: 90), harness: .codex, at: now) == .atRisk)
        #expect(SubscriptionGroup.classify(usage(age: 60, used: 100), harness: .codex, at: now) == .limited)
        #expect(SubscriptionGroup.classify(usage(age: 60, issue: .unavailable("x")), harness: .codex, at: now) == .stale)
        // Old data with no error is stale too: 30 min for Codex, 36 min for Grok.
        #expect(SubscriptionGroup.classify(usage(age: 31 * 60), harness: .codex, at: now) == .stale)
        #expect(SubscriptionGroup.classify(usage(age: 31 * 60), harness: .grok, at: now) == .onTrack)
    }

    @Test func expiredTokenDoesNotBackOff() {
        var state = RefreshState()
        RefreshPolicy.record(.failure(.tokenExpired(hint: "x")), into: &state, at: now)
        #expect(state.consecutiveFailures == 0)
        RefreshPolicy.record(.failure(.unavailable("x")), into: &state, at: now)
        #expect(state.consecutiveFailures == 1)
    }

    @Test func snapshotCacheRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hb-cache-\(UUID().uuidString)/usage-cache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = UsageCacheFile(url: url)
        #expect(cache.load().isEmpty)
        let id = UUID()
        let snapshot = try #require(usage(age: 0).snapshot)
        try cache.save([id: snapshot])
        #expect(cache.load() == [id: snapshot])
    }
}
