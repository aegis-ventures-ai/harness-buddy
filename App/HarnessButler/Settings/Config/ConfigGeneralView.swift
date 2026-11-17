import HarnessButlerKit
import SwiftUI

/// C-2: curated settings. Every change is staged as a key-scoped edit; nothing is written until Review & Save.
struct ConfigGeneralView: View {
    let profile: ConfigProfile
    let config: ConfigStore

    var body: some View {
        Form {
            Section {
                ForEach(CuratedSettings.general(profile.harness)) { field in
                    if let ref = profile.file(field.file), let document = config.document(ref) {
                        FieldRow(field: field, value: field.value(in: document)) { config.apply([field.operation(for: $0)], in: ref) }
                    }
                }
            } footer: {
                Text("Empty or \"harness default\" removes the key, so the harness uses its own default. Other keys in the file are left as they are.")
            }
            if profile.harness == .claude, let ref = profile.file(.claudeSettings), let document = config.document(ref) {
                ClaudeEffortSection(document: document) { config.apply($0, in: ref) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FieldRow: View {
    let field: ConfigField
    let value: ConfigValue?
    let commit: (ConfigValue?) -> Void

    var body: some View {
        switch field.kind {
        case .text(let placeholder, let suggestions):
            LabeledContent {
                HStack {
                    CommittingTextField(title: field.label, value: value?.displayText ?? "", prompt: placeholder) { text in
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        commit(trimmed.isEmpty ? nil : .string(trimmed))
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions, id: \.self) { suggestion in Button(suggestion) { commit(.string(suggestion)) } }
                        } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Suggestions")
                    }
                }
            } label: { label }
        case .choice(let choices):
            let current = value?.displayText
            Picker(selection: Binding(get: { current ?? "" }, set: { commit($0.isEmpty ? nil : .string($0)) })) {
                Text("harness default").tag("")
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                if let current, !choices.contains(where: { $0.value == current }) {
                    Text("\(current) (from file)").tag(current)
                }
            } label: { label }
        case .toggle(let defaultValue):
            Toggle(isOn: Binding(get: { value?.bool ?? defaultValue }, set: { commit(.bool($0)) })) { label }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
            Text(field.help).font(.caption).foregroundStyle(.secondary)
            Text(field.path.joined(separator: ".")).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
    }
}

/// Claude Code saves `/effort` per model id; edit the entries it has saved.
private struct ClaudeEffortSection: View {
    let document: ConfigDocument
    let apply: ([ConfigOperation]) -> Void

    var body: some View {
        let efforts = CuratedSettings.claudeEfforts(in: document)
        Section {
            if efforts.isEmpty {
                Text("No per-model effort saved yet. Use /effort in Claude Code to set one.").foregroundStyle(.secondary)
            }
            ForEach(efforts, id: \.model) { entry in
                Picker(selection: Binding(
                    get: { entry.effort ?? "" },
                    set: { new in
                        let path = CuratedSettings.claudeEffortPath(model: entry.model)
                        apply([new.isEmpty ? .remove(path) : .set(path, .string(new))])
                    }
                )) {
                    Text("model default").tag("")
                    ForEach(CuratedSettings.claudeEffortLevels, id: \.self) { Text($0).tag($0) }
                    if let effort = entry.effort, !CuratedSettings.claudeEffortLevels.contains(effort) { Text(effort).tag(effort) }
                } label: {
                    Text(entry.model).font(.body.monospaced())
                }
            }
        } header: {
            Text("Reasoning effort per model")
        } footer: {
            Text("modelSettings.<model>.effortLevel. \"max\" is session-only in Claude Code and isn't saved.")
        }
    }
}

/// Claude Code's allow / ask / deny permission rules.
struct ConfigPermissionsView: View {
    let profile: ConfigProfile
    let config: ConfigStore

    var body: some View {
        Form {
            if let ref = profile.file(.claudeSettings), let document = config.document(ref) {
                ForEach(CuratedSettings.claudePermissionLists, id: \.label) { list in
                    Section {
                        StringListEditor(items: document.value(at: list.path)?.stringArray ?? [], placeholder: "e.g. Bash(npm run test:*)") { items in
                            config.apply([items.isEmpty ? .remove(list.path) : .set(list.path, .strings(items))], in: ref)
                        }
                    } header: {
                        Text(list.label)
                    } footer: {
                        Text(list.path.joined(separator: "."))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Environment variables the harness sets for every session.
struct ConfigEnvView: View {
    let profile: ConfigProfile
    let config: ConfigStore

    var body: some View {
        let location = CuratedSettings.envLocation(profile.harness)
        Form {
            if let ref = profile.file(location.file), let document = config.document(ref) {
                Section {
                    KeyValueEditor(items: document.value(at: location.path)?.stringPairs ?? []) { items in
                        config.apply([items.isEmpty ? .remove(location.path) : .set(location.path, .pairs(items))], in: ref)
                    }
                } footer: {
                    Text(location.help + " Values often hold tokens, so they stay hidden unless you show them; backups are private to your user.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
