import Foundation

/// Watches one config file for changes made by others (C-7). It watches both the file (in-place
/// writes) and its folder (atomic rename-over writes replace the file's inode), and re-arms after
/// each event. Events are coalesced; the handler runs on the main actor.
@MainActor
final class ConfigFileWatcher {
    private let path: String
    private let onChange: @MainActor () -> Void
    private var sources: [any DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
        arm()
    }

    func stop() {
        pending?.cancel()
        for source in sources { source.cancel() }
        sources = []
    }

    private func arm() {
        for source in sources { source.cancel() }
        sources = []
        // Resolve symlinks so we watch the file that actually changes.
        let resolved = (try? SafeFileWriter.realpath(path)) ?? path
        for (target, mask) in [(resolved, DispatchSource.FileSystemEvent([.write, .delete, .rename, .extend, .attrib])),
                               ((resolved as NSString).deletingLastPathComponent, .write)] {
            let fd = open(target, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.schedule() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.arm()
            self.onChange()
        }
    }
}
