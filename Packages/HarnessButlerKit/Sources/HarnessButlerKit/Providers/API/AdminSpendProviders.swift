import Foundation

/// The one network call the API providers make, so tests can answer without a server.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

extension URLSession {
    /// No disk cache, no cookies, no credential storage: tokens, keys and responses stay in memory.
    /// Used for every network call: provider usage and spend, and harness version checks (which then
    /// also never see a stale cached "latest").
    public static let providerAPI: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
}

/// What one provider-specific read produces before it becomes a snapshot.
struct SpendPage: Sendable {
    var days: [Date: Double] = [:]
    var currency = "USD"
    var dataThrough: Date?
}

/// Shared flow for Admin-key spend providers (U-3, U-7): key from the Keychain, month-to-date read,
/// budget window. The key is only ever put in a request header; it is never logged or stored elsewhere.
protocol AdminSpendProvider: UsageProvider {
    var api: APIProvider { get }
    var secrets: any SecretStore { get }
    func readMonth(_ month: BillingMonth, key: String, context: UsageFetchContext) async -> Result<SpendPage, UsageIssue>
}

extension AdminSpendProvider {
    func fetchSpend(_ subscription: Subscription, context: UsageFetchContext) async -> UsageReport {
        let adminKey: String?
        do {
            adminKey = try secrets.read(account: subscription.id.uuidString)
        } catch {
            return .failure(.unavailable(error == .locked ? "Keychain is locked" : "Couldn't read the Admin key from the Keychain"))
        }
        guard let adminKey, !adminKey.isEmpty else {
            return .failure(.signedOut(hint: "Add the Admin key in Settings → Subscriptions"))
        }
        let month = BillingMonth.containing(context.now)
        switch await readMonth(month, key: adminKey, context: context) {
        case .failure(let issue):
            return .failure(issue)
        case .success(let page):
            let spend = APISpend(currency: page.currency, days: page.days, month: month, dataThrough: page.dataThrough)
            let snapshot = UsageSnapshot(windows: [], planName: "Admin API", fetchedAt: context.now, source: .live, spend: spend)
            return UsageReport(snapshot: snapshot.applyingBudget(subscription.api?.monthlyBudget))
        }
    }

    /// Maps a non-200 status to a row state. Response bodies and headers other than `retry-after` are ignored.
    static func issue(status: Int, response: HTTPURLResponse, provider: String) -> UsageIssue {
        switch status {
        case 401:
            return .unavailable("\(provider) rejected the Admin key. Replace it in Settings → Subscriptions")
        case 403:
            return .unavailable("This key can't read \(provider) organization costs. Use an Admin key")
        case 429:
            return .rateLimited(retryAfter: RetryAfter.parse(response.value(forHTTPHeaderField: "retry-after")))
        default:
            return .unavailable("\(provider) returned HTTP \(status)")
        }
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        let number = (value as? String).map { Double($0) } ?? LenientJSON.double(value)
        return number.flatMap { $0.isFinite && abs($0) < 1e15 ? $0 : nil }
    }

    /// The cursor for the next page. `has_more` without a cursor is malformed: stopping there would undercount.
    /// `has_more` must be there and be a boolean: without it we can't tell a complete month from a cut-off one.
    static func nextPage(_ root: [String: Any]) throws(MalformedSpend) -> String? {
        guard let hasMore = root["has_more"] as? NSNumber, CFGetTypeID(hasMore) == CFBooleanGetTypeID() else { throw MalformedSpend() }
        guard hasMore.boolValue else { return nil }
        guard let next = LenientJSON.string(root["next_page"]), !next.isEmpty else { throw MalformedSpend() }
        return next
    }
}

/// A cost page without the expected shape.
struct MalformedSpend: Error {}

/// Never follow more pages than this; a month of hourly rows fits in one.
private let maxPages = 20

// MARK: - Anthropic

/// `GET /v1/organizations/analytics/cost` (Usage and Cost Analytics API, beta), hourly buckets from the
/// start of the UTC month to the last whole hour, summed per UTC day. Amounts are decimal strings in cents.
public struct AnthropicAdminUsageProvider: AdminSpendProvider {
    public let api = APIProvider.anthropic
    public var harness: Harness { api.brandHarness }
    public var key: UsageProviderKey { .api(api) }
    public func fetch(_ subscription: Subscription, context: UsageFetchContext) async -> UsageReport {
        await fetchSpend(subscription, context: context)
    }
    let secrets: any SecretStore
    let transport: any HTTPTransport
    static let costURL = URL(string: "https://api.anthropic.com/v1/organizations/analytics/cost")!
    static let apiVersion = "2026-10-21"
    static let beta = "analytics-usage-cost-2026-08-24"

    public init(secrets: any SecretStore = KeychainSecretStore(), transport: any HTTPTransport = URLSession.providerAPI) {
        self.secrets = secrets
        self.transport = transport
    }

