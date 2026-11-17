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

    @Test func searchPathMergesLoginShellProcessAndWellKnown() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let path = HarnessEnvironment.mergedSearchPath(loginShellPath: "/custom/bin:/usr/bin", processPath: "/usr/bin:/bin", homeDirectory: home)
        #expect(path.prefix(3) == ["/custom/bin", "/usr/bin", "/bin"])
        #expect(path.contains("/Users/test/.local/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(Set(path).count == path.count)
    }
}
