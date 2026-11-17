import Foundation
import Synchronization

/// Tracks every child process the app spawns so none outlive it (NFR: child processes).
public final class ChildProcessRegistry: Sendable {
    public static let shared = ChildProcessRegistry()

    private let processes = Mutex<[ObjectIdentifier: Process]>([:])

    func register(_ process: Process) {
        processes.withLock { $0[ObjectIdentifier(process)] = process }
    }

    func unregister(_ process: Process) {
        _ = processes.withLock { $0.removeValue(forKey: ObjectIdentifier(process)) }
    }

    /// Kill all live children. Call from `applicationWillTerminate`.
    public func terminateAll() {
        let live = processes.withLock { dict -> [Process] in
            defer { dict.removeAll() }
            return Array(dict.values)
        }
        for process in live where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    var liveCount: Int { processes.withLock { $0.count } }

    /// PIDs of our own live children (excluded from "sessions running" counts).
    public var pids: Set<pid_t> {
        processes.withLock { Set($0.values.map(\.processIdentifier)) }
    }
}

/// SIGTERM, then SIGKILL after a grace period if the process is still running.
func terminate(_ process: Process, grace: Duration = .seconds(2)) {
    guard process.isRunning else { return }
    process.terminate()
    let pid = process.processIdentifier
    Task.detached {
        try? await Task.sleep(for: grace)
        if process.isRunning { kill(pid, SIGKILL) }
    }
}
