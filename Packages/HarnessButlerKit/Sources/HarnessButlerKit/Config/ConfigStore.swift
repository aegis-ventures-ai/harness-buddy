import Darwin
import Foundation
import Observation

/// What the app holds for one open config file.
public struct ConfigFileState: Sendable {
    public var ref: ConfigFileRef
    /// The file as loaded; `nil` while it doesn't exist (saving creates it).
    public var loaded: LoadedFile?
    /// The document as on disk.
    public var original: ConfigDocument
    /// The document with pending changes applied.
    public var edited: ConfigDocument
    /// Pending changes as key-scoped operations, re-appliable to fresh bytes.
    public var operations: [ConfigOperation] = []
    /// The raw editor buffer when the file was edited as text (may be invalid; see `rawError`).
    public var rawText: String?
    public var rawError: String?
    /// The file changed on disk while changes were pending (C-7). Saving is blocked until resolved.
    public var externalChange = false
    public var isSymlink = false
    /// Saving replaces the file, which breaks hard links.
    public var isHardLinked = false

    public var exists: Bool { loaded != nil }
    public var isRawEdited: Bool { rawText != nil }
    public var hasChanges: Bool {
        if let rawText { return Array(rawText.utf8) != original.bytes }
        return edited.bytes != original.bytes
    }
    public var canSave: Bool { hasChanges && rawError == nil && !externalChange }

    /// Re-apply pending operations on a fresh document. Fails when they no longer apply.
    public var canMerge: Bool { !isRawEdited && !operations.isEmpty }
}

/// The diff shown before saving.
public struct ConfigPreview: Sendable {
    public var hunks: [DiffHunk]
    public var added: Int
    public var removed: Int
    /// For `.claude.json` only the `mcpServers` value is diffed, never the rest of the file.
    public var scopeNote: String?
}

/// Loads, edits and safely saves harness config files (C-1…C-7).
@MainActor
@Observable
public final class ConfigStore {
    public private(set) var profiles: [ConfigProfile] = []
    public private(set) var files: [String: ConfigFileState] = [:]
    public private(set) var errors: [String: String] = [:]
    public private(set) var saving: Set<String> = []
    /// The last successful save per file (for a confirmation line).
    public private(set) var lastSaved: [String: (date: Date, backup: String?)] = [:]

    public let backups: ConfigBackupStore
    @ObservationIgnored private let homeDirectory: URL
    @ObservationIgnored private var watchers: [String: ConfigFileWatcher] = [:]

    public init(backups: ConfigBackupStore = .standard, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.backups = backups
        self.homeDirectory = homeDirectory
    }

    public func setSubscriptions(_ subscriptions: [Subscription]) {
        profiles = ConfigProfile.profiles(for: subscriptions, homeDirectory: homeDirectory)
    }

    public func files(of profile: ConfigProfile) -> [ConfigFileRef] { profile.files(homeDirectory: homeDirectory) }

    public func state(_ ref: ConfigFileRef) -> ConfigFileState? { files[ref.id] }

    /// The document with pending changes (`nil` until loaded with `open` or `load`).
    public func document(_ ref: ConfigFileRef) -> ConfigDocument? { files[ref.id]?.edited }

    public var pendingFiles: [ConfigFileRef] { files.values.filter(\.hasChanges).map(\.ref) }

    // MARK: Loading and watching

    /// Load the profile's files and watch them for outside changes.
    public func open(_ profile: ConfigProfile) {
        for ref in files(of: profile) {
            if files[ref.id] == nil { load(ref) }
            if watchers[ref.id] == nil {
                watchers[ref.id] = ConfigFileWatcher(path: ref.path) { [weak self] in self?.diskChanged(ref) }
            }
        }
    }

    /// Stop watching (the settings window closed). Files without pending changes are dropped.
    public func closeAll() {
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        files = files.filter(\.value.hasChanges)
    }

    public func load(_ ref: ConfigFileRef) {
        do {
            files[ref.id] = try Self.read(ref)
            errors[ref.id] = nil
        } catch {
            errors[ref.id] = "\(error)"
        }
    }

    public nonisolated static func read(_ ref: ConfigFileRef) throws -> ConfigFileState {
        guard FileManager.default.fileExists(atPath: ref.path) else {
            let empty = ConfigDocument.empty(ref.kind.format)
            return ConfigFileState(ref: ref, loaded: nil, original: empty, edited: empty)
        }
        let loaded = try SafeFileWriter(backupDirectory: URL(filePath: "/dev/null")).load(ref.path)
        let document = try ConfigDocument(format: ref.kind.format, bytes: loaded.bytes)
        var state = ConfigFileState(ref: ref, loaded: loaded, original: document, edited: document)
        var link = stat(), target = stat()
        state.isSymlink = lstat(ref.path, &link) == 0 && (link.st_mode & S_IFMT) == S_IFLNK
        state.isHardLinked = stat(ref.path, &target) == 0 && target.st_nlink > 1
        return state
    }

