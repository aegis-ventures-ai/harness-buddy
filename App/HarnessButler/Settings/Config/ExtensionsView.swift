import AppKit
import HarnessButlerKit
import SwiftUI

/// C-8: a read-only list of the profile's user-level hooks, plugins and skills.
struct ExtensionsView: View {
    let profile: ConfigProfile
    let config: ConfigStore
    @State private var inventory: ExtensionsInventory?
    @State private var reloads = 0

    /// Re-scan when a config file of this profile changes on disk (or is saved).
    private var refreshKey: String {
        profile.id + "|\(reloads)|" + config.files(of: profile).map { config.state($0)?.loaded?.snapshot.sha256 ?? "-" }.joined(separator: ",")
    }

    var body: some View {
        Form {
            if let inventory {
                hooks(inventory)
                plugins(inventory)
                skills(inventory)
                if !inventory.problems.isEmpty {
                    Section("Couldn't read") {
                        ForEach(inventory.problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warn).font(.callout)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .task(id: refreshKey) {
            let profile = profile
            inventory = await Task.detached(priority: .userInitiated) { ExtensionsScanner.scan(profile) }.value
        }
    }

    // MARK: Hooks

    @ViewBuilder
    private func hooks(_ inventory: ExtensionsInventory) -> some View {
        Section {
            if inventory.hooks.isEmpty { Text("No user-level hooks.").foregroundStyle(.secondary) }
            ForEach(inventory.hooks) { hook in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(hook.event).fontWeight(.medium)
                        if let matcher = hook.matcher { Chip(text: matcher) }
                        Spacer()
                        Text(details(hook)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(hook.target)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(hook.target)
                }
                .contextMenu { revealButton(hook.source) }
            }
        } header: {
            header("Hooks", count: inventory.hooks.count)
        } footer: {
            Text(footer(for: .hooks, sources: Set(inventory.hooks.map(\.source))))
        }
    }

    private func details(_ hook: HookEntry) -> String {
        var parts = [hook.type]
        if let timeout = hook.timeout { parts.append("\(timeout) s timeout") }
        return parts.joined(separator: " · ")
    }

    // MARK: Plugins

    @ViewBuilder
    private func plugins(_ inventory: ExtensionsInventory) -> some View {
        Section {
            if inventory.plugins.isEmpty { Text("No plugins configured.").foregroundStyle(.secondary) }
            ForEach(inventory.plugins) { plugin in
                HStack(spacing: 8) {
                    Text(plugin.name).fontWeight(.medium)
                    if let marketplace = plugin.marketplace { Text(marketplace).foregroundStyle(.secondary) }
                    if let version = plugin.version { Text("v\(version)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    switch plugin.isEnabled {
                    case true?: Text("On").foregroundStyle(Theme.ok)
                    case false?: Text("Off").foregroundStyle(.secondary)
                    case nil: Text("Installed").foregroundStyle(.secondary)
                    }
                }
                .contextMenu { revealButton(plugin.source) }
            }
        } header: {
            header("Plugins", count: inventory.plugins.count)
        } footer: {
            Text(footer(for: .plugins, sources: Set(inventory.plugins.map(\.source))))
        }
    }

    // MARK: Skills

    @ViewBuilder
    private func skills(_ inventory: ExtensionsInventory) -> some View {
        Section {
            if inventory.skills.isEmpty { Text("No user-level skills.").foregroundStyle(.secondary) }
            ForEach(inventory.skills) { skill in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(skill.name).fontWeight(.medium)
                            if skill.origin == "bundled" { Chip(text: "bundled") }
                        }
                        if skill.isBroken {
                            Label(skill.description.isEmpty ? "Link target is missing" : "\(skill.description), not loaded",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(Theme.warn)
                        } else if !skill.description.isEmpty {
                            Text(skill.description).font(.callout).foregroundStyle(.secondary).lineLimit(2).help(skill.description)
                        }
                    }
                    Spacer()
                    if !skill.isBroken || FileManager.default.fileExists(atPath: skill.path) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.path)]) } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
            }
        } header: {
            header("Skills", count: inventory.skills.count)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("From " + Set(inventory.skills.map(\.origin)).sorted().joined(separator: ", ") + ". Skills are folders with a SKILL.md.")
                    .opacity(inventory.skills.isEmpty ? 0 : 1)
                ForEach(inventory.notes, id: \.self) { Text($0) }
            }
        }
    }

    // MARK: Pieces

    private func header(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            if count > 0 { Text("\(count)").foregroundStyle(.secondary) }
            Spacer()
            if title == "Hooks" {
                Button("Reload") { reloads += 1 }.buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private enum Kind { case hooks, plugins }

    private func footer(for kind: Kind, sources: Set<String>) -> String {
        let read = sources.isEmpty ? "" : "From " + sources.sorted().joined(separator: ", ") + ". "
        let how: String = switch (profile.harness, kind) {
        case (.claude, .hooks): "Change hooks with /hooks in Claude Code or in the Raw tab."
        case (.claude, .plugins): "Install and remove plugins with /plugin in Claude Code."
        case (.codex, .hooks): "notify runs after each turn. Change it and hooks.json in a text editor."
        case (.codex, .plugins): "Manage plugins with codex plugin, or turn them off in the Raw tab."
        case (.grok, .hooks): "Change hooks with /hooks in Grok or in the Raw tab."
        case (.grok, .plugins): "Manage plugins with grok plugin or /plugins in Grok."
        }
        return read + how + " This list is read-only."
    }

    @ViewBuilder
    private func revealButton(_ source: String) -> some View {
        Button("Show \((source as NSString).lastPathComponent) in Finder") {
            let path = (source as NSString).expandingTildeInPath
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

private struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }
}
