import CryptoKit
import Foundation

public struct ConfigBackup: Hashable, Sendable, Identifiable {
    public var url: URL
    public var date: Date
    public var size: Int
    public var id: String { url.path(percentEncoded: false) }
}

/// Backups written before every config save (C-5, C-12): mode 0600 files in 0700 directories, one
/// directory per config file, kept for 30 days.
public struct ConfigBackupStore: Sendable {
    public var root: URL
    public static let retention: TimeInterval = 30 * 24 * 3600

    public init(root: URL) {
        self.root = root
    }

    public static var standard: ConfigBackupStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ConfigBackupStore(root: support.appending(path: "HarnessButler/Backups", directoryHint: .isDirectory))
    }

    /// `<root>/<kind>-<hash of the path>`, so two profiles' `config.toml` never share a folder.
    public func directory(for file: ConfigFileRef) -> URL {
        let hash = SHA256.hash(data: Data(file.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "\(file.kind.rawValue)-\(hash)", directoryHint: .isDirectory)
    }

    /// Create the folders with mode 0700 (including the app's support folder).
    func prepare(for file: ConfigFileRef) throws {
        let manager = FileManager.default
        for url in [root.deletingLastPathComponent(), root, directory(for: file)] {
            if !manager.fileExists(atPath: url.path(percentEncoded: false)) {
                try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    /// Newest first.
    public func list(for file: ConfigFileRef) -> [ConfigBackup] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory(for: file), includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "bak" }.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return ConfigBackup(url: url, date: values?.creationDate ?? .distantPast, size: values?.fileSize ?? 0)
        }
        .sorted { $0.date > $1.date }
    }

    public func read(_ backup: ConfigBackup) throws -> [UInt8] {
        guard let data = FileManager.default.contents(atPath: backup.url.path(percentEncoded: false)) else {
            throw ConfigEditError("Couldn't read the backup")
        }
        return [UInt8](data)
    }

    /// Delete backups older than the retention period.
    @discardableResult
    public func prune(for file: ConfigFileRef, now: Date = .now) -> Int {
        var removed = 0
        for backup in list(for: file) where now.timeIntervalSince(backup.date) > Self.retention {
            if (try? FileManager.default.removeItem(at: backup.url)) != nil { removed += 1 }
        }
        return removed
    }
}
