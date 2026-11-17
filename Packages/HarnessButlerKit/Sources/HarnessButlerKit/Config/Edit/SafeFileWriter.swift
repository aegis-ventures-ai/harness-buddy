import CryptoKit
import Darwin
import Foundation

/// What we knew about a file when we loaded it.
public struct FileSnapshot: Equatable, Sendable {
    public var resolvedPath: String   // symlinks resolved; this is the file actually written
    public var device: dev_t
    public var inode: ino_t
    public var size: off_t
    public var mtimeSec: Int
    public var mtimeNsec: Int
    public var mode: mode_t           // permission bits only
    public var sha256: String
}

public struct LoadedFile: Sendable {
    public var path: String           // as given (may be a symlink)
    public var bytes: [UInt8]
    public var snapshot: FileSnapshot
}

public enum SafeWriteError: Error, Equatable {
    /// The file changed on disk since it was loaded (C-7). Carries the current state.
    case externalChange(current: FileSnapshot?)
    case invalidContent(String)
    case verifyFailed
    case lockTimeout
    case posix(String, Int32)
}

public struct WriteResult: Sendable {
    public var backupPath: String
    public var snapshot: FileSnapshot
}

/// Safe write protocol:
/// 1. load: read bytes, record stat (dev/inode/size/mtime/mode) and SHA-256;
/// 2. just before writing: re-stat and re-hash, refuse if anything changed;
/// 3. back up the loaded bytes (mode 0600) to the backup directory;
/// 4. write a temp file in the *target's* directory (symlinks resolved), fsync,
///    set the original permission bits, rename over the target, fsync the directory;
/// 5. re-read and verify the bytes and hash.
///
/// Symlinks: the path is resolved with realpath(3) at load, and the rename happens
/// on the resolved target, so `~/.claude/settings.json -> dotfiles/...` keeps its
/// link and the dotfiles copy is updated. (Foundation's `.atomic` write would
/// replace the link with a regular file.) Hard links are broken by any
/// rename-based write; that is accepted and detectable via `st_nlink > 1`.
public struct SafeFileWriter: Sendable {
    public var backupDirectory: URL
    public init(backupDirectory: URL) { self.backupDirectory = backupDirectory }

    public func load(_ path: String) throws -> LoadedFile {
        let resolved = try Self.realpath(path)
        let bytes = try Self.read(resolved)
        return LoadedFile(path: path, bytes: bytes, snapshot: try Self.snapshot(resolved, bytes: bytes))
    }

    /// Writes `newBytes` over a file previously loaded. `validate` runs before
    /// anything touches the disk (e.g. re-parse as TOML/JSON).
    @discardableResult
    public func write(_ newBytes: [UInt8], over loaded: LoadedFile, validate: ([UInt8]) throws -> Void = { _ in }) throws -> WriteResult {
        do { try validate(newBytes) } catch { throw SafeWriteError.invalidContent("\(error)") }
        let target = loaded.snapshot.resolvedPath

        // 2. Change detection, as late as possible.
        let current = try? Self.snapshot(target, bytes: Self.read(target))
        guard current == loaded.snapshot, try Self.realpath(loaded.path) == target else {
            throw SafeWriteError.externalChange(current: current)
        }

        // 3. Backup of exactly what we loaded.
        let backup = try writeBackup(loaded)

        // 4. Atomic replace in the target's directory.
        let dir = (target as NSString).deletingLastPathComponent
        var template = Array("\(dir)/.\((target as NSString).lastPathComponent).hb-XXXXXX".utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw SafeWriteError.posix("mkstemp", errno) }
        let tmp = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var renamed = false
        defer { if !renamed { unlink(tmp) } }
        do {
            defer { close(fd) }
            try newBytes.withUnsafeBytes { buf in
                var off = 0
                while off < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                    if n < 0 { if errno == EINTR { continue }; throw SafeWriteError.posix("write", errno) }
                    off += n
                }
            }
            guard fchmod(fd, loaded.snapshot.mode) == 0 else { throw SafeWriteError.posix("fchmod", errno) }
            guard fsync(fd) == 0 else { throw SafeWriteError.posix("fsync", errno) }
        }
        guard rename(tmp, target) == 0 else { throw SafeWriteError.posix("rename", errno) }
        renamed = true
        let dfd = open(dir, O_RDONLY)
        if dfd >= 0 { fsync(dfd); close(dfd) }

