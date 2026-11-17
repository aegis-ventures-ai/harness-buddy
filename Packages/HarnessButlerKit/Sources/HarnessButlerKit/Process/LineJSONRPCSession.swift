import Foundation
import Synchronization

public struct JSONRPCError: Error, Hashable, Sendable {
    public var code: Int
    public var message: String
}

public enum JSONRPCSessionError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case processExited(Int32)
    case malformedResponse
}

/// Newline-delimited JSON-RPC over a child process's stdio.
///
/// Used for `codex app-server` (no `"jsonrpc"` field) and `grok agent stdio` (ACP, `"jsonrpc": "2.0"`).
/// Notifications and server-to-client requests are ignored. The process is killed on `close()`,
/// on overall timeout, and when the app quits.
public final class LineJSONRPCSession: Sendable {
    private struct State {
        var nextID = 1
        var pending: [Int: CheckedContinuation<Any, any Error>] = [:]
        var buffer = Data()
        var exited: Int32?
        var timedOut = false
    }

    private let process: Process
    private let stdin: FileHandle
    private let includeVersionField: Bool
    private let state = Mutex(State())

    /// - Parameter timeout: hard limit on the whole session, after which the process is killed.
    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        includeVersionField: Bool,
        timeout: Duration = .seconds(10)
    ) throws(JSONRPCSessionError) {
        self.includeVersionField = includeVersionField
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        // A child that exits early must make writes fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] finished in
            reapGroup(of: finished.processIdentifier)
            ChildProcessRegistry.shared.unregister(finished)
            self?.failAll(exitCode: finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            throw .launchFailed(error.localizedDescription)
        }
        ChildProcessRegistry.shared.register(process)

        Task.detached { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.expire()
        }
    }

    deinit { terminate(process) }

    /// Send a request and wait for its result object.
    public func request(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            let failure: (any Error)? = state.withLock { state in
                if state.timedOut { return JSONRPCSessionError.timedOut }
                if let code = state.exited { return JSONRPCSessionError.processExited(code) }
                let id = state.nextID
                state.nextID += 1
                state.pending[id] = continuation
                do {
                    try write(["id": id, "method": method, "params": params])
                } catch {
                    state.pending[id] = nil
                    return error
                }
                return nil
            }
            if let failure { continuation.resume(throwing: failure) }
        }
    }

    public func notify(_ method: String, params: [String: Any]? = nil) throws {
        var message: [String: Any] = ["method": method]
        if let params { message["params"] = params }
        try state.withLock { state in
            if state.timedOut { throw JSONRPCSessionError.timedOut }
            if let code = state.exited { throw JSONRPCSessionError.processExited(code) }
            try write(message)
        }
    }

    /// Close stdin and terminate the process (SIGTERM, then SIGKILL after 2 s).
    public func close() {
        try? stdin.close()
        terminate(process)
    }

    // MARK: - Private

    private func write(_ message: [String: Any]) throws {
        var message = message
        if includeVersionField { message["jsonrpc"] = "2.0" }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        let lines: [Data] = state.withLock { state in
            state.buffer.append(data)
            var lines: [Data] = []
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                lines.append(state.buffer[state.buffer.startIndex..<newline])
                state.buffer.removeSubrange(state.buffer.startIndex...newline)
            }
            return lines
        }
        for line in lines { handle(line: line) }
    }

    private func handle(line: Data) {
        guard
            !line.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["method"] == nil, // notification or server→client request
            let id = (object["id"] as? NSNumber)?.intValue
        else { return }
        guard let continuation = state.withLock({ $0.pending.removeValue(forKey: id) }) else { return }
        if let error = object["error"] as? [String: Any] {
            continuation.resume(throwing: JSONRPCError(
                code: (error["code"] as? NSNumber)?.intValue ?? 0,
                message: error["message"] as? String ?? ""
            ))
        } else if let result = object["result"] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: JSONRPCSessionError.malformedResponse)
        }
    }

    private func failAll(exitCode: Int32) {
        let pending = state.withLock { state in
            state.exited = exitCode
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for continuation in pending { continuation.resume(throwing: JSONRPCSessionError.processExited(exitCode)) }
    }

    private func expire() {
        let pending = state.withLock { state in
            state.timedOut = true
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for continuation in pending { continuation.resume(throwing: JSONRPCSessionError.timedOut) }
        terminate(process)
    }
}
