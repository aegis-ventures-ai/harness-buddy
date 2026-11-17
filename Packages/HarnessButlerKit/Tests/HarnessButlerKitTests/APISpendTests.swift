import Foundation
import Synchronization
import Testing
@testable import HarnessButlerKit

/// Answers requests from a closure and records them. Never touches the network.
final class FakeTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private let handler: @Sendable (URLRequest, Int) -> Reply
    private let log = Mutex<[URLRequest]>([])

    init(_ handler: @escaping @Sendable (URLRequest, Int) -> Reply) {
        self.handler = handler
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = log.withLock { $0.append(request); return $0.count - 1 }
        let reply = handler(request, index)
        if reply.status == -1 { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

private func date(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }

private func context(_ now: Date) -> UsageFetchContext {
    UsageFetchContext(
        environment: HarnessEnvironment(homeDirectory: URL(filePath: "/nonexistent"), searchPath: [], baseEnvironment: [:]),
        now: now, acceptableCacheAge: 0, appVersion: "test", scratchDirectory: URL(filePath: "/nonexistent")
    )
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

@Suite struct APISpendModelTests {
    let now = date("2026-11-16T12:00:00Z")   // 15.5 days into a 30-day month

    @Test func billingMonthIsTheUTCMonth() {
        let month = BillingMonth.containing(date("2026-11-30T23:59:59Z"))
        #expect(month.start == date("2026-11-01T00:00:00Z"))
        #expect(month.end == date("2026-12-01T00:00:00Z"))
        let december = BillingMonth.containing(date("2026-12-31T12:00:00Z"))
        #expect(december.end == date("2027-01-01T00:00:00Z"))
    }

    @Test func runRateAndProjection() {
        let spend = APISpend(days: [date("2026-11-01T00:00:00Z"): 100, date("2026-11-10T00:00:00Z"): 55], month: .containing(now))
        #expect(spend.monthToDate == 155)
        #expect(abs(spend.dailyRunRate(at: now) - 10) < 0.0001)
        #expect(abs(spend.projectedMonthEnd(at: now) - 300) < 0.0001)
    }

    @Test func runRateUsesDataThroughAndAtLeastOneDay() {
        let month = BillingMonth.containing(now)
        let lagging = APISpend(monthToDate: 140, daily: [], periodStart: month.start, periodEnd: month.end, dataThrough: date("2026-11-15T00:00:00Z"))
        #expect(abs(lagging.dailyRunRate(at: now) - 10) < 0.0001)
        let early = APISpend(monthToDate: 5, daily: [], periodStart: month.start, periodEnd: month.end)
        #expect(early.dailyRunRate(at: date("2026-11-01T02:00:00Z")) == 5)
        let ended = APISpend(monthToDate: 300, daily: [], periodStart: month.start, periodEnd: month.end)
        #expect(ended.projectedMonthEnd(at: date("2026-12-03T00:00:00Z")) == 300)
    }

    @Test func lastDaysAreZeroFilled() {
        let spend = APISpend(days: [date("2026-11-14T00:00:00Z"): 3, date("2026-11-16T00:00:00Z"): 4], month: .containing(now))
        let days = spend.lastDays(7, at: now)
        #expect(days.count == 7)
        #expect(days.first?.day == date("2026-11-10T00:00:00Z"))
        #expect(days.map(\.amount) == [0, 0, 0, 0, 3, 0, 4])
    }

    @Test func budgetWindowUsesTheAtRiskRule() {
        let month = BillingMonth.containing(now)
        // $160 of $300 after 15.5/30 days projects to ~$310: at risk (U-8).
        let spend = APISpend(monthToDate: 160, daily: [], periodStart: month.start, periodEnd: month.end)
        let snapshot = UsageSnapshot(windows: [], planName: nil, fetchedAt: now, source: .live, spend: spend).applyingBudget(300)
        let window = try! #require(snapshot.windows.first)
        #expect(window.id == APISpend.budgetWindowID)
        #expect(abs(window.usedPercent - 53.333) < 0.01)
        #expect(window.resetsAt == month.end)
        #expect(UsageRules.status(of: snapshot, at: now) == .atRisk)
        // A bigger budget is on track; no budget means no window; over budget is limited.
        #expect(UsageRules.status(of: snapshot.applyingBudget(1000), at: now) == .onTrack)
        #expect(snapshot.applyingBudget(nil).windows.isEmpty)
        #expect(UsageRules.status(of: snapshot.applyingBudget(150), at: now) == .limited)
        #expect(snapshot.applyingBudget(0).windows.isEmpty)
        // A tiny budget is far over, but bounded: percent and pace stay finite and displayable.
        let tiny = try! #require(snapshot.applyingBudget(1e-20).windows.first)
        #expect(tiny.usedPercent == UsageWindow.maxUsedPercent)
        let pace = try! #require(UsageRules.pace(of: tiny, at: now))
        #expect(pace.deltaPercent.isFinite && pace.projectedUsedPercent <= UsageWindow.maxUsedPercent)
        #expect(UsageWindow(id: "x", label: "x", usedPercent: .nan, resetsAt: nil, duration: nil).usedPercent == 0)
        #expect(UsageWindow(id: "x", label: "x", usedPercent: -40, resetsAt: nil, duration: nil).usedPercent == 0)
        #expect(Double.infinity.displayInt == 1_000_000_000_000_000 && Double.nan.displayInt == 0 && (-1e300).displayInt == -1_000_000_000_000_000)
    }

    @Test func cachedWindowsAreBoundedToo() throws {
        let json = #"{"id":"x","label":"x","usedPercent":1e300}"#
        #expect(try JSONDecoder().decode(UsageWindow.self, from: Data(json.utf8)).usedPercent == UsageWindow.maxUsedPercent)
    }

    @Test func oldSubscriptionJSONStillDecodes() throws {
        let json = #"[{"id":"6F1C1F0C-1D0B-4C7B-9E3E-0D6C5B1D2A11","name":"Work","harness":"claude","isPinned":true}]"#
        let decoded = try JSONDecoder().decode([Subscription].self, from: Data(json.utf8))
        #expect(decoded.first?.api == nil)
        #expect(decoded.first?.isHarnessLogin == true)
        let api = Subscription.api(APIAccount(provider: .openai, monthlyBudget: 50), name: "Org")
        let roundTrip = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(api))
        #expect(roundTrip == api)
        #expect(roundTrip.harness == .codex)
        #expect(roundTrip.cadence == .apiSpend)
        #expect(roundTrip.providerKey == .api(.openai))
    }

    @Test func apiSubscriptionsHaveNoConfigProfile() {
        let subscriptions = [
            Subscription(name: "Claude", harness: .claude),
            Subscription.api(APIAccount(provider: .anthropic), name: "Org"),
        ]
        let profiles = ConfigProfile.profiles(for: subscriptions, homeDirectory: URL(filePath: "/Users/u"))
        #expect(profiles.count == 1)
        #expect(profiles.first?.subscriptionNames == ["Claude"])
    }

    @Test func keyFormatCheck() {
        #expect(APIProvider.anthropic.keyProblem("sk-ant-admin01-abc") == nil)
        #expect(APIProvider.anthropic.keyProblem("sk-ant-api03-abc") != nil)
        #expect(APIProvider.openai.keyProblem("  sk-admin-abc \n") == nil)
        #expect(APIProvider.openai.keyProblem("sk-proj-abc") != nil)
        #expect(APIProvider.openai.keyProblem("") != nil)
        #expect(APIProvider.openai.keyProblem("sk-admin- x") != nil)
    }
}

@Suite struct AnthropicAdminProviderTests {
    let subscription = Subscription.api(APIAccount(provider: .anthropic, monthlyBudget: 1000), name: "Org")
    let now = date("2026-11-16T12:34:56Z")

    func provider(_ transport: FakeTransport, key: String? = "sk-ant-admin01-secret") -> AnthropicAdminUsageProvider {
        AnthropicAdminUsageProvider(secrets: InMemorySecretStore(key.map { [subscription.id.uuidString: $0] } ?? [:]), transport: transport)
    }

    static let page1 = """
    {"data":[
      {"starting_at":"2026-11-01T10:00:00Z","ending_at":"2026-11-01T11:00:00Z","group":{},"cost":{"currency":"USD","amount":"1250.500000","list_amount":"1300.000000","requests":3}},
      {"starting_at":"2026-11-01T11:00:00Z","ending_at":"2026-11-01T12:00:00Z","group":{},"cost":{"currency":"USD","amount":"49.500000"}}
    ],"has_more":true,"next_page":"cursor-2","data_refreshed_at":"2026-11-16T08:00:00Z"}
    """
    static let page2 = """
    {"data":[{"starting_at":"2026-11-16T07:00:00Z","ending_at":"2026-11-16T08:00:00Z","group":{},"cost":{"currency":"USD","amount":"700"}}],
     "has_more":false,"next_page":null,"data_refreshed_at":"2026-11-16T08:00:00Z"}
    """

    @Test func readsAndSumsHourlyBucketsAcrossPages() async throws {
        let transport = FakeTransport { request, _ in
            .init(status: 200, body: query(request)["page"] == "cursor-2" ? Self.page2 : Self.page1)
        }
        let report = await provider(transport).fetch(subscription, context: context(now))
        #expect(report.issue == nil)
        let spend = try #require(report.snapshot?.spend)
        #expect(spend.monthToDate == 20)   // (1250.5 + 49.5 + 700) cents
        #expect(spend.daily == [DailySpend(day: date("2026-11-01T00:00:00Z"), amount: 13), DailySpend(day: date("2026-11-16T00:00:00Z"), amount: 7)])
        #expect(spend.dataThrough == date("2026-11-16T08:00:00Z"))
        #expect(report.snapshot?.windows.map(\.id) == [APISpend.budgetWindowID])
        #expect(report.snapshot?.windows.first?.usedPercent == 2)

        let first = try #require(transport.requests.first)
        #expect(first.url?.path() == "/v1/organizations/analytics/cost")
        #expect(first.value(forHTTPHeaderField: "x-api-key") == "sk-ant-admin01-secret")
        #expect(first.value(forHTTPHeaderField: "anthropic-version") == AnthropicAdminUsageProvider.apiVersion)
        #expect(first.value(forHTTPHeaderField: "anthropic-beta") == AnthropicAdminUsageProvider.beta)
        #expect(first.value(forHTTPHeaderField: "Authorization") == nil)
        let params = query(first)
        #expect(params["starting_at"] == "2026-11-01T00:00:00Z")
        #expect(params["ending_at"] == "2026-11-16T12:00:00Z")
        #expect(params["time_bucket_width"] == "1h")
        #expect(params["limit"] == "1000")
        #expect(transport.requests.count == 2)
    }

    @Test func emptyMonthStartMakesNoRequest() async {
        let transport = FakeTransport { _, _ in .init(status: 500, body: "") }
        let report = await provider(transport).fetch(subscription, context: context(date("2026-11-01T00:40:00Z")))
        #expect(transport.requests.isEmpty)
        #expect(report.snapshot?.spend?.monthToDate == 0)
        #expect(report.issue == nil)
    }

    @Test func nullRefreshAndEmptyDataIsZeroSpend() async {
        let transport = FakeTransport { _, _ in .init(status: 200, body: #"{"data":[],"has_more":false,"next_page":null,"data_refreshed_at":null}"#) }
        let report = await provider(transport).fetch(subscription, context: context(now))
        #expect(report.snapshot?.spend?.monthToDate == 0)
        #expect(report.snapshot?.spend?.dataThrough == nil)
    }

    @Test func malformedOrIncompletePagesFailWhole() async {
        func report(_ bodies: [String]) async -> UsageReport {
            let transport = FakeTransport { _, index in .init(status: 200, body: bodies[min(index, bodies.count - 1)]) }
            return await provider(transport).fetch(subscription, context: context(now))
        }
        let bad = UsageIssue.unsupported("Unexpected cost response from Anthropic")
        // A row with a cost that doesn't parse would understate spend.
        let badRow = #"{"data":[{"starting_at":"2026-11-01T10:00:00Z","cost":{"amount":"lots"}}],"has_more":false}"#
        #expect(await report([badRow]).issue == bad)
        #expect(await report([badRow]).snapshot == nil)
        #expect(await report([#"{"data":[{"cost":{"amount":"1"}}],"has_more":false}"#]).issue == bad)
        // More pages promised but no cursor.
        #expect(await report([#"{"data":[],"has_more":true,"next_page":null}"#]).issue == bad)
        // An hour without a cost is zero, not an error.
        let noCost = #"{"data":[{"starting_at":"2026-11-01T10:00:00Z","cost":null}],"has_more":false}"#
        #expect(await report([noCost]).snapshot?.spend?.monthToDate == 0)
        // Endless pages stop at the cap with an error, not a partial total.
        let endless = #"{"data":[{"starting_at":"2026-11-01T10:00:00Z","cost":{"amount":"100"}}],"has_more":true,"next_page":"again"}"#
        let capped = await report([endless])
        #expect(capped.issue == .unsupported("Anthropic returned more cost pages than expected"))
        #expect(capped.snapshot == nil)
    }

    @Test func retryAfterAcceptsAnHTTPDate() {
        let now = date("2026-11-16T12:00:00Z")
        #expect(RetryAfter.parse("Mon, 16 Nov 2026 12:02:00 GMT", now: now) == 120)
        #expect(RetryAfter.parse("90", now: now) == 90)
        #expect(RetryAfter.parse("Mon, 16 Nov 2026 11:00:00 GMT", now: now) == 0)
        #expect(RetryAfter.parse("soon", now: now) == nil)
        #expect(RetryAfter.parse(nil, now: now) == nil)
        // Only digits are delay seconds, and a provider can't silence us for more than a day.
        #expect(RetryAfter.parse("inf", now: now) == nil)
        #expect(RetryAfter.parse("1e300", now: now) == nil)
        #expect(RetryAfter.parse("-5", now: now) == nil)
        #expect(RetryAfter.parse("31536000", now: now) == RetryAfter.maximum)
        #expect(RetryAfter.parse("999999999999999999999999", now: now) == RetryAfter.maximum)
        #expect(RetryAfter.parse("Fri, 16 Nov 2029 12:00:00 GMT", now: now) == RetryAfter.maximum)
        #expect(AnthropicAdminUsageProvider.number("1e400") == nil && AnthropicAdminUsageProvider.number(Double.nan) == nil)
    }

    @Test func expiredCursorRestartsOnce() async {
        let transport = FakeTransport { request, index in
            if index == 1 { return .init(status: 410, body: "{}") }
            return .init(status: 200, body: query(request)["page"] == "cursor-2" ? Self.page2 : Self.page1)
        }
        let report = await provider(transport).fetch(subscription, context: context(now))
        #expect(report.snapshot?.spend?.monthToDate == 20)   // not double-counted
        #expect(transport.requests.count == 4)
    }

    @Test func errorsMapToRowStates() async {
        func issue(_ status: Int, headers: [String: String] = [:]) async -> UsageIssue? {
            let transport = FakeTransport { _, _ in .init(status: status, body: #"{"error":{"message":"nope"}}"#, headers: headers) }
            return await provider(transport).fetch(subscription, context: context(now)).issue
        }
        #expect(await issue(401)?.message.contains("rejected the Admin key") == true)
        #expect(await issue(403)?.message.contains("Use an Admin key") == true)
        #expect(await issue(429, headers: ["retry-after": "90"]) == .rateLimited(retryAfter: 90))
        #expect(await issue(500) == .unavailable("Anthropic returned HTTP 500"))
        #expect(await issue(-1) == .unavailable("Can't reach Anthropic"))
        // A 200 without a `data` array isn't an empty month: keep the last good total.
        #expect(await issue(200) == .unsupported("Unexpected cost response from Anthropic"))
    }

    @Test func missingKeyIsSignedOutWithoutARequest() async {
        let transport = FakeTransport { _, _ in .init(status: 200, body: "{}") }
        let report = await provider(transport, key: nil).fetch(subscription, context: context(now))
        #expect(transport.requests.isEmpty)
        if case .signedOut = report.issue {} else { Issue.record("expected signedOut, got \(String(describing: report.issue))") }
    }

    @Test func issueMessagesNeverContainTheKey() async {
        for status in [401, 403, 429, 500, 200] {
            let transport = FakeTransport { _, _ in .init(status: status, body: "sk-ant-admin01-secret") }
            let report = await provider(transport).fetch(subscription, context: context(now))
            #expect(report.issue?.message.contains("secret") != true)
        }
    }
}

@Suite struct OpenAIAdminProviderTests {
    let subscription = Subscription.api(APIAccount(provider: .openai), name: "Org")
    let now = date("2026-11-03T06:00:00Z")

    static let page1 = """
    {"object":"page","data":[
      {"object":"bucket","start_time":1793491200,"end_time":1793577600,"results":[
        {"object":"organization.costs.result","amount":{"value":1.25,"currency":"usd"},"line_item":null,"project_id":null},
        {"object":"organization.costs.result","amount":{"value":"0.75","currency":"usd"}}]},
      {"object":"bucket","start_time":1793577600,"end_time":1793664000,"results":[]}
    ],"has_more":true,"next_page":"page_2"}
    """
    static let page2 = """
    {"object":"page","data":[{"object":"bucket","start_time":1793664000,"end_time":1793750400,"results":[{"amount":{"value":3,"currency":"usd"}}]}],"has_more":false,"next_page":null}
    """

    @Test func readsDailyBucketsAcrossPages() async throws {
        let transport = FakeTransport { request, _ in
            .init(status: 200, body: query(request)["page"] == "page_2" ? Self.page2 : Self.page1)
        }
        let secrets = InMemorySecretStore([subscription.id.uuidString: "sk-admin-secret"])
        let report = await OpenAIAdminUsageProvider(secrets: secrets, transport: transport).fetch(subscription, context: context(now))
        let spend = try #require(report.snapshot?.spend)
        #expect(spend.monthToDate == 5)
        #expect(spend.currency == "USD")
        #expect(spend.daily.map(\.day) == [date("2026-11-01T00:00:00Z"), date("2026-11-03T00:00:00Z")])
        #expect(report.snapshot?.windows.isEmpty == true)   // no budget

        let first = try #require(transport.requests.first)
        #expect(first.url?.host() == "api.openai.com")
        #expect(first.url?.path() == "/v1/organization/costs")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer sk-admin-secret")
        let params = query(first)
        #expect(params["start_time"] == "1793491200")
        #expect(params["end_time"] == String(Int(now.timeIntervalSince1970)))
        #expect(params["bucket_width"] == "1d")
        #expect(query(transport.requests[1])["page"] == "page_2")
    }

    @Test func malformedBucketsFailWhole() async {
        func issue(_ body: String) async -> UsageIssue? {
            let transport = FakeTransport { _, _ in .init(status: 200, body: body) }
            let secrets = InMemorySecretStore([subscription.id.uuidString: "sk-admin-secret"])
            return await OpenAIAdminUsageProvider(secrets: secrets, transport: transport).fetch(subscription, context: context(now)).issue
        }
        let bad = UsageIssue.unsupported("Unexpected costs response from OpenAI")
        #expect(await issue("{}") == bad)
        #expect(await issue(#"{"data":[{"start_time":1793491200,"results":[{"amount":{"value":"n/a"}}]}],"has_more":false}"#) == bad)
        #expect(await issue(#"{"data":[{"results":[]}],"has_more":false}"#) == bad)
        #expect(await issue(#"{"data":[],"has_more":true}"#) == bad)
        #expect(await issue(#"{"data":[{"start_time":1793491200,"results":null}],"has_more":false}"#) == bad)
        #expect(await issue(#"{"data":[{"start_time":1793491200}],"has_more":false}"#) == bad)
        #expect(await issue(#"{"data":[{"start_time":1793491200,"results":[]}]}"#) == bad)            // no has_more
        #expect(await issue(#"{"data":[{"start_time":1793491200,"results":[]}],"has_more":"no"}"#) == bad)
        #expect(await issue(#"{"data":[{"start_time":1793491200,"results":[]}],"has_more":0}"#) == bad)
        #expect(await issue(#"{"data":[{"start_time":1793491200,"results":[]}],"has_more":false}"#) == nil)
    }
}

@MainActor
@Suite struct APISubscriptionStoreTests {
    func makeStore() -> (UsageStore, InMemorySecretStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-api-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let store = UsageStore(
            file: SubscriptionFile(url: dir.appending(path: "subscriptions.json")),
            cacheFile: UsageCacheFile(url: dir.appending(path: "cache.json")),
            providers: [], secrets: secrets, appVersion: "test", homeDirectory: dir
        )
        return (store, secrets, dir)
    }

    @Test func addingStoresTheKeyOnlyInTheSecretStore() throws {
        let (store, secrets, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.addAPI(name: "Org", provider: .anthropic, key: "sk-ant-api03-nope", monthlyBudget: nil) != nil)
        #expect(store.subscriptions.isEmpty && secrets.count == 0)

        #expect(store.addAPI(name: "Org", provider: .anthropic, key: " sk-ant-admin01-secret ", monthlyBudget: 250) == nil)
        let subscription = try #require(store.subscriptions.first)
        #expect(subscription.api == APIAccount(provider: .anthropic, monthlyBudget: 250))
        #expect(try secrets.read(account: subscription.id.uuidString) == "sk-ant-admin01-secret")
        let saved = try String(contentsOf: dir.appending(path: "subscriptions.json"), encoding: .utf8)
        #expect(!saved.contains("secret"))
        #expect(saved.contains("monthlyBudget"))

        #expect(store.addAPI(name: "Org", provider: .openai, key: "sk-admin-x", monthlyBudget: nil) != nil)   // duplicate name

        store.remove(subscription.id)
        #expect(secrets.count == 0)
    }

    @Test func budgetEditsUpdateTheWindowWithoutRefetch() throws {
        let (store, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.addAPI(name: "Org", provider: .openai, key: "sk-admin-x", monthlyBudget: nil)
        let id = try #require(store.subscriptions.first?.id)
        let month = BillingMonth.containing(.now)
        let spend = APISpend(monthToDate: 40, daily: [], periodStart: month.start, periodEnd: month.end)
        var seen: [UsageSnapshot] = []
        store.onSnapshot = { _, snapshot in seen.append(snapshot) }
        store.apply(UsageReport(snapshot: UsageSnapshot(windows: [], planName: nil, fetchedAt: .now, source: .live, spend: spend)), to: id)
        #expect(store.usage(for: id).snapshot?.windows.isEmpty == true)
        #expect(seen.count == 1)

        store.setBudget(id, 80)
        #expect(store.usage(for: id).snapshot?.windows.first?.usedPercent == 50)
        #expect(store.subscriptions.first?.api?.monthlyBudget == 80)
        store.setBudget(id, -5)
        #expect(store.subscriptions.first?.api?.monthlyBudget == nil)
        store.setBudget(id, 1e-20)
        #expect(store.subscriptions.first?.api?.monthlyBudget == nil)
        store.setBudget(id, 1e20)
        #expect(store.subscriptions.first?.api?.monthlyBudget == nil)
        #expect(store.usage(for: id).snapshot?.windows.isEmpty == true)
    }

    @Test func replacingAKeyValidatesIt() throws {
        let (store, secrets, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.addAPI(name: "Org", provider: .openai, key: "sk-admin-old", monthlyBudget: nil)
        let id = try #require(store.subscriptions.first?.id)
        #expect(store.replaceKey(id, with: "bad") != nil)
        #expect(try secrets.read(account: id.uuidString) == "sk-admin-old")
        #expect(store.replaceKey(id, with: "sk-admin-new") == nil)
        #expect(try secrets.read(account: id.uuidString) == "sk-admin-new")
    }
}