        // 5. Verify.
        let reread = try Self.read(target)
        guard reread == newBytes else { throw SafeWriteError.verifyFailed }
        return WriteResult(backupPath: backup, snapshot: try Self.snapshot(target, bytes: reread))
    }

    /// Load → transform → write, retrying when the file changes underneath (for
    /// `~/.claude.json`, which the CLI rewrites often). Because edits are
    /// key-scoped operations, re-applying them to fresh bytes is a correct merge.
    @discardableResult
    public func update(_ path: String, attempts: Int = 3, validate: ([UInt8]) throws -> Void = { _ in },
                       _ transform: ([UInt8]) throws -> [UInt8]) throws -> WriteResult {
        var lastError: Error = SafeWriteError.verifyFailed
        for _ in 0..<attempts {
            let loaded = try load(path)
            let next = try transform(loaded.bytes)
            do { return try write(next, over: loaded, validate: validate) }
            catch SafeWriteError.externalChange(let c) { lastError = SafeWriteError.externalChange(current: c) }
        }
        throw lastError
    }

    /// Runs `body` while holding a proper-lockfile-compatible lock: a *directory*
    /// at `lockPath` created with mkdir(2). Claude Code 2.1.x takes exactly this
    /// lock (`${configPath}.lock`) around its read-modify-write of `~/.claude.json`,
    /// so holding it closes the check-then-rename race with the CLI.
    /// A lock older than `stale` seconds is treated as abandoned (proper-lockfile
    /// refreshes the mtime of live locks; its default staleness is 10 s).
    public func withLock<T>(_ lockPath: String, timeout: TimeInterval = 5, stale: TimeInterval = 10,
                            _ body: () throws -> T) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while mkdir(lockPath, 0o755) != 0 {
            guard errno == EEXIST else { throw SafeWriteError.posix("mkdir lock", errno) }
            var st = stat()
            if stat(lockPath, &st) == 0, Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) > stale {
                rmdir(lockPath); continue
            }
            guard Date() < deadline else { throw SafeWriteError.lockTimeout }
            usleep(50_000)
        }
        defer { rmdir(lockPath) }
        return try body()
    }

    // MARK: helpers

    private func writeBackup(_ loaded: LoadedFile) throws -> String {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss.SSS"
        let name = (loaded.snapshot.resolvedPath as NSString).lastPathComponent
        let path = backupDirectory.appendingPathComponent("\(name).\(f.string(from: Date())).\(loaded.snapshot.sha256.prefix(8)).bak").path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw SafeWriteError.posix("open backup", errno) }
        defer { close(fd) }
        let ok = loaded.bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == $0.count }
        guard ok, fsync(fd) == 0 else { throw SafeWriteError.posix("write backup", errno) }
        return path
    }

    static func realpath(_ path: String) throws -> String {
        guard let p = Darwin.realpath(path, nil) else { throw SafeWriteError.posix("realpath", errno) }
        defer { free(p) }
        return String(cString: p)
    }

    static func read(_ path: String) throws -> [UInt8] {
        guard let d = FileManager.default.contents(atPath: path) else { throw SafeWriteError.posix("read", errno) }
        return [UInt8](d)
    }

    static func snapshot(_ path: String, bytes: [UInt8]) throws -> FileSnapshot {
        var st = stat()
        guard stat(path, &st) == 0 else { throw SafeWriteError.posix("stat", errno) }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return FileSnapshot(resolvedPath: path, device: st.st_dev, inode: st.st_ino, size: st.st_size,
                            mtimeSec: st.st_mtimespec.tv_sec, mtimeNsec: st.st_mtimespec.tv_nsec,
                            mode: st.st_mode & 0o7777, sha256: hash)
    }
}