    private func diskChanged(_ ref: ConfigFileRef) {
        guard let state = files[ref.id], !saving.contains(ref.id) else { return }
        guard let fresh = try? Self.read(ref) else {
            if !state.hasChanges { load(ref) } else { files[ref.id]?.externalChange = true }
            return
        }
        if fresh.loaded?.snapshot == state.loaded?.snapshot { return } // our own write, or nothing changed

        if let scope = ref.kind.scopedKeys, fresh.original.value(at: scope) == state.original.value(at: scope) {
            // `.claude.json` is rewritten by the CLI all the time. If our keys are untouched, rebase quietly.
            var rebased = fresh
            rebased.operations = state.operations
            if (try? rebased.edited.apply(state.operations)) != nil {
                files[ref.id] = rebased
                return
            }
        }
        if !state.hasChanges {
            files[ref.id] = fresh
        } else {
            files[ref.id]?.externalChange = true
        }
    }

    // MARK: Editing

    /// Apply edits from a form. They are kept as operations so they can be merged with outside changes.
    public func stage(_ operations: [ConfigOperation], in ref: ConfigFileRef) throws {
        if files[ref.id] == nil { load(ref) }
        guard var state = files[ref.id] else { throw ConfigEditError(errors[ref.id] ?? "Couldn't read \(ref.path)") }
        if state.isRawEdited {
            throw ConfigEditError("This file has unsaved edits in the Raw tab. Save or discard them first.")
        }
        try state.edited.apply(operations)
        state.operations += operations
        files[ref.id] = state
        errors[ref.id] = nil
    }

    /// `stage` for UI callers: a failure is shown as the file's error instead of thrown.
    public func apply(_ operations: [ConfigOperation], in ref: ConfigFileRef) {
        guard !operations.isEmpty else { return }
        do { try stage(operations, in: ref) } catch { errors[ref.id] = "\(error)" }
    }

    public func clearError(_ ref: ConfigFileRef) { errors[ref.id] = nil }

    /// Replace the whole file's text (C-4). Invalid text is kept in the buffer with an error and can't be saved.
    public func setRawText(_ text: String, in ref: ConfigFileRef) {
        guard ref.kind.allowsRawEditing, var state = files[ref.id] else { return }
        if text == state.original.text, state.operations.isEmpty {
            state.rawText = nil
            state.rawError = nil
            state.edited = state.original
        } else {
            state.rawText = text
            do {
                state.edited = try ConfigDocument(format: ref.kind.format, bytes: Array(text.utf8))
                state.rawError = nil
            } catch {
                state.rawError = "\(error)"
            }
            state.operations = []
        }
        files[ref.id] = state
    }

    public func discard(_ ref: ConfigFileRef) {
        guard var state = files[ref.id] else { return }
        state.edited = state.original
        state.operations = []
        state.rawText = nil
        state.rawError = nil
        state.externalChange = false
        files[ref.id] = state
        errors[ref.id] = nil
    }

    /// After an outside change: reload from disk, optionally re-applying pending form edits.
    public func reload(_ ref: ConfigFileRef, keepChanges: Bool) {
        guard let state = files[ref.id] else { return load(ref) }
        do {
            var fresh = try Self.read(ref)
            if keepChanges, state.canMerge {
                try fresh.edited.apply(state.operations)
                fresh.operations = state.operations
            }
            files[ref.id] = fresh
            errors[ref.id] = nil
        } catch {
            errors[ref.id] = "Couldn't re-apply your changes to the new file: \(error)"
        }
    }

    // MARK: Preview

    public func preview(_ ref: ConfigFileRef) -> ConfigPreview? {
        guard let state = files[ref.id] else { return nil }
        let old: String, new: String
        var note: String?
        if let scope = ref.kind.scopedKeys {
            old = Self.render(state.original.value(at: scope), key: scope.joined(separator: "."))
            new = Self.render(state.edited.value(at: scope), key: scope.joined(separator: "."))
            note = "Only \(scope.joined(separator: ".")) is shown and written; the rest of \(ref.kind.fileName) isn't touched."
        } else {
            old = state.original.text
            new = state.rawText ?? state.edited.text
        }
        let hunks = LineDiff.hunks(old: old, new: new)
        let counts = LineDiff.counts(hunks)
        return ConfigPreview(hunks: hunks, added: counts.added, removed: counts.removed, scopeNote: note)
    }

    private static func render(_ value: ConfigValue?, key: String) -> String {
        guard let value else { return "" }
        return "\"\(key)\": " + JSONRender(unit: "  ", newline: "\n").render(JSONValue(value), indent: "") + "\n"
    }

    // MARK: Saving (C-5)

