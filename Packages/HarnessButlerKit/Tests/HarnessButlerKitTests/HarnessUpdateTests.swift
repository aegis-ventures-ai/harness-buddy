import Foundation
import Synchronization
import Testing
@testable import HarnessButlerKit

@Suite struct SemanticVersionTests {
    @Test(arguments: [
        ("2.1.326 (Claude Code)", "2.1.326"),
        ("codex-cli 0.167.2", "0.167.2"),
        ("grok 1.0.88 (2fe3608f7398) [stable]", "1.0.88"),
        ("rust-v0.169.0", "0.169.0"),
        ("1.2.3-alpha.1", "1.2.3-alpha.1"),
        ("v10.4", "10.4"),
    ])
    func parses(input: String, expected: String) throws {
        #expect(try #require(SemanticVersion(input)).description == expected)
    }

    @Test func rejectsTextWithoutVersion() {
        #expect(SemanticVersion("grok (2fe3608f7398)") == nil)
        #expect(SemanticVersion("") == nil)
    }

    @Test func ordersNumericallyAndPutsPrereleasesFirst() throws {
        func v(_ s: String) throws -> SemanticVersion { try #require(SemanticVersion(s)) }
        #expect(try v("0.167.2") < v("0.169.0"))
        #expect(try v("2.1.99") < v("2.1.326"))
        #expect(try v("1.0") == v("1.0.0"))
        #expect(try v("1.0.0-alpha") < v("1.0.0"))
        #expect(try v("1.0.0-alpha.2") < v("1.0.0-alpha.10"))
        #expect(try !(v("1.0.88") < v("1.0.88")))
    }
}

@Suite struct InstallMethodTests {
    @Test(arguments: [
        (Harness.claude, "/Users/u/.local/share/claude/versions/2.1.326", InstallMethod.claudeNative),
        (.codex, "/opt/homebrew/Caskroom/codex/0.167.2/bin/codex", .homebrewCask(token: "codex")),
        (.claude, "/opt/homebrew/Caskroom/claude-code/2.1.0/claude", .homebrewCask(token: "claude-code")),
        (.grok, "/opt/homebrew/Cellar/grok/1.0.0/bin/grok", .homebrewFormula(name: "grok")),
        (.grok, "/Users/u/.grok/downloads/grok-1.0.88-macos-aarch64", .grokInstaller),
        (.codex, "/Users/u/.nvm/versions/node/v22/lib/node_modules/@openai/codex/bin/codex.js", .nodeGlobal(.npm, package: "@openai/codex")),
        (.codex, "/Users/u/.bun/install/global/node_modules/@openai/codex/bin/codex.js", .nodeGlobal(.bun, package: "@openai/codex")),
        (.claude, "/Users/u/Library/pnpm/global/5/node_modules/@anthropic-ai/claude-code/cli.js", .nodeGlobal(.pnpm, package: "@anthropic-ai/claude-code")),
        (.codex, "/usr/local/bin/codex", .unknown),
    ])
    func classifies(harness: Harness, path: String, expected: InstallMethod) {
        #expect(InstallMethod.classify(harness: harness, resolvedPath: path) == expected)
    }

    @Test func codexStandaloneNeedsPackageJSON() {
        #expect(InstallMethod.classify(harness: .codex, resolvedPath: "/Users/u/.codex/bin/codex", hasCodexPackageJSON: true) == .codexStandalone)
    }

