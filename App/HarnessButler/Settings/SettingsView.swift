import HarnessButlerKit
import SwiftUI

/// M1 settings: manage subscriptions (U-2) and menubar pinning/order (M-1).
/// Harness config pages (C-1…) arrive in M3.
struct SettingsView: View {
    let store: UsageStore

    var body: some View {
        TabView {
            Tab("Subscriptions", systemImage: "person.2") {
                SubscriptionsSettings(store: store)
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettings()
            }
        }
        .frame(minWidth: 600, minHeight: 420)
    }
}

private struct SubscriptionsSettings: View {
    let store: UsageStore
    @State private var selection: UUID?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(store.subscriptions) { subscription in
                    SubscriptionSettingsRow(store: store, subscription: subscription)
                        .tag(subscription.id)
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)

            HStack {
                Button { isAdding = true } label: { Image(systemName: "plus") }
                    .help("Add a subscription")
                Button {
                    if let selection { store.remove(selection) }
                    selection = nil
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Remove the selected subscription")
                Spacer()
                Text("Drag to reorder. Pinned subscriptions appear in the menubar in this order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(10)

            if let error = store.saveError {
                Text(error).font(.caption).foregroundStyle(.red).padding([.horizontal, .bottom], 10)
            }
        }
        .sheet(isPresented: $isAdding) {
            AddSubscriptionSheet(store: store)
        }
    }
}

private struct SubscriptionSettingsRow: View {
    let store: UsageStore
    let subscription: Subscription
    @State private var draftName = ""
    @State private var isRenaming = false

    var body: some View {
        HStack(spacing: 10) {
            HarnessAvatar(harness: subscription.harness)
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    let error = SubscriptionNames.validate(draftName, among: store.subscriptions, excluding: subscription.id)
                    HStack {
                        TextField("Name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commit() }
                        Button("Save") { commit() }.disabled(error != nil)
                        Button("Cancel") { isRenaming = false }
                    }
                    if let error { Text(error.message).font(.caption).foregroundStyle(.red) }
                } else {
                    Text(subscription.name).font(.body.weight(.medium))
                        .onTapGesture(count: 2) { startRename() }
                }
                Text("\(subscription.harness.displayName) · \(subscription.sourceDescription())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let service = subscription.claudeKeychainService {
                    Text("Keychain: \(service)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !isRenaming {
                Button("Rename") { startRename() }.buttonStyle(.borderless)
            }
            Toggle("Menubar", isOn: Binding(
                get: { subscription.isPinned },
                set: { store.setPinned(subscription.id, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func startRename() {
        draftName = subscription.name
        isRenaming = true
    }

    private func commit() {
        if store.rename(subscription.id, to: draftName) == nil { isRenaming = false }
    }
}

private struct AddSubscriptionSheet: View {
    let store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var harness: Harness = .claude
    @State private var name = Harness.claude.displayName
    @State private var nameEdited = false
    @State private var homeOverride = ""

    var body: some View {
        let error = SubscriptionNames.validate(name, among: store.subscriptions)
        Form {
            Picker("Harness", selection: $harness) {
                ForEach(Harness.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: harness) { _, new in
                if !nameEdited { name = SubscriptionNames.unique(new.displayName, among: store.subscriptions) }
            }
            TextField("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
            if let error { Text(error.message).font(.caption).foregroundStyle(.red) }
            TextField(harness.homeEnvironmentVariable, text: $homeOverride, prompt: Text("Leave empty for \(defaultHome)"))
            Text("Enter the value exactly as your shell exports \(harness.homeEnvironmentVariable). Each value is a separate login.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { name = SubscriptionNames.unique(harness.displayName, among: store.subscriptions) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    if store.add(name: name, harness: harness, homeOverride: homeOverride) == nil { dismiss() }
                }
                .disabled(error != nil)
            }
        }
    }

    private var defaultHome: String {
        switch harness {
        case .claude: "~/.claude"
        case .codex: "~/.codex"
        case .grok: "~/.grok"
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 40))
            Text("Harness Butler").font(.title2.weight(.semibold))
            Text("Version \(AppDelegate.appVersion)").foregroundStyle(.secondary)
            Text("Usage, updates and config for Claude Code, Codex and Grok Build.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
