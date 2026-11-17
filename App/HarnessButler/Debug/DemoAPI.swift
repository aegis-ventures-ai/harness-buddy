#if DEBUG
import Foundation
import HarnessButlerKit

/// `--demo-api`: runs the app on a throwaway copy of the subscription list plus two API-spend
/// subscriptions whose providers answer from canned data. The real subscriptions file, usage cache
/// and Keychain are never written, and no request leaves the Mac for the demo rows.
enum DemoAPI {
    static var isEnabled: Bool { CommandLine.arguments.contains("--demo-api") }

    static func makeStore(appVersion: String) -> UsageStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "HarnessButler-demo-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = SubscriptionFile(url: directory.appending(path: "subscriptions.json"))
        var subscriptions = ((try? SubscriptionFile.standard.load()) ?? nil) ?? []
        let anthropic = Subscription.api(APIAccount(provider: .anthropic, monthlyBudget: 400), name: "Anthropic API (demo)")
        let openai = Subscription.api(APIAccount(provider: .openai), name: "OpenAI API (demo)")
        subscriptions += [anthropic, openai]
        try? file.save(subscriptions)

        let secrets = InMemorySecretStore([
            anthropic.id.uuidString: "sk-ant-admin01-demo",
            openai.id.uuidString: "sk-admin-demo",
        ])
        let transport = CannedSpendTransport()
        return UsageStore(
            file: file,
            cacheFile: UsageCacheFile(url: directory.appending(path: "usage-cache.json")),
            providers: [
                ClaudeUsageProvider(), CodexAppServerUsageProvider(), GrokACPUsageProvider(),
                AnthropicAdminUsageProvider(secrets: secrets, transport: transport),
                OpenAIAdminUsageProvider(secrets: secrets, transport: transport),
            ],
            secrets: secrets,
            appVersion: appVersion
        )
    }
}

/// Answers the two cost endpoints with a plausible month: Anthropic about $14/hour on weekdays
/// (at risk against a $400 budget late in the month), OpenAI a few dollars a day.
private struct CannedSpendTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .milliseconds(300))
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let body: String
        if url.host() == "api.anthropic.com" {
            let start = item("starting_at").flatMap { try? Date($0, strategy: .iso8601) } ?? .now
            let end = item("ending_at").flatMap { try? Date($0, strategy: .iso8601) } ?? .now
            var rows: [String] = []
            var hour = start
            while hour < end {
                let weekday = Calendar(identifier: .gregorian).component(.weekday, from: hour)
                if weekday != 1, weekday != 7 {
                    let cents = 30 + Double(abs(hour.hashValue) % 70)
                    rows.append(#"{"starting_at":"\#(hour.formatted(.iso8601))","ending_at":"\#(hour.addingTimeInterval(3600).formatted(.iso8601))","group":{},"cost":{"currency":"USD","amount":"\#(String(format: "%.6f", cents))"}}"#)
                }
                hour = hour.addingTimeInterval(3600)
            }
            body = #"{"data":[\#(rows.joined(separator: ","))],"has_more":false,"next_page":null,"data_refreshed_at":"\#(end.addingTimeInterval(-4 * 3600).formatted(.iso8601))"}"#
        } else {
            let start = Double(item("start_time") ?? "") ?? Date.now.timeIntervalSince1970
            let end = Double(item("end_time") ?? "") ?? Date.now.timeIntervalSince1970
            var buckets: [String] = []
            var day = start
            while day < end {
                let value = 2 + (day / 86_400).truncatingRemainder(dividingBy: 5)
                buckets.append(#"{"object":"bucket","start_time":\#(Int(day)),"end_time":\#(Int(day + 86_400)),"results":[{"object":"organization.costs.result","amount":{"value":\#(value),"currency":"usd"}}]}"#)
                day += 86_400
            }
            body = #"{"object":"page","data":[\#(buckets.joined(separator: ","))],"has_more":false,"next_page":null}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
#endif
