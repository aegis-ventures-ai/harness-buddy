import AppKit
import HarnessButlerKit
import SwiftUI

enum ConfigTab: String, CaseIterable, Identifiable {
    case general = "General"
    case permissions = "Permissions"
    case mcp = "MCP servers"
    case env = "Env"
    case extensions = "Extensions"
    case raw = "Raw"
    case backups = "Backups"
    var id: String { rawValue }

    static func tabs(for harness: Harness) -> [ConfigTab] {
        // Codex and Grok keep approval/sandbox modes on General; only Claude has rule lists.
        harness == .claude ? allCases : allCases.filter { $0 != .permissions }
    }
}

/// C-1: one harness profile's config, with curated tabs, raw editing and backups.
struct ProfileConfigView: View {
    let profile: ConfigProfile
    let config: ConfigStore
    let harnesses: HarnessStore
    @State private var tab: ConfigTab = Self.initialTab

    private static var initialTab: ConfigTab {
        #if DEBUG
        // `--config-tab mcp|env|extensions|raw|backups|permissions` (UI checks).
        if let index = CommandLine.arguments.firstIndex(of: "--config-tab"),
           let name = CommandLine.arguments.dropFirst(index + 1).first,
           let tab = ConfigTab.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(name.lowercased()) }) { return tab }
        #endif
        return .general
    }
    @State private var reviewing: ConfigFileRef?

    var body: some View {
        let files = config.files(of: profile)
        VStack(alignment: .leading, spacing: 0) {
            header(files)
            Picker("Section", selection: $tab) {
                ForEach(ConfigTab.tabs(for: profile.harness)) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ForEach(files) { ref in conflictBanner(ref) }

            Group {
                switch tab {
                case .general: ConfigGeneralView(profile: profile, config: config)
                case .permissions: ConfigPermissionsView(profile: profile, config: config)
                case .mcp: MCPServersView(profile: profile, config: config)
                case .env: ConfigEnvView(profile: profile, config: config)
                case .extensions: ExtensionsView(profile: profile, config: config)
                case .raw: RawConfigView(profile: profile, config: config)
                case .backups: ConfigBackupsView(profile: profile, config: config)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            ForEach(files) { ref in pendingBar(ref) }
        }
        .onAppear {
            config.open(profile)
        }
        #if DEBUG
        .task {
            // `--demo-review`: open the diff sheet for the first file with pending changes (UI checks).
            guard CommandLine.arguments.contains("--demo-review") else { return }
            try? await Task.sleep(for: .seconds(1))
            reviewing = files.first { config.state($0)?.hasChanges == true }
        }
        #endif
        .onChange(of: profile) { _, new in config.open(new) }
        .sheet(item: $reviewing) { ref in
            DiffReviewSheet(ref: ref, config: config)
        }
    }

    private func header(_ files: [ConfigFileRef]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                HarnessAvatar(harness: profile.harness, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.displayName == profile.harness.displayName
                             ? profile.harness.displayName
                             : "\(profile.harness.displayName) · \(profile.displayName)")
                            .font(.title3.weight(.semibold))
                        if let version = harnesses.status(for: profile.harness).installation?.version {
                            Text(version.description).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Text(files.map { $0.abbreviatedPath + ($0.kind.scopedKeys.map { " (\($0.joined(separator: ".")))" } ?? "") }
                        .joined(separator: " · ") + " · watched for outside changes")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Reveal in Finder") {
                    let existing = files.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
                    if existing.isEmpty { NSWorkspace.shared.open(profile.home) } else { NSWorkspace.shared.activateFileViewerSelecting(existing) }
                }
            }
            ForEach(files) { ref in
                if let state = config.state(ref), state.isHardLinked {
                    Label("\(ref.kind.fileName) has other hard links; saving replaces the file and breaks them.", systemImage: "link")
                        .font(.caption).foregroundStyle(Theme.warn)
                } else if let state = config.state(ref), state.isSymlink {
                    Label("\(ref.kind.fileName) is a symlink; saves go to the file it points to and the link is kept.", systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }

    /// C-7: the file changed on disk while there were unsaved changes.
    @ViewBuilder private func conflictBanner(_ ref: ConfigFileRef) -> some View {
        if let state = config.state(ref), state.externalChange {
            HStack {
                Label("\(ref.kind.fileName) changed on disk while you had unsaved changes.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warn)
                Spacer()
                Button("Reload, discarding mine") { config.reload(ref, keepChanges: false) }
                if state.canMerge {
                    Button("Re-apply my changes") { config.reload(ref, keepChanges: true) }
                        .help("Load the new file and apply your edits on top of it")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warn.opacity(0.12)))
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private func pendingBar(_ ref: ConfigFileRef) -> some View {
        let state = config.state(ref)
        let error = config.errors[ref.id]
        if state?.hasChanges == true || error != nil || config.lastSaved[ref.id] != nil {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                if let error {
                    HStack {
                        Label(error, systemImage: "xmark.octagon").foregroundStyle(Theme.bad).font(.callout).lineLimit(3)
                        Spacer()
                        Button("Dismiss") { config.clearError(ref) }.buttonStyle(.borderless)
                    }
                }
                if let state, state.hasChanges {
                    HStack(spacing: 10) {
                        Text("Unsaved changes").foregroundStyle(Theme.warn).font(.callout.weight(.medium))
                        if let preview = config.preview(ref) {
                            Text("+\(preview.added)").foregroundStyle(Theme.ok).font(.callout.monospaced())
                            Text("−\(preview.removed)").foregroundStyle(Theme.bad).font(.callout.monospaced())
                        }
                        Text("\(ref.abbreviatedPath) · a backup is saved before writing")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Discard") { config.discard(ref) }
                        Button("Review & Save…") { reviewing = ref }
                            .buttonStyle(.borderedProminent)
                            .disabled(!state.canSave)
                            .keyboardShortcut("s", modifiers: .command)
                    }
                } else if let saved = config.lastSaved[ref.id] {
                    Label("Saved \(ref.kind.fileName) \(saved.date.formatted(.relative(presentation: .named)))" + (saved.backup == nil ? "" : " · backup kept for 30 days"),
                          systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(Theme.ok)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }
}

/// C-5: the diff to approve before writing.
struct DiffReviewSheet: View {
    let ref: ConfigFileRef
    let config: ConfigStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review changes to \(ref.abbreviatedPath)").font(.headline)
            if let preview = config.preview(ref) {
                HStack(spacing: 12) {
                    Text("+\(preview.added)").foregroundStyle(Theme.ok)
                    Text("−\(preview.removed)").foregroundStyle(Theme.bad)
                    if let note = preview.scopeNote { Text(note).foregroundStyle(.secondary) }
                }
                .font(.caption)
                DiffView(hunks: preview.hunks)
            }
            Text("Before writing, the current file is backed up (kept 30 days). The write is atomic and is checked by reading it back. If the file changed since it was loaded, nothing is written.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = config.errors[ref.id] {
                Text(error).font(.caption).foregroundStyle(Theme.bad)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { if await config.save(ref) { dismiss() } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(config.state(ref)?.canSave != true || config.saving.contains(ref.id))
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 480)
    }
}

struct DiffView: View {
    let hunks: [DiffHunk]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunks) { hunk in
                    Text(hunk.header).foregroundStyle(Theme.accent).padding(.vertical, 2)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        Text(prefix(line) + line.text)
                            .foregroundStyle(color(line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line))
                    }
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private func prefix(_ line: DiffLine) -> String {
        switch line.kind {
        case .context: "  "
        case .added: "+ "
        case .removed: "- "
        }
    }

    private func color(_ line: DiffLine) -> Color {
        switch line.kind {
        case .context: .secondary
        case .added: Theme.ok
        case .removed: Theme.bad
        }
    }

    private func background(_ line: DiffLine) -> Color {
        switch line.kind {
        case .context: .clear
        case .added: Theme.ok.opacity(0.1)
        case .removed: Theme.bad.opacity(0.1)
        }
    }
}
