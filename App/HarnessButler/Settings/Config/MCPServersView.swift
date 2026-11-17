import HarnessButlerKit
import SwiftUI

/// C-3: user-scope MCP servers: list, add, edit, enable/disable, remove.
struct MCPServersView: View {
    let profile: ConfigProfile
    let config: ConfigStore
    @State private var editing: EditTarget?
    @State private var removing: MCPServer?
    @State private var copying: MCPServer?
    @Environment(SettingsNavigation.self) private var navigation

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
                            Button { copying = server } label: { Image(systemName: "doc.on.doc") }
                                .help("Copy \(server.name) to another profile or harness")
                                .disabled(config.profiles.count < 2)
                            Button { removing = server } label: { Image(systemName: "trash") }.help("Remove \(server.name)")
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(105)
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
                .sheet(item: $copying) { server in
                    MCPCopySheet(server: server, source: profile, config: config) { target in
                        navigation.page = .profile(target.id)
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
        #if DEBUG
        .task {
            // `--demo-copy`: open the copy sheet for the first server (UI checks; nothing is staged).
            guard CommandLine.arguments.contains("--demo-copy") else { return }
            try? await Task.sleep(for: .seconds(1))
            let mapping = MCPServerMapping.forHarness(profile.harness)
            copying = profile.file(mapping.file).flatMap(config.document).flatMap { mapping.servers(in: $0).first }
        }
        #endif
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

/// C-9: copy a server to another profile (same or another harness). The copy is staged in the
/// target's file and saved from that profile's page after review.
private struct MCPCopySheet: View {
    let server: MCPServer
    let source: ConfigProfile
    let config: ConfigStore
    let reveal: (ConfigProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var targetID: String?
    @State private var name = ""
    @State private var copied: MCPCopyPlan?
    @State private var failure: String?

    private var targets: [ConfigProfile] { config.profiles.filter { $0.id != source.id } }
    private var target: ConfigProfile? { targets.first { $0.id == targetID } }

    /// A pure read: the target's file is loaded by the `.task` below, not during view updates.
    private var plan: Result<MCPCopyPlan, ConfigEditError>? {
        guard let target else { return nil }
        guard let ref = config.mcpFile(of: target), let document = config.document(ref) else {
            return config.mcpFile(of: target).flatMap { config.errors[$0.id] }.map { .failure(ConfigEditError($0)) }
        }
        do { return .success(try MCPServerMapping.forHarness(target.harness).copyPlan(server, into: document, as: name)) }
        catch let error as ConfigEditError { return .failure(error) }
        catch { return .failure(ConfigEditError("\(error)")) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy \(server.name)").font(.headline)
            if let copied, let target {
                Label("Staged in \(target.displayName) (\(target.harness.displayName)). Review and save it on that profile's page.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.ok)
                notes(copied.notes)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                    Button("Go to \(target.displayName)") { dismiss(); reveal(target) }.keyboardShortcut(.defaultAction)
                }
            } else {
                Form {
                    Picker("To", selection: $targetID) {
                        ForEach(Harness.allCases) { harness in
                            let profiles = targets.filter { $0.harness == harness }
                            if !profiles.isEmpty {
                                Section(harness.displayName) {
                                    ForEach(profiles) { Text("\($0.displayName) · \(PathFormatting.abbreviate($0.home.path(percentEncoded: false)))").tag(Optional($0.id)) }
                                }
                            }
                        }
                    }
                    TextField("Name", text: $name)
                }
                .formStyle(.columns)
                switch plan {
                case .failure(let error)?:
                    Label(error.message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warn)
                case .success(let plan)?:
                    notes(plan.notes)
                    if plan.notes.isEmpty { Text("Every setting carries over.").foregroundStyle(.secondary) }
                case nil:
                    EmptyView()
                }
                if let failure { Text(failure).foregroundStyle(Theme.bad) }
                HStack {
                    Text("Nothing is written until you review and save.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Copy") {
                        guard let target else { return }
                        do { copied = try config.copy(server, to: target, as: name) } catch { failure = "\(error)" }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(plan.map { if case .success = $0 { true } else { false } } ?? false))
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            name = server.name
            // Prefer another harness: that's what copying is mostly for.
            targetID = (targets.first { $0.harness != source.harness } ?? targets.first)?.id
        }
        .task(id: targetID) {
            if let target { config.open(target) }
        }
    }

    @ViewBuilder
    private func notes(_ notes: [String]) -> some View {
        ForEach(notes, id: \.self) { Label($0, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
    }
}
