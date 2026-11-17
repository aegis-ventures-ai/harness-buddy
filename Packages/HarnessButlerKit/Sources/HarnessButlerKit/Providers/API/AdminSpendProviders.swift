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
    /// No disk cache, no cookies: spend responses stay in memory and only the app's own cache file keeps totals.
    public static let adminAPI: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
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
            return .rateLimited(retryAfter: response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init))
        default:
            return .unavailable("\(provider) returned HTTP \(status)")
        }
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        if let string = value as? String { return Double(string) }
        return LenientJSON.double(value)
    }
}

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

    public init(secrets: any SecretStore = KeychainSecretStore(), transport: any HTTPTransport = URLSession.adminAPI) {
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

    /// Adds one page's rows into `page`; returns the next-page cursor, if any.
    static func parse(_ root: [String: Any], into page: inout SpendPage) -> String? {
        if let refreshed = ISO8601.date(LenientJSON.string(root["data_refreshed_at"])) { page.dataThrough = refreshed }
        for row in LenientJSON.array(root["data"]) ?? [] {
            guard let start = ISO8601.date(LenientJSON.string(row["starting_at"])),
                  let cost = LenientJSON.object(row["cost"]),
                  let cents = number(cost["amount"]) else { continue }
            if let currency = LenientJSON.string(cost["currency"]) { page.currency = currency.uppercased() }
            page.days[BillingMonth.utcDay(containing: start), default: 0] += cents / 100
        }
        guard root["has_more"] as? Bool == true, let next = LenientJSON.string(root["next_page"]), !next.isEmpty else { return nil }
        return next
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
            guard let root = Self.jsonObject(data) else {
                return .failure(.unsupported("Unexpected cost response from Anthropic"))
            }
            cursor = Self.parse(root, into: &result)
            pages += 1
            if cursor == nil || pages >= maxPages { break }
        }
        return .success(result)
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

    public init(secrets: any SecretStore = KeychainSecretStore(), transport: any HTTPTransport = URLSession.adminAPI) {
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

    static func parse(_ root: [String: Any], into page: inout SpendPage) -> String? {
        for bucket in LenientJSON.array(root["data"]) ?? [] {
            guard let start = number(bucket["start_time"]) else { continue }
            let day = BillingMonth.utcDay(containing: Date(timeIntervalSince1970: start))
            for result in LenientJSON.array(bucket["results"]) ?? [] {
                guard let amount = LenientJSON.object(result["amount"]), let value = number(amount["value"]) else { continue }
                if let currency = LenientJSON.string(amount["currency"]) { page.currency = currency.uppercased() }
                page.days[day, default: 0] += value
            }
        }
        guard root["has_more"] as? Bool == true, let next = LenientJSON.string(root["next_page"]), !next.isEmpty else { return nil }
        return next
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
            guard let root = Self.jsonObject(data) else {
                return .failure(.unsupported("Unexpected costs response from OpenAI"))
            }
            cursor = Self.parse(root, into: &result)
            pages += 1
        } while cursor != nil && pages < maxPages
        return .success(result)
    }
}
