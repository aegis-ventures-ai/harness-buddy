import Foundation
import Synchronization

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
}

/// Runs a short-lived command to completion with a hard timeout.
public enum ProcessRunner {
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = OutputBuffer(), stderrBuffer = OutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdoutBuffer.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderrBuffer.append($0.availableData) }

        let timedOut = Mutex(false)
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                ChildProcessRegistry.shared.unregister(finished)
                continuation.resume(returning: ProcessResult(
                    exitCode: finished.terminationStatus,
                    stdout: stdoutBuffer.data,
                    stderr: stderrBuffer.data,
                    timedOut: timedOut.withLock { $0 }
                ))
            }
            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                return
            }
            ChildProcessRegistry.shared.register(process)
            Task.detached {
                try? await Task.sleep(for: timeout)
                if process.isRunning {
                    timedOut.withLock { $0 = true }
                    terminate(process)
                }
            }
        }
    }
}

final class OutputBuffer: Sendable {
    private let storage = Mutex(Data())
    func append(_ data: Data) { if !data.isEmpty { storage.withLock { $0.append(data) } } }
    var data: Data { storage.withLock { $0 } }
}
