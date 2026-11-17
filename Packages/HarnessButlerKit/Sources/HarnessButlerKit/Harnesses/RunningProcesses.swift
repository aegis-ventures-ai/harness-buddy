import Darwin
import Foundation

/// H-7: counts running processes of a harness binary, so the UI can warn that open sessions
/// keep running the old version until restarted. Reads only executable paths.
public enum RunningProcesses {
    /// Processes whose executable is `binary` (symlinks resolved), excluding `excluding` (our own children).
    public static func count(executable binary: URL, excluding: Set<pid_t> = []) -> Int {
        let target = binary.resolvingSymlinksInPath().path(percentEncoded: false)
        return allPIDs().filter { pid in
            pid > 0 && pid != getpid() && !excluding.contains(pid) && executablePath(of: pid) == target
        }.count
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
