import Foundation

/// The environment harness processes run in.
///
/// A menubar app launched from Finder gets a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`),
/// which can't find Homebrew, npm or `~/.local/bin` installs, nor `node` for npm-installed Codex.
/// This builds a `PATH` from the user's login shell plus well-known install locations.
public struct HarnessEnvironment: Sendable {
    public var homeDirectory: URL
    public var searchPath: [String]
    public var baseEnvironment: [String: String]

    public init(homeDirectory: URL, searchPath: [String], baseEnvironment: [String: String]) {
        self.homeDirectory = homeDirectory
        self.searchPath = searchPath
        self.baseEnvironment = baseEnvironment
    }

    /// Resolve once at launch. Asks the login shell for its `PATH` (3 s timeout).
    public static func resolve(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> HarnessEnvironment {
        let shellPath = await loginShellPath(environment: processEnvironment)
        let path = mergedSearchPath(
            loginShellPath: shellPath,
            processPath: processEnvironment["PATH"],
            homeDirectory: homeDirectory
        )
        var base: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING"] {
            if let value = processEnvironment[key] { base[key] = value }
        }
        base["HOME"] = base["HOME"] ?? homeDirectory.path(percentEncoded: false)
        return HarnessEnvironment(homeDirectory: homeDirectory, searchPath: path, baseEnvironment: base)
    }

    static func mergedSearchPath(loginShellPath: String?, processPath: String?, homeDirectory: URL) -> [String] {
        let home = homeDirectory.path(percentEncoded: false).trimmingSuffix("/")
        let wellKnown = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "\(home)/Library/pnpm",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        var result: [String] = []
        for entry in (loginShellPath ?? "").split(separator: ":").map(String.init)
            + (processPath ?? "").split(separator: ":").map(String.init)
            + wellKnown where !entry.isEmpty && seen.insert(entry).inserted {
            result.append(entry)
        }
        return result
    }

    private static func loginShellPath(environment: [String: String]) async -> String? {
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__HB_PATH__"
        guard let result = try? await ProcessRunner.run(
            URL(filePath: shell),
            arguments: ["-l", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""],
            timeout: .seconds(3)
        ), result.exitCode == 0, !result.timedOut else { return nil }
        let output = String(decoding: result.stdout, as: UTF8.self)
        let parts = output.components(separatedBy: marker)
        return parts.count >= 3 ? parts[1] : nil
    }

    /// Environment for a harness child process.
    public func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var env = baseEnvironment
        env["PATH"] = searchPath.joined(separator: ":")
        env.merge(extra) { _, new in new }
        return env
    }

    /// First executable named `name` in `preferred` locations, then on the search path.
    public func locate(_ name: String, preferring preferred: [URL] = []) -> URL? {
        let fm = FileManager.default
        for url in preferred where fm.isExecutableFile(atPath: url.path(percentEncoded: false)) {
            return url
        }
        for dir in searchPath {
            let candidate = URL(filePath: dir, directoryHint: .isDirectory).appending(path: name)
            if fm.isExecutableFile(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return nil
    }
}