    static func request(month: BillingMonth, now: Date, key: String, page: String?, appVersion: String) -> URLRequest? {
        let start = month.start
        // `ending_at` is rounded down to the hour anyway; an empty range is not a valid request.
        let end = Date(timeIntervalSince1970: (min(now, month.end).timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        guard end > start else { return nil }
        var components = URLComponents(url: costURL, resolvingAgainstBaseURL: false)!
        let format = Date.ISO8601FormatStyle()
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: start.formatted(format)),
            URLQueryItem(name: "ending_at", value: end.formatted(format)),
            URLQueryItem(name: "time_bucket_width", value: "1h"),
            URLQueryItem(name: "order_by", value: "time"),
            URLQueryItem(name: "order", value: "asc"),
            URLQueryItem(name: "limit", value: "1000"),
        ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("HarnessButler/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Adds one page's rows into `page`; returns the next-page cursor, if any. A page that doesn't
    /// have the expected shape fails as a whole: a partial sum would understate spend.
    static func parse(_ root: [String: Any], into page: inout SpendPage) throws(MalformedSpend) -> String? {
        if let refreshed = ISO8601.date(LenientJSON.string(root["data_refreshed_at"])) { page.dataThrough = refreshed }
        guard let rows = root["data"] as? [Any] else { throw MalformedSpend() }
        for row in rows {
            guard let row = row as? [String: Any], let start = ISO8601.date(LenientJSON.string(row["starting_at"])) else { throw MalformedSpend() }
            // An hour without spend may come without a cost; one that has a cost must parse.
            guard let costValue = row["cost"], !(costValue is NSNull) else { continue }
            guard let cost = costValue as? [String: Any], let cents = number(cost["amount"]) else { throw MalformedSpend() }
            if let currency = LenientJSON.string(cost["currency"]) { page.currency = currency.uppercased() }
            page.days[BillingMonth.utcDay(containing: start), default: 0] += cents / 100
        }
        return try nextPage(root)
    }

    func readMonth(_ month: BillingMonth, key: String, context: UsageFetchContext) async -> Result<SpendPage, UsageIssue> {
        var result = SpendPage()
        var cursor: String?
        var restarted = false
        var pages = 0
        while true {
            guard let request = Self.request(month: month, now: context.now, key: key, page: cursor, appVersion: context.appVersion) else {
                return .success(result)   // first hour of the month: nothing billed yet
            }
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch {
                return .failure(.unavailable("Can't reach Anthropic"))
            }
            if response.statusCode == 410, !restarted {
                // The page cursor expired: start over from the first page.
                restarted = true
                result = SpendPage()
                cursor = nil
                continue
            }
            guard response.statusCode == 200 else {
                return .failure(Self.issue(status: response.statusCode, response: response, provider: "Anthropic"))
            }
            do {
                guard let root = Self.jsonObject(data) else { throw MalformedSpend() }
                cursor = try Self.parse(root, into: &result)
            } catch {
                return .failure(.unsupported("Unexpected cost response from Anthropic"))
            }
            pages += 1
            if cursor == nil { return .success(result) }
            if pages >= maxPages { return .failure(.unsupported("Anthropic returned more cost pages than expected")) }
        }
    }
}

// MARK: - OpenAI

/// `GET /v1/organization/costs`, daily buckets from the start of the UTC month to now.
/// Amounts are `{ "value": <dollars>, "currency": "usd" }` per result, summed per bucket.
public struct OpenAIAdminUsageProvider: AdminSpendProvider {
    public let api = APIProvider.openai
    public var harness: Harness { api.brandHarness }
    public var key: UsageProviderKey { .api(api) }
    public func fetch(_ subscription: Subscription, context: UsageFetchContext) async -> UsageReport {
        await fetchSpend(subscription, context: context)
    }
    let secrets: any SecretStore
    let transport: any HTTPTransport
    static let costsURL = URL(string: "https://api.openai.com/v1/organization/costs")!

    public init(secrets: any SecretStore = KeychainSecretStore(), transport: any HTTPTransport = URLSession.providerAPI) {
        self.secrets = secrets
        self.transport = transport
    }

    static func request(month: BillingMonth, now: Date, key: String, page: String?, appVersion: String) -> URLRequest? {
        let start = Int(month.start.timeIntervalSince1970)
        let end = Int(min(now, month.end).timeIntervalSince1970)
        guard end > start else { return nil }
        var components = URLComponents(url: costsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(start)),
            URLQueryItem(name: "end_time", value: String(end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("HarnessButler/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Adds one page's buckets into `page`; returns the next-page cursor, if any. Malformed pages fail whole.
    static func parse(_ root: [String: Any], into page: inout SpendPage) throws(MalformedSpend) -> String? {
        guard let buckets = root["data"] as? [Any] else { throw MalformedSpend() }
        for bucket in buckets {
            guard let bucket = bucket as? [String: Any], let start = number(bucket["start_time"]) else { throw MalformedSpend() }
            let day = BillingMonth.utcDay(containing: Date(timeIntervalSince1970: start))
            // Every bucket lists its results; a day without spend has an empty list.
            guard let results = bucket["results"] as? [Any] else { throw MalformedSpend() }
            for result in results {
                guard let result = result as? [String: Any], let amount = LenientJSON.object(result["amount"]),
                      let value = number(amount["value"]) else { throw MalformedSpend() }
                if let currency = LenientJSON.string(amount["currency"]) { page.currency = currency.uppercased() }
                page.days[day, default: 0] += value
            }
        }
        return try nextPage(root)
    }

    func readMonth(_ month: BillingMonth, key: String, context: UsageFetchContext) async -> Result<SpendPage, UsageIssue> {
        var result = SpendPage()
        var cursor: String?
        var pages = 0
        repeat {
            guard let request = Self.request(month: month, now: context.now, key: key, page: cursor, appVersion: context.appVersion) else {
                return .success(result)
            }
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch {
                return .failure(.unavailable("Can't reach OpenAI"))
            }
            guard response.statusCode == 200 else {
                return .failure(Self.issue(status: response.statusCode, response: response, provider: "OpenAI"))
            }
            do {
                guard let root = Self.jsonObject(data) else { throw MalformedSpend() }
                cursor = try Self.parse(root, into: &result)
            } catch {
                return .failure(.unsupported("Unexpected costs response from OpenAI"))
            }
            pages += 1
            if cursor != nil, pages >= maxPages { return .failure(.unsupported("OpenAI returned more cost pages than expected")) }
        } while cursor != nil
        return .success(result)
    }
}
