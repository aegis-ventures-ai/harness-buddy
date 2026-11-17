import HarnessButlerKit
import SwiftUI

/// A text field that reports its value when the user presses Return or leaves the field,
/// not on every keystroke (each commit becomes one staged config edit).
struct CommittingTextField: View {
    let title: String
    let value: String
    var prompt: String = ""
    var monospaced = true
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft, prompt: Text(prompt))
            .font(monospaced ? .body.monospaced() : .body)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { send() } }
            .onSubmit(send)
    }

    private func send() {
        if draft != value { commit(draft) }
    }
}

/// An ordered list of strings (permission rules, command arguments).
struct StringListEditor: View {
    let items: [String]
    var placeholder = "Add…"
    let onChange: ([String]) -> Void
    @State private var newItem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text(item).font(.body.monospaced()).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button {
                        var copy = items
                        copy.remove(at: index)
                        onChange(copy)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                }
            }
            HStack {
                TextField("New item", text: $newItem, prompt: Text(placeholder))
                    .font(.body.monospaced())
                    .onSubmit(add)
                Button("Add", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let trimmed = newItem.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onChange(items + [trimmed])
        newItem = ""
    }
}

/// Key/value rows (env vars, HTTP headers). Values are masked by default because they often hold tokens.
struct KeyValueEditor: View {
    let items: [KeyValue]
    var keyPrompt = "NAME"
    let onChange: ([KeyValue]) -> Void
    @State private var reveal = false
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !items.isEmpty {
                Toggle("Show values", isOn: $reveal).toggleStyle(.checkbox).font(.caption)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    Text(item.key).font(.body.monospaced()).frame(minWidth: 120, alignment: .leading)
                    Text("=").foregroundStyle(.tertiary)
                    if reveal {
                        CommittingTextField(title: "Value", value: item.value) { value in
                            var copy = items
                            copy[index].value = value
                            onChange(copy)
                        }
                        .textFieldStyle(.roundedBorder)
                    } else {
                        Text(item.value.isEmpty ? "" : String(repeating: "•", count: min(12, item.value.count)))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button {
                        var copy = items
                        copy.remove(at: index)
                        onChange(copy)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove \(item.key)")
                }
            }
            HStack(spacing: 6) {
                TextField("Name", text: $newKey, prompt: Text(keyPrompt)).font(.body.monospaced()).frame(minWidth: 120)
                Text("=").foregroundStyle(.tertiary)
                SecureField("Value", text: $newValue, prompt: Text("value"))
                    .onSubmit(add)
                Button("Add", action: add).disabled(!canAdd)
            }
            if items.contains(where: { $0.key == newKey }) {
                Text("\(newKey) is already set; edit it above.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var canAdd: Bool {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && !items.contains { $0.key == key }
    }

    private func add() {
        guard canAdd else { return }
        onChange(items + [KeyValue(key: newKey.trimmingCharacters(in: .whitespaces), value: newValue)])
        newKey = ""
        newValue = ""
    }
}

extension ConfigFileRef {
    var abbreviatedPath: String { PathFormatting.abbreviate(path) }
}
