import Foundation
import Testing
@testable import HarnessButlerKit

@Suite(.serialized) struct ProcessTests {
    let sh = URL(filePath: "/bin/sh")

    @Test func runnerCapturesOutputAndExitCode() async throws {
        let result = try await ProcessRunner.run(sh, arguments: ["-c", "printf out; printf err >&2; exit 3"])
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err")
        #expect(result.exitCode == 3)
        #expect(!result.timedOut)
    }

    @Test func runnerKillsOnTimeout() async throws {
        let start = ContinuousClock.now
        let result = try await ProcessRunner.run(sh, arguments: ["-c", "sleep 30"], timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func runnerDoesNotWaitForADescendantHoldingThePipe() async throws {
        // The wrapper exits at once; its background child keeps stdout open forever.
        // (`tail`, not `sleep`: another suite counts running `sleep` processes.)
        let start = ContinuousClock.now
        let result = try await ProcessRunner.run(sh, arguments: ["-c", "/usr/bin/tail -f /dev/null & echo $!; exit 0"], timeout: .seconds(10))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(result.exitCode == 0)
        let child = try #require(pid_t(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        // ...and the descendant was stopped with the process group.
        var alive = true
        for _ in 0..<50 where alive {
            alive = kill(child, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive)
    }

    /// Reads the pid a test child wrote, then waits until that process is gone.
    func descendantStops(pidFile: URL) async throws -> Bool {
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(text))
        for _ in 0..<60 {
            if kill(pid, 0) != 0 { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        kill(pid, SIGKILL)
        return false
    }

    @Test func descendantsWithTheirOwnOutputStopWhenTheCommandExits() async throws {
        // A helper that redirects its output never holds our pipe; it must still not outlive the command.
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "hb-desc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "/usr/bin/tail -f /dev/null </dev/null >/dev/null 2>&1 & echo $! > \"$0\"; exit 0"
        _ = try await ProcessRunner.run(sh, arguments: ["-c", script, pidFile.path(percentEncoded: false)])
        #expect(try await descendantStops(pidFile: pidFile))

    }

    @Test func anUpdaterThatFinishesMayLeaveAFinisherRunning() async throws {
        // Like a terminal: only an update we stopped takes its helpers with it.
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "hb-desc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "/usr/bin/tail -f /dev/null </dev/null >/dev/null 2>&1 & echo $! > \"$0\"; exit 0"
        _ = try await StreamingProcess.run(sh, arguments: ["-c", script, pidFile.path(percentEncoded: false)], environment: [:]) { _ in }
        let pid = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(pid, 0) == 0)
    }

    @Test func aTimedOutUpdaterTakesItsHelpersWithIt() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "hb-desc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "/usr/bin/tail -f /dev/null </dev/null >/dev/null 2>&1 & echo $! > \"$0\"; exec /usr/bin/tail -f /dev/null"
        let result = try await StreamingProcess.run(sh, arguments: ["-c", script, pidFile.path(percentEncoded: false)], environment: [:],
                                                    timeout: .milliseconds(500)) { _ in }
        #expect(result.timedOut)
        #expect(try await descendantStops(pidFile: pidFile))
    }

    @Test func jsonRPCChildThatExitsTakesItsHelpersWithIt() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "hb-desc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let session = try LineJSONRPCSession(
            executable: sh,
            arguments: ["-c", "/usr/bin/tail -f /dev/null </dev/null >/dev/null 2>&1 & echo $! > \"$0\"; read x; exit 4", pidFile.path(percentEncoded: false)],
            environment: [:], includeVersionField: false, timeout: .seconds(5)
        )
        defer { session.close() }
        await #expect(throws: JSONRPCSessionError.processExited(4)) { _ = try await session.request("initialize") }
        #expect(try await descendantStops(pidFile: pidFile))
    }

    @Test func streamingDoesNotWaitForADescendantHoldingThePipe() async throws {
        let start = ContinuousClock.now
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "hb-desc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let result = try await StreamingProcess.run(sh, arguments: ["-c", "echo started; /usr/bin/tail -f /dev/null & echo $! > \"$0\"; exit 0", pidFile.path(percentEncoded: false)], environment: [:]) { _ in }
        #expect(result.exitCode == 0)
        #expect(ContinuousClock.now - start < .seconds(6))
        if let pid = pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") { kill(pid, SIGKILL) }
    }

    @Test func runnerReportsLaunchFailure() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.run(URL(filePath: "/nonexistent/binary"))
        }
    }

    /// A fake JSON-RPC server: emits a notification, then answers request 1 with a result
    /// and request 2 with an error, echoing nothing it doesn't understand.
    static let fakeServer = #"""
    read line1
    printf '%s\n' '{"method":"note","params":{}}'
    printf '%s\n' '{"id":1,"result":{"ok":true}}'
    read line2
    case "$line2" in *'"jsonrpc":"2.0"'*) v=yes;; *) v=no;; esac
    printf '{"id":2,"error":{"code":-32601,"message":"nope %s"}}\n' "$v"
    sleep 30
    """#

    @Test func jsonRPCMatchesResponsesAndErrors() async throws {
        let session = try LineJSONRPCSession(
            executable: sh, arguments: ["-c", Self.fakeServer], environment: [:], includeVersionField: true, timeout: .seconds(5)
        )
        defer { session.close() }
        let first = try await session.request("initialize")
        #expect((first as? [String: Any])?["ok"] as? Bool == true)
        do {
            _ = try await session.request("missing")
            Issue.record("expected an error")
        } catch let error as JSONRPCError {
            #expect(error == JSONRPCError(code: -32601, message: "nope yes"))
        }
    }

    @Test func jsonRPCTimesOut() async throws {
        let session = try LineJSONRPCSession(
            executable: sh, arguments: ["-c", "sleep 30"], environment: [:], includeVersionField: false, timeout: .milliseconds(300)
        )
        defer { session.close() }
        await #expect(throws: JSONRPCSessionError.timedOut) {
            _ = try await session.request("initialize")
        }
    }

    @Test func jsonRPCFailsWhenProcessExits() async throws {
        let session = try LineJSONRPCSession(
            executable: sh, arguments: ["-c", "read x; exit 7"], environment: [:], includeVersionField: false, timeout: .seconds(5)
        )
        await #expect(throws: JSONRPCSessionError.processExited(7)) {
            _ = try await session.request("initialize")
        }
    }

    @Test func writingToAnExitedChildFailsInsteadOfRaisingSIGPIPE() async throws {
        // SIGPIPE's default action would end the test process; the session must turn it into an error.
        let session = try LineJSONRPCSession(
            executable: sh, arguments: ["-c", "exec 0<&-; exit 3"], environment: [:], includeVersionField: false, timeout: .seconds(5)
        )
        defer { session.close() }
        let deadline = Date.now.addingTimeInterval(5)
        var failed = false
        while !failed, Date.now < deadline {
            do { try session.notify("initialized", params: ["padding": String(repeating: "x", count: 70_000)]) } catch { failed = true }
            if !failed { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(failed)
        await #expect(throws: (any Error).self) { _ = try await session.request("initialize") }
    }

    @Test func searchPathMergesLoginShellProcessAndWellKnown() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let path = HarnessEnvironment.mergedSearchPath(loginShellPath: "/custom/bin:/usr/bin", processPath: "/usr/bin:/bin", homeDirectory: home)
        #expect(path.prefix(3) == ["/custom/bin", "/usr/bin", "/bin"])
        #expect(path.contains("/Users/test/.local/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(Set(path).count == path.count)
    }
}
