import HarnessButlerKit
import SwiftUI

/// A page in the settings sidebar.
enum SettingsPage: Hashable {
    case subscriptions, menubar, about
    /// A harness profile's config (C-1), by `ConfigProfile.id`.
    case profile(String)

    /// `--open-settings subscriptions|menubar|about|config` (debug builds).
    init?(argument: String) {
        switch argument {
        case "subscriptions": self = .subscriptions
        case "menubar": self = .menubar
        case "about": self = .about
        default: return nil
        }
    }
}

/// Shared so the popover and notifications can open a given page.
@Observable
final class SettingsNavigation {
    var page: SettingsPage? = .subscriptions
}

/// Settings: app pages, then one page per harness profile (mockup "settings window").
struct SettingsView: View {
    let store: UsageStore
    let harnesses: HarnessStore
    let config: ConfigStore
    let menuBar: MenuBarState
    @Bindable var navigation: SettingsNavigation

    static let sidebarMinWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 230
    static let detailMinWidth: CGFloat = 760

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.page) {
                Section("App") {
                    Label("Subscriptions", systemImage: "person.2").tag(SettingsPage.subscriptions)
                    Label("Menubar", systemImage: "menubar.rectangle").tag(SettingsPage.menubar)
                    Label("About", systemImage: "info.circle").tag(SettingsPage.about)
                }
                ForEach(Harness.allCases) { harness in
                    let profiles = config.profiles.filter { $0.harness == harness }
                    if !profiles.isEmpty {
                        Section {
                            ForEach(profiles) { profile in
                                ProfileSidebarRow(profile: profile, config: config).tag(SettingsPage.profile(profile.id))
                            }
                        } header: {
                            HStack(spacing: 4) {
                                Text(harness.displayName)
                                if harnesses.status(for: harness).isUpdateAvailable {
                                    Text("●").foregroundStyle(Theme.accent).help("Update available")
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: Self.sidebarIdealWidth, max: 300)
        } detail: {
            Group {
            switch navigation.page {
            case .subscriptions, nil: SubscriptionsSettings(store: store)
            case .menubar: MenuBarSettings(store: store, menuBar: menuBar)
            case .about: AboutSettings()
            case .profile(let id):
                if let profile = config.profiles.first(where: { $0.id == id }) {
                    ProfileConfigView(profile: profile, config: config, harnesses: harnesses).id(profile.id)
                } else {
                    ContentUnavailableView("Profile not found", systemImage: "questionmark.folder",
                                           description: Text("Its subscription may have been removed."))
                }
            }
            }
            // The config page's seven-tab bar (about 101 pt per tab) and header need this much;
            // below it SwiftUI centres the overflowing content and clips both edges.
            .frame(minWidth: Self.detailMinWidth)
            .navigationSplitViewColumnWidth(min: Self.detailMinWidth, ideal: Self.detailMinWidth + 60)
        }
        // The sidebar opens at its ideal width, so the window must fit that plus the detail minimum.
        .frame(minWidth: Self.sidebarIdealWidth + Self.detailMinWidth + 10, minHeight: 560)
        .environment(navigation)
        .onAppear { config.setSubscriptions(store.subscriptions) }
        .onChange(of: store.subscriptions) { _, new in config.setSubscriptions(new) }
    }
}

private struct ProfileSidebarRow: View {
    let profile: ConfigProfile
    let config: ConfigStore

    var body: some View {
        let pending = config.files(of: profile).contains { config.state($0)?.hasChanges == true }
        HStack(spacing: 8) {
            HarnessAvatar(harness: profile.harness, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName).lineLimit(1)
                Text(PathFormatting.abbreviate(profile.home.path(percentEncoded: false)))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if pending {
                Spacer()
                Circle().fill(Theme.warn).frame(width: 7, height: 7).help("Unsaved changes")
            }
        }
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
                Text("\(subscription.kindName) · \(subscription.sourceDescription())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let service = subscription.claudeKeychainService {
                    Text("Keychain: \(service)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                if subscription.api != nil {
                    APISubscriptionControls(store: store, subscription: subscription)
                }
            }
            Spacer()
            if !isRenaming {
                Button("Rename") { startRename() }.buttonStyle(.borderless).fixedSize()
            }
            HStack(spacing: 6) {
                Text("Menubar").font(.caption).foregroundStyle(.secondary)
                Toggle("Show in menubar", isOn: Binding(
                    get: { subscription.isPinned },
                    set: { store.setPinned(subscription.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            .fixedSize()
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

/// U-7: budget and key for an API subscription, under its name in the list.
private struct APISubscriptionControls: View {
    let store: UsageStore
    let subscription: Subscription
    @State private var budgetText = ""
    @State private var isReplacingKey = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Monthly budget").font(.caption).foregroundStyle(.secondary)
            TextField("Budget", text: $budgetText, prompt: Text("none"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 80)
                .onSubmit(commitBudget)
                .help("USD per UTC calendar month. Leave empty for no budget.")
            Text(BudgetInput.isValid(budgetText) ? "USD" : "Enter an amount like 250")
                .font(.caption)
                .foregroundStyle(BudgetInput.isValid(budgetText) ? Color.secondary : Color.red)
            Button("Replace Key…") { isReplacingKey = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .onAppear { budgetText = BudgetInput.text(subscription.api?.monthlyBudget) }
        .onChange(of: subscription.api?.monthlyBudget) { _, new in budgetText = BudgetInput.text(new) }
        // Commit when focus leaves the field, too.
        .onDisappear(perform: commitBudget)
        .sheet(isPresented: $isReplacingKey) {
            ReplaceKeySheet(store: store, subscription: subscription)
        }
    }

    private func commitBudget() {
        guard BudgetInput.isValid(budgetText) else { return }
        let budget = BudgetInput.value(budgetText)
        if budget != subscription.api?.monthlyBudget { store.setBudget(subscription.id, budget) }
    }
}

enum BudgetInput {
    static func value(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        guard let value = Double(cleaned), value.isFinite, UsageStore.budgetRange.contains(value) else { return nil }
        return value
    }

    static func isValid(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty || value(text) != nil
    }

    static func text(_ budget: Double?) -> String {
        guard let budget else { return "" }
        // %.0f, not Int(_:), so a huge budget (say 1e20) can't trap.
        return budget == budget.rounded() ? String(format: "%.0f", budget) : String(format: "%.2f", budget)
    }
}

private struct ReplaceKeySheet: View {
    let store: UsageStore
    let subscription: Subscription
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        Form {
            SecureField("Admin key", text: $key, prompt: Text(subscription.api?.provider.keyPrefix ?? ""))
            Text(subscription.api?.provider.keyHelp ?? "").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    error = store.replaceKey(subscription.id, with: key)
                    if error == nil { dismiss() }
                }
                .disabled(key.isEmpty)
            }
        }
    }
}

private struct AddSubscriptionSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case harness = "Harness login"
        case api = "API spend"
        var id: String { rawValue }
    }

    let store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.harness
    @State private var harness: Harness = .claude
    @State private var provider: APIProvider = .anthropic
    @State private var name = Harness.claude.displayName
    @State private var nameEdited = false
    @State private var homeOverride = ""
    @State private var key = ""
    @State private var budgetText = ""
    @State private var addError: String?

    private var suggestedName: String { kind == .api ? provider.displayName : harness.displayName }

    var body: some View {
        let error = SubscriptionNames.validate(name, among: store.subscriptions)
        Form {
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if kind == .harness {
                Picker("Harness", selection: $harness) {
                    ForEach(Harness.allCases) { Text($0.displayName).tag($0) }
                }
            } else {
                Picker("Provider", selection: $provider) {
                    ForEach(APIProvider.allCases) { Text($0.displayName).tag($0) }
                }
            }
            TextField("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
            if let error { Text(error.message).font(.caption).foregroundStyle(.red) }
            if kind == .harness {
                TextField(harness.homeEnvironmentVariable, text: $homeOverride, prompt: Text("Leave empty for \(defaultHome)"))
                Text("Enter the value exactly as your shell exports \(harness.homeEnvironmentVariable). Each value is a separate login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SecureField("Admin key", text: $key, prompt: Text(provider.keyPrefix + "…"))
                Text(provider.keyHelp + " The key is stored in your login Keychain and only sent to \(provider == .anthropic ? "api.anthropic.com" : "api.openai.com").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Monthly budget (USD)", text: $budgetText, prompt: Text("optional"))
                if !BudgetInput.isValid(budgetText) {
                    Text("Enter an amount like 250, or leave it empty.").font(.caption).foregroundStyle(.red)
                }
                Text("Spend is read every 30 minutes; providers report it with a delay of a few hours. Grok Build has no admin API, so it's tracked through its login only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let addError { Text(addError).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { name = SubscriptionNames.unique(suggestedName, among: store.subscriptions) }
        .onChange(of: suggestedName) { _, new in
            if !nameEdited { name = SubscriptionNames.unique(new, among: store.subscriptions) }
        }
        .onChange(of: kind) { addError = nil }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    switch kind {
                    case .harness:
                        if store.add(name: name, harness: harness, homeOverride: homeOverride) == nil { dismiss() }
                    case .api:
                        addError = store.addAPI(name: name, provider: provider, key: key, monthlyBudget: BudgetInput.value(budgetText))
                        if addError == nil { dismiss() }
                    }
                }
                .disabled(error != nil || (kind == .api && (key.isEmpty || !BudgetInput.isValid(budgetText))))
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

/// M-1: pinned order, a live preview, the item's width and a warning when it risks being hidden.
private struct MenuBarSettings: View {
    let store: UsageStore
    let menuBar: MenuBarState
    @AppStorage(AppSettings.showUpdateBadgeKey) private var showUpdateBadge = true
    @AppStorage(AppSettings.notifyUpdatesKey) private var notifyUpdates = false
    @AppStorage(AppSettings.notifyUsageKey) private var notifyUsage = false
    @AppStorage(AppSettings.notificationsDeniedKey) private var notificationsDenied = false
    @AppStorage(AppSettings.menuBarModeKey) private var mode = MenuBarMode.percent

    var body: some View {
        Form {
            Section("Preview") {
                Picker("Display", selection: $mode) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    MenuBarPreview(title: MenuBarTitle.attributedString(
                        for: store.pinned.map { ($0, store.usage(for: $0.id)) }, now: context.date, mode: mode
                    ))
                }
                LabeledContent("Width", value: "\(Int(menuBar.width.rounded())) pt")
                if menuBar.isLikelyHidden {
                    Label("macOS appears to be hiding the menubar item because it doesn't fit. Unpin some subscriptions or remove other menubar items.",
                          systemImage: "eye.slash")
                        .foregroundStyle(.red)
                } else if menuBar.isWide {
                    Label("The item is wide. On smaller or notched displays macOS may hide it. Consider unpinning some subscriptions.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warn)
                }
            }
            Section("Usage alerts") {
                Toggle(isOn: $notifyUsage) {
                    Text("Notify me about usage")
                    Text("When a window passes 80% and 95% used, and when a limited window resets. Each once per window period. Choose per subscription in its detail view.")
                }
            }
            Section("Harness updates") {
                Toggle("Show a dot in the menubar when an update is available", isOn: $showUpdateBadge)
                Toggle(isOn: $notifyUpdates) {
                    Text("Notify me when an update is available")
                    Text("Once per version. Updates still only run when you click Update.")
                }
                if notificationsDenied && !notifyUpdates && !notifyUsage {
                    HStack {
                        Label("Notifications for Harness Butler are turned off in System Settings.", systemImage: "bell.slash")
                            .foregroundStyle(Theme.warn)
                        Spacer()
                        Button("Open Notifications Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            Section {
                if store.pinned.isEmpty {
                    Text("Nothing pinned. Pin subscriptions in the popover or on the Subscriptions tab.")
                        .foregroundStyle(.secondary)
                }
                List {
                    ForEach(store.pinned) { subscription in
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            HarnessAvatar(harness: subscription.harness, size: 18)
                            Text(subscription.name)
                            Spacer()
                            Button("Unpin") { store.setPinned(subscription.id, false) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .onMove { store.movePinned(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 120)
            } header: {
                Text("Pinned, in menubar order")
            } footer: {
                Text("Drag to reorder. Every pinned subscription is shown; none are truncated.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Renders the menubar title (with logo attachments) the way the status item does.
private struct MenuBarPreview: NSViewRepresentable {
    var title: NSAttributedString

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: title)
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = title.length == 0 ? NSAttributedString(string: "(icon only)") : title
    }
}
