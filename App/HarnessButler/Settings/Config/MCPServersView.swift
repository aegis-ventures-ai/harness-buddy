import HarnessButlerKit
import SwiftUI

/// C-3: user-scope MCP servers: list, add, edit, enable/disable, remove.
struct MCPServersView: View {
    let profile: ConfigProfile
    let config: ConfigStore
    @State private var editing: EditTarget?
    @State private var removing: MCPServer?

    struct EditTarget: Identifiable {
        var original: MCPServer?
        var id: String { original?.name ?? "new" }
    }

    var body: some View {
        let mapping = MCPServerMapping.forHarness(profile.harness)
        VStack(alignment: .leading, spacing: 0) {
            if let ref = profile.file(mapping.file), let document = config.document(ref) {
                let servers = mapping.servers(in: document)
                Table(servers) {
                    TableColumn("Name") { server in
                        Text(server.name).font(.body.monospaced())
                    }
                    .width(min: 100, ideal: 140)
                    TableColumn("Transport") { server in Text(server.transport.rawValue).foregroundStyle(.secondary) }
                        .width(70)
                    TableColumn("Command / URL") { server in
                        Text(server.summary).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(server.summary)
                    }
                    TableColumn("Enabled") { server in
                        if mapping.supportsDisabling {
                            Toggle("Enabled", isOn: Binding(get: { server.isEnabled }, set: { enabled in
                                var new = server
                                new.isEnabled = enabled
                                config.apply(mapping.operations(from: server, to: new, document: document), in: ref)
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        } else {
                            Text("always").foregroundStyle(.tertiary).help("Claude Code has no user-scope on/off switch")
                        }
                    }
                    .width(60)
                    TableColumn("") { server in
                        HStack {
                            Button("Edit") { editing = EditTarget(original: server) }
                            Button { removing = server } label: { Image(systemName: "trash") }.help("Remove \(server.name)")
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(80)
                }
                .overlay {
                    if servers.isEmpty { Text("No user-scope MCP servers.").foregroundStyle(.secondary) }
                }
                HStack {
                    Button("Add Server…") { editing = EditTarget(original: nil) }
                    Spacer()
                    Text("Stored in \(ref.abbreviatedPath) → \(mapping.tableKey)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .sheet(item: $editing) { target in
                    MCPServerEditor(mapping: mapping, original: target.original, existingNames: servers.map(\.name)) { new in
                        config.apply(mapping.operations(from: target.original, to: new, document: document), in: ref)
                    }
                }
                .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                    Button("Remove", role: .destructive) {
                        if let removing { config.apply(mapping.operations(from: removing, to: nil, document: document), in: ref) }
                        removing = nil
                    }
                } message: {
                    Text("This is staged; nothing is written until you review and save.")
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

private struct MCPServerEditor: View {
    let mapping: MCPServerMapping
    let original: MCPServer?
    let existingNames: [String]
    let save: (MCPServer) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var server = MCPServer(name: "")
    @State private var argsText = ""

    var body: some View {
        let errors = validationErrors
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $server.name).font(.body.monospaced())
                Picker("Transport", selection: $server.transport) {
                    ForEach(mapping.transports, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if server.transport == .stdio {
                    TextField("Command", text: $server.command, prompt: Text("npx")).font(.body.monospaced())
                    Section {
                        StringListEditor(items: server.args, placeholder: "argument") { server.args = $0 }
                    } header: { Text("Arguments") } footer: { Text("One argument per row; no shell quoting needed.") }
                } else {
                    TextField("URL", text: $server.url, prompt: Text("https://…")).font(.body.monospaced())
                    Section("Headers") {
                        KeyValueEditor(items: server.headers, keyPrompt: "Header") { server.headers = $0 }
                    }
                }
                Section("Environment") {
                    KeyValueEditor(items: server.env) { server.env = $0 }
                }
                if mapping.supportsDisabling {
                    Toggle("Enabled", isOn: $server.isEnabled)
                }
                if !server.otherKeys.isEmpty {
                    Text("Also set in the file (kept as is): \(server.otherKeys.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if !errors.isEmpty {
                VStack(alignment: .leading) {
                    ForEach(errors, id: \.self) { Text($0) }
                }
                .font(.caption)
                .foregroundStyle(Theme.bad)
                .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Done") {
                    save(server)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!errors.isEmpty || server == original)
            }
            .padding(20)
        }
        .frame(width: 560, height: 560)
        .onAppear { if let original { server = original } }
    }

    private var validationErrors: [String] {
        var errors = server.validationErrors
        if server.name != original?.name, existingNames.contains(server.name) { errors.append("A server named \(server.name) already exists") }
        return errors
    }
}