    @Test func updateCommands() throws {
        let tools = ["brew": "/opt/homebrew/bin/brew", "npm": "/usr/local/bin/npm", "bun": "/Users/u/.bun/bin/bun"]
        func locate(_ name: String) -> URL? { tools[name].map { URL(filePath: $0) } }
        let binary = URL(filePath: "/Users/u/.local/bin/claude")

        #expect(InstallMethod.claudeNative.updateCommand(binary: binary, locate: locate)?.displayString == "claude update")
        let cask = try #require(InstallMethod.homebrewCask(token: "codex").updateCommand(binary: binary, locate: locate))
        #expect(cask.displayString == "brew upgrade --cask codex")
        #expect(cask.environment["HOMEBREW_AUTO_UPDATE_SECS"] == "0")
        #expect(InstallMethod.nodeGlobal(.npm, package: "@openai/codex").updateCommand(binary: binary, locate: locate)?.displayString
            == "npm install -g @openai/codex@latest")
        #expect(InstallMethod.nodeGlobal(.bun, package: "@openai/codex").updateCommand(binary: binary, locate: locate)?.displayString
            == "bun add -g @openai/codex@latest")
        // Missing helper or unknown method: no command rather than a guess.
        #expect(InstallMethod.nodeGlobal(.pnpm, package: "x").updateCommand(binary: binary, locate: locate) == nil)
        #expect(InstallMethod.unknown.updateCommand(binary: binary, locate: locate) == nil)
    }

    @Test func latestSourcesPerMethodAndChannel() {
        #expect(InstallMethod.claudeNative.latestVersionSource(channel: nil)?.url.absoluteString == "https://downloads.claude.ai/claude-code-releases/latest")
        #expect(InstallMethod.claudeNative.latestVersionSource(channel: "stable")?.url.absoluteString == "https://downloads.claude.ai/claude-code-releases/stable")
        #expect(InstallMethod.claudeNative.latestVersionSource(channel: "../etc")?.url.absoluteString == "https://downloads.claude.ai/claude-code-releases/latest")
        #expect(InstallMethod.grokInstaller.latestVersionSource(channel: "alpha")?.url.absoluteString == "https://x.ai/cli/alpha")
        #expect(InstallMethod.homebrewCask(token: "codex").latestVersionSource(channel: nil)?.url.absoluteString == "https://formulae.brew.sh/api/cask/codex.json")
        #expect(InstallMethod.nodeGlobal(.npm, package: "@openai/codex").latestVersionSource(channel: nil)?.url.absoluteString == "https://registry.npmjs.org/@openai/codex/latest")
        #expect(InstallMethod.unknown.latestVersionSource(channel: nil) == nil)
    }

    @Test func parsesEachSourceFormat() throws {
        func parse(_ format: LatestVersionSource.Format, _ body: String) -> String? {
            LatestVersionSource(url: URL(string: "https://example.com")!, format: format).parse(Data(body.utf8))?.description
        }
        #expect(parse(.plainText, "2.1.331\n") == "2.1.331")
        #expect(parse(.homebrewCask, #"{"token":"codex","version":"0.169.0"}"#) == "0.169.0")
        #expect(parse(.homebrewCask, #"{"version":"1.4.2,8812"}"#) == "1.4.2")
        #expect(parse(.homebrewFormula, #"{"versions":{"stable":"3.2.1","head":"HEAD"}}"#) == "3.2.1")
        #expect(parse(.npm, #"{"name":"@openai/codex","version":"0.169.0"}"#) == "0.169.0")
        #expect(parse(.githubRelease, #"{"tag_name":"rust-v0.169.0"}"#) == "0.169.0")
        #expect(parse(.plainText, "<html>error</html>") == nil)
    }
}

@Suite struct TerminalLogTests {
    @Test func carriageReturnRewritesTheCurrentLine() {
        var log = TerminalLog()
        log.append("Downloading 10%\rDownloading 50%\rDownloading 100%\nDone\n")
        #expect(log.displayLines == ["Downloading 100%", "Done"])
    }

    @Test func handlesChunkBoundariesAndCRLF() {
        var log = TerminalLog()
        log.append("Check")
        log.append("ing\r\nNext ")
        log.append("line")
        #expect(log.displayLines == ["Checking", "Next line"])
    }

