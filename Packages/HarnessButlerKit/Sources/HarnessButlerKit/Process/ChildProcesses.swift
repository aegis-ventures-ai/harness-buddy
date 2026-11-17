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
        for process in live {
            // The whole group: an updater's own children (npm, brew helpers) go too.
            killGroup(of: process.processIdentifier, SIGKILL)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    var liveCount: Int { processes.withLock { $0.count } }

    /// PIDs of our own live children (excluded from "sessions running" counts).
    public var pids: Set<pid_t> {
        processes.withLock { Set($0.values.map(\.processIdentifier)) }
    }
}

/// SIGTERM, then SIGKILL after a grace period, to the process and the processes it started.
func terminate(_ process: Process, grace: Duration = .seconds(2)) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    process.terminate()
    killGroup(of: pid, SIGTERM)
    Task.detached {
        try? await Task.sleep(for: grace)
        // Only while our process is still there: once it has exited (and its pid could be reused),
        // the exit handlers have already cleaned up its group (`reapGroup`).
        guard process.isRunning else { return }
        killGroup(of: pid, SIGKILL)
        kill(pid, SIGKILL)
    }
}

/// Called when a child process has exited: stops anything it started that is still running
/// (helpers, or background processes), so nothing it spawned outlives the read or update.
/// Runs right after the exit is reported, while the group can only hold that child's descendants.
func reapGroup(of pid: pid_t) {
    guard pid > 1, pid != getpgrp(), kill(-pid, 0) == 0 else { return }
    kill(-pid, SIGKILL)
}

/// Foundation's `Process` starts each child as the leader of its own process group (pgid == pid),
/// so signalling `-pid` reaches its descendants as well. Never signals the app's own group.
func killGroup(of pid: pid_t, _ signal: Int32) {
    guard pid > 1, pid != getpgrp() else { return }
    kill(-pid, signal)
}

/// What's left in a pipe once its process has exited, read for at most `timeout`: a descendant that
/// inherited the pipe can keep it open long after the process we started is gone.
/// Returns the data and whether end-of-file was reached.
func drainPipe(_ handle: FileHandle, timeout: TimeInterval = 1) -> (data: Data, eof: Bool) {
    let fd = handle.fileDescriptor
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let deadline = Date.now.addingTimeInterval(timeout)
    while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return (data, false) }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, Int32(max(1, remaining * 1000)))
        if ready < 0 { if errno == EINTR { continue }; return (data, false) }
        if ready == 0 { return (data, false) }
        let count = read(fd, &buffer, buffer.count)
        if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; return (data, false) }
        if count == 0 { return (data, true) }
        data.append(buffer, count: count)
    }
}
