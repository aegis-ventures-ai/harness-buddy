import Foundation
import Synchronization

public struct StreamingResult: Sendable, Equatable {
    public var exitCode: Int32
    public var timedOut: Bool
    public var cancelled: Bool
}

/// Runs a long command (an updater) and streams its combined stdout/stderr as it arrives.
/// Cancelling the calling task terminates the process.
public enum StreamingProcess {
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeout: Duration = .seconds(600),
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> StreamingResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let decoder = UTF8ChunkDecoder()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = decoder.decode(data) { onOutput(text) }
        }

        let flags = Mutex((timedOut: false, cancelled: false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let state = flags.withLock { $0 }
                    // An updater that finished on its own may leave a finisher running, as in a
                    // terminal; one we stopped (timeout or cancel) takes its helpers with it.
                    if state.timedOut || state.cancelled { reapGroup(of: finished.processIdentifier) }
                    // Bounded: a descendant holding the pipe open would otherwise block this forever.
                    let rest = drainPipe(pipe.fileHandleForReading, timeout: 2)
                    if !rest.data.isEmpty, let text = decoder.decode(rest.data) { onOutput(text) }
                    if let tail = decoder.flush() { onOutput(tail) }
                    ChildProcessRegistry.shared.unregister(finished)
                    continuation.resume(returning: StreamingResult(
                        exitCode: finished.terminationStatus, timedOut: state.timedOut, cancelled: state.cancelled
                    ))
                }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                    return
                }
                ChildProcessRegistry.shared.register(process)
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning {
                        flags.withLock { $0.timedOut = true }
                        terminate(process)
                    }
                }
            }
        } onCancel: {
            flags.withLock { $0.cancelled = true }
            terminate(process)
        }
    }
}

/// Decodes UTF-8 across chunk boundaries so multi-byte characters (progress-bar blocks) aren't split.
final class UTF8ChunkDecoder: Sendable {
    private let pending = Mutex(Data())

    func decode(_ data: Data) -> String? {
        pending.withLock { buffer -> String? in
            buffer.append(data)
            // Hold back an incomplete trailing sequence (at most 3 bytes).
            var cut = buffer.endIndex
            for back in 1...min(3, buffer.count) {
                let byte = buffer[buffer.endIndex - back]
                if byte & 0xC0 == 0x80 { continue } // continuation byte
                let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                if needed > back { cut = buffer.endIndex - back }
                break
            }
            let ready = buffer[buffer.startIndex..<cut]
            let text = String(decoding: ready, as: UTF8.self)
            buffer = Data(buffer[cut...])
            return text.isEmpty ? nil : text
        }
    }

    func flush() -> String? {
        pending.withLock { buffer -> String? in
            defer { buffer = Data() }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
    }
}