    @Test func stripsANSIAndCapsLines() {
        var log = TerminalLog(limit: 2)
        log.append("\u{1B}[32mgreen\u{1B}[0m\n\u{1B}[2Kb\nc\n")
        #expect(log.displayLines == ["b", "c"])
    }

    @Test func appLinesCloseThePartialLine() {
        var log = TerminalLog()
        log.append("partial")
        log.appendLine("✓ done")
        #expect(log.displayLines == ["partial", "✓ done"])
    }
}

@Suite(.serialized) struct StreamingProcessTests {
    @Test func streamsOutputAndExitCode() async throws {
        let chunks = Mutex<[String]>([])
        let result = try await StreamingProcess.run(
            URL(filePath: "/bin/sh"), arguments: ["-c", "printf 'a\\n'; printf 'b\\n' >&2; exit 4"], environment: [:]
        ) { chunk in chunks.withLock { $0.append(chunk) } }
        #expect(result == StreamingResult(exitCode: 4, timedOut: false, cancelled: false))
        #expect(chunks.withLock { $0.joined() }.contains("a\n"))
        #expect(chunks.withLock { $0.joined() }.contains("b\n"))
    }

    @Test func cancellingTheTaskStopsTheProcess() async throws {
        let task = Task {
            try await StreamingProcess.run(URL(filePath: "/bin/sh"), arguments: ["-c", "sleep 30"], environment: [:]) { _ in }
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = try await task.value
        #expect(result.cancelled)
    }

    @Test func utf8SplitAcrossChunksDecodesCleanly() {
        let decoder = UTF8ChunkDecoder()
        let bytes = Array("█▉".utf8) // 3 bytes each
        #expect(decoder.decode(Data(bytes[0..<4])) == "█")
        #expect(decoder.decode(Data(bytes[4...])) == "▉")
        #expect(decoder.flush() == nil)
    }

    @Test func countsRunningProcessesByExecutable() async throws {
        let task = Task { try await ProcessRunner.run(URL(filePath: "/bin/sleep"), arguments: ["1"], timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(RunningProcesses.count(executable: URL(filePath: "/bin/sleep")) >= 1)
        #expect(RunningProcesses.count(executable: URL(filePath: "/bin/sleep"), excluding: ChildProcessRegistry.shared.pids) == 0)
        _ = try await task.value
    }
}

@Suite struct UpdateOutcomeTests {
    let v1 = SemanticVersion("1.0.0")!, v2 = SemanticVersion("1.1.0")!

    func ok(_ code: Int32 = 0) -> StreamingResult { StreamingResult(exitCode: code, timedOut: false, cancelled: false) }

    @Test func outcomes() {
        #expect(HarnessStore.outcome(result: ok(), from: v1, target: v2, now: v2) == .succeeded(v2))
        #expect(HarnessStore.outcome(result: ok(), from: v1, target: nil, now: v2) == .succeeded(v2))
        #expect(HarnessStore.outcome(result: ok(), from: v1, target: v2, now: v1) == .failed("The updater finished, but the installed version is still 1.0.0"))
        #expect(HarnessStore.outcome(result: ok(1), from: v1, target: v2, now: v1) == .failed("The updater exited with status 1"))
        #expect(HarnessStore.outcome(result: StreamingResult(exitCode: 15, timedOut: false, cancelled: true), from: v1, target: v2, now: v1) == .cancelled)
        #expect(HarnessStore.outcome(result: nil, from: v1, target: v2, now: nil) == .failed("The updater couldn't be started"))
    }

    @Test func updateAvailability() {
        var status = HarnessStatus()
        #expect(!status.isUpdateAvailable)
        status.latest = v2
        status.installation = HarnessInstallation(
            harness: .codex, binary: URL(filePath: "/x"), resolvedBinary: URL(filePath: "/x"),
            version: v1, versionOutput: nil, method: .unknown, channel: nil, detectedAt: .now
        )
        #expect(status.isUpdateAvailable)
        status.latest = v1
        #expect(!status.isUpdateAvailable)
    }
}