    /// Validate → check for outside changes → back up → atomic write → verify. Returns whether it saved.
    @discardableResult
    public func save(_ ref: ConfigFileRef) async -> Bool {
        guard let state = files[ref.id], state.canSave, !saving.contains(ref.id) else { return false }
        saving.insert(ref.id)
        defer { saving.remove(ref.id) }
        let backups = backups
        do {
            let backup = try await Task.detached { try Self.write(state, backups: backups) }.value
            files[ref.id] = try Self.read(ref)
            errors[ref.id] = nil
            lastSaved[ref.id] = (.now, backup)
            backups.prune(for: ref)
            return true
        } catch SafeWriteError.externalChange {
            files[ref.id]?.externalChange = true
            errors[ref.id] = "\(ref.kind.fileName) changed on disk since it was loaded. Nothing was written."
        } catch {
            errors[ref.id] = Self.message(for: error)
        }
        return false
    }

    /// Returns the backup path (nil when the file was created).
    nonisolated static func write(_ state: ConfigFileState, backups: ConfigBackupStore) throws -> String? {
        let ref = state.ref
        try backups.prepare(for: ref)
        let writer = SafeFileWriter(backupDirectory: backups.directory(for: ref))
        let format = ref.kind.format
        let validate: ([UInt8]) throws -> Void = { _ = try ConfigDocument(format: format, bytes: $0) }

        if let scope = ref.kind.scopedKeys {
            // `.claude.json`: take the CLI's own lock, re-read under it, and re-apply our operations
            // to whatever is there now, as long as our keys haven't changed.
            let lock = ref.lockPath!
            let original = state.original.value(at: scope)
            let operations = state.operations
            if state.loaded == nil, !FileManager.default.fileExists(atPath: ref.path) {
                return try writer.withLock(lock) { try create(ref, bytes: state.edited.bytes, validate: validate); return nil }
            }
            return try writer.withLock(lock) {
                try writer.update(ref.path, validate: validate) { bytes in
                    var fresh = try ConfigDocument(format: format, bytes: bytes)
                    guard fresh.value(at: scope) == original else { throw SafeWriteError.externalChange(current: nil) }
                    try fresh.apply(operations)
                    return fresh.bytes
                }.backupPath
            }
        }

        guard let loaded = state.loaded else {
            try create(ref, bytes: state.edited.bytes, validate: validate)
            return nil
        }
        let bytes = state.rawText.map { Array($0.utf8) } ?? state.edited.bytes
        return try writer.write(bytes, over: loaded, validate: validate).backupPath
    }

    /// Create a missing file (mode 0600). Fails if it appeared meanwhile.
    nonisolated static func create(_ ref: ConfigFileRef, bytes: [UInt8], validate: ([UInt8]) throws -> Void) throws {
        try validate(bytes)
        let folder = ref.url.deletingLastPathComponent().path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: folder) else { throw ConfigEditError("The folder \(folder) doesn't exist.") }
        let fd = Darwin.open(ref.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { throw SafeWriteError.externalChange(current: nil) }
            throw SafeWriteError.posix("create", errno)
        }
        defer { close(fd) }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count, fsync(fd) == 0 else { throw SafeWriteError.posix("write", errno) }
    }

    static func message(for error: Error) -> String {
        switch error {
        case SafeWriteError.invalidContent(let detail): "The new content isn't valid, so nothing was written: \(detail)"
        case SafeWriteError.verifyFailed: "The file didn't read back as written. A backup was saved; check the Backups tab."
        case SafeWriteError.lockTimeout: "Claude Code is holding its lock on .claude.json. Try again in a moment."
        case SafeWriteError.posix(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        default: "\(error)"
        }
    }

    // MARK: Backups

    public func backupList(_ ref: ConfigFileRef) -> [ConfigBackup] { backups.list(for: ref) }

    /// Restore a backup. The current file is itself backed up first. For `.claude.json` only
    /// `mcpServers` is restored, so newer CLI state isn't rolled back.
    @discardableResult
    public func restore(_ backup: ConfigBackup, to ref: ConfigFileRef) async -> Bool {
        guard !saving.contains(ref.id) else { return false }
        if files[ref.id]?.hasChanges == true {
            errors[ref.id] = "Save or discard pending changes before restoring."
            return false
        }
        saving.insert(ref.id)
        defer { saving.remove(ref.id) }
        let backups = backups
        do {
            let bytes = try backups.read(backup)
            let restored = try ConfigDocument(format: ref.kind.format, bytes: bytes)
            try await Task.detached {
                var state = try Self.read(ref)
                if let scope = ref.kind.scopedKeys {
                    let value = restored.value(at: scope)
                    state.operations = [value.map { .set(scope, $0) } ?? .remove(scope)]
                    try state.edited.apply(state.operations)
                } else {
                    state.edited = restored
                    state.rawText = String(decoding: bytes, as: UTF8.self)
                }
                _ = try Self.write(state, backups: backups)
            }.value
            files[ref.id] = try Self.read(ref)
            errors[ref.id] = nil
            lastSaved[ref.id] = (.now, nil)
            return true
        } catch {
            errors[ref.id] = Self.message(for: error)
            return false
        }
    }
}
