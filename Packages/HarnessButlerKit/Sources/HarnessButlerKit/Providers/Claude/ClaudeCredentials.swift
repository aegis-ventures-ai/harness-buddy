import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Synchronization

/// The minimum taken from Claude Code's credential blob. Everything else (refresh token,
/// third-party MCP tokens) is dropped as soon as it is parsed and never stored.
struct ClaudeCredentials: Sendable {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?
    var rateLimitTier: String?

    static func parse(_ data: Data) -> ClaudeCredentials? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = JSONValue.object(root["claudeAiOauth"]),
            let token = JSONValue.string(oauth["accessToken"]), !token.isEmpty
        else { return nil }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: JSONValue.double(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: JSONValue.string(oauth["subscriptionType"]),
            rateLimitTier: JSONValue.string(oauth["rateLimitTier"])
        )
    }
}

enum ClaudeCredentialError: Error, Equatable {
    case notFound
    case keychainLocked
    case unreadable(String)
}

/// Reads the Claude Code OAuth credential the way the CLI does: by spawning `/usr/bin/security`,
/// the only client on the item's ACL. A direct Keychain API call would prompt.
enum ClaudeKeychain {
    /// `Claude Code-credentials` for the default dir; with `CLAUDE_CONFIG_DIR` set,
    /// `Claude Code-credentials-` + first 8 hex of sha256(NFC(value as exported)).
    static func serviceName(configDirOverride: String?) -> String {
        guard let dir = configDirOverride, !dir.isEmpty else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    static func account(environment: [String: String]) -> String {
        let user = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        return user.wholeMatch(of: /[a-zA-Z0-9._-]+/) != nil ? user : "claude-code-user"
    }

    static func read(configDirOverride: String?, configDir: URL, environment: [String: String]) async throws(ClaudeCredentialError) -> ClaudeCredentials {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                URL(filePath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-a", account(environment: environment), "-w", "-s", serviceName(configDirOverride: configDirOverride)],
                timeout: .seconds(2)
            )
        } catch {
            throw .unreadable("couldn't run security")
        }
        switch result.exitCode {
        case 0:
            if let creds = ClaudeCredentials.parse(result.stdout) { return creds }
            throw .unreadable("unexpected credential format")
        case 44:
            // Plaintext fallback the CLI uses when the Keychain write fails.
            let file = configDir.appending(path: ".credentials.json")
            if let data = try? Data(contentsOf: file), let creds = ClaudeCredentials.parse(data) { return creds }
            throw .notFound
        case 36:
            throw .keychainLocked
        default:
            throw .unreadable(result.timedOut ? "security timed out" : "security exited \(result.exitCode)")
        }
    }
}

extension Subscription {
    /// The Keychain item Claude Code uses for this config dir, shown in Settings so a mismatched
    /// path (trailing `/`, unexpanded `~`) is easy to spot.
    public var claudeKeychainService: String? {
        harness == .claude ? ClaudeKeychain.serviceName(configDirOverride: homeOverride) : nil
    }
}

/// Where the Claude provider gets credentials. Injectable for tests.
protocol ClaudeCredentialSource: Sendable {
    /// When the credential last changed, read without touching its secret (and without prompting).
    /// `nil` when unknown.
    func modificationDate(configDirOverride: String?, configDir: URL, environment: [String: String]) -> Date?
    func read(configDirOverride: String?, configDir: URL, environment: [String: String]) async throws(ClaudeCredentialError) -> ClaudeCredentials
}

struct SystemClaudeCredentialSource: ClaudeCredentialSource {
    func modificationDate(configDirOverride: String?, configDir: URL, environment: [String: String]) -> Date? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ClaudeKeychain.serviceName(configDirOverride: configDirOverride),
            kSecAttrAccount as String: ClaudeKeychain.account(environment: environment),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let attributes = result as? [String: Any],
           let date = attributes[kSecAttrModificationDate as String] as? Date {
            return date
        }
        let file = configDir.appending(path: ".credentials.json")
        return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func read(configDirOverride: String?, configDir: URL, environment: [String: String]) async throws(ClaudeCredentialError) -> ClaudeCredentials {
        try await ClaudeKeychain.read(configDirOverride: configDirOverride, configDir: configDir, environment: environment)
    }
}

/// Remembers credentials the API rejected (or that had expired), keyed by Keychain service,
/// so the provider doesn't retry until Claude Code has rewritten them (spike 01, step 5).
final class ClaudeRejectedCredentials: Sendable {
    private let rejected = Mutex<[String: Date]>([:])

    /// True when `service` was rejected at exactly this credential version.
    func isRejected(_ service: String, credentialDate: Date?) -> Bool {
        guard let credentialDate else { return false } // unknown version: don't block
        return rejected.withLock { $0[service] == credentialDate }
    }

    func reject(_ service: String, credentialDate: Date?) {
        rejected.withLock { $0[service] = credentialDate }
    }

    func clear(_ service: String) {
        _ = rejected.withLock { $0.removeValue(forKey: service) }
    }
}
