import AppKit
import HarnessButlerKit
import SwiftUI

/// C-4: edit the file as text, validated as you type (TOML 1.0-strict, strict JSON).
struct RawConfigView: View {
    let profile: ConfigProfile
    let config: ConfigStore

    var body: some View {
        let editable = config.files(of: profile).filter(\.kind.allowsRawEditing)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(editable) { ref in
                if let state = config.state(ref) {
                    HStack {
                        Text(ref.abbreviatedPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        if let error = state.rawError {
                            Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(Theme.bad).lineLimit(2)
                        } else if state.isRawEdited {
                            Label("valid \(ref.kind.format == .toml ? "TOML 1.0" : "JSON")", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.ok)
                        }
                    }
                    TextEditor(text: Binding(
                        get: { state.rawText ?? state.edited.text },
                        set: { config.setRawText($0, in: ref) }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(state.rawError == nil ? Color.secondary.opacity(0.2) : Theme.bad))
                }
            }
            if config.files(of: profile).contains(where: { !$0.kind.allowsRawEditing }) {
                Text(".claude.json isn't shown here: it holds account and session data. Its MCP servers are on the MCP servers tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

/// C-5: backups taken before each save, with one-click restore.
struct ConfigBackupsView: View {
    let profile: ConfigProfile
    let config: ConfigStore
    @State private var restoring: (ConfigFileRef, ConfigBackup)?

    var body: some View {
        Form {
            ForEach(config.files(of: profile)) { ref in
                let list = config.backupList(ref)
                Section {
                    if list.isEmpty { Text("No backups yet.").foregroundStyle(.secondary) }
                    ForEach(list) { backup in
                        HStack {
                            Text(backup.date.formatted(date: .abbreviated, time: .standard))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(backup.size), countStyle: .file)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore…") { restoring = (ref, backup) }
                                .disabled(config.state(ref)?.hasChanges == true || config.saving.contains(ref.id))
                        }
                    }
                } header: {
                    HStack {
                        Text(ref.abbreviatedPath)
                        Spacer()
                        if !list.isEmpty {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([list[0].url]) }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                } footer: {
                    Text(ref.kind.scopedKeys == nil
                         ? "Restoring backs up the current file first. Backups are kept for 30 days and readable only by you."
                         : "Restoring puts back only mcpServers, so newer Claude Code state in .claude.json isn't rolled back.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("Restore") {
                if let (ref, backup) = restoring { Task { await config.restore(backup, to: ref) } }
                restoring = nil
            }
        } message: {
            if let (ref, backup) = restoring {
                Text("\(ref.abbreviatedPath) will be replaced with the version from \(backup.date.formatted(date: .abbreviated, time: .shortened)). The current version is backed up first.")
            }
        }
    }
}
