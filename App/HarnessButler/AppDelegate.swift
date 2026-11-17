import AppKit
import HarnessButlerKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var store: UsageStore!
    private(set) var harnesses: HarnessStore!
    private let config = ConfigStore()
    private let settingsNavigation = SettingsNavigation()
    private var statusItem: StatusItemController?
    private var updateNotifier: UpdateNotifier?
    private var settingsWindow: NSWindow?

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        #if DEBUG
        store = DemoAPI.isEnabled ? DemoAPI.makeStore(appVersion: Self.appVersion) : UsageStore(appVersion: Self.appVersion)
        #else
        store = UsageStore(appVersion: Self.appVersion)
        #endif
        harnesses = HarnessStore(appVersion: Self.appVersion)
        statusItem = StatusItemController(store: store, harnesses: harnesses, openSettings: { [weak self] in self?.showSettings(page: $0) })
        // Before the first check, so a notification clicked while the app wasn't running is delivered.
        updateNotifier = UpdateNotifier(harnesses: harnesses) { [weak self] in
            NSApp.activate()
            self?.statusItem?.showPopover(.harnesses)
        }
        observeSleep()
        Task {
            await store.start()
            if let environment = store.environment { harnesses.start(environment: environment) }
            #if DEBUG
            if CommandLine.arguments.contains("--open-popover") {
                try? await Task.sleep(for: .seconds(3))
                statusItem?.openPopoverForDebugging()
            }
            // --open-settings [subscriptions|menubar|about|claude|codex|grok]
            if let index = CommandLine.arguments.firstIndex(of: "--open-settings") {
                let name = CommandLine.arguments.dropFirst(index + 1).first ?? ""
                if let harness = Harness(rawValue: name) {
                    showSettings(page: configPage(for: harness))
                } else {
                    showSettings(page: SettingsPage(argument: name) ?? .subscriptions)
                }
            }
            // --demo-pending: stage one harmless edit in memory (never saved) to check the pending bar and diff.
            if CommandLine.arguments.contains("--demo-pending"), let profile = config.profiles.first(where: { $0.harness == .grok }),
               let ref = profile.file(.grokConfig) {
                config.open(profile)
                let current = config.document(ref)?.value(at: ["ui", "compact_mode"])?.bool ?? false
                config.apply([.set(["ui", "compact_mode"], .bool(!current))], in: ref)
            }
            #endif
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        harnesses.stop()
        ChildProcessRegistry.shared.terminateAll()
    }

    /// Open Settings, optionally on a page (`nil` keeps the current one).
    func showSettings(page: SettingsPage? = nil) {
        config.setSubscriptions(store.subscriptions)
        if let page { settingsNavigation.page = page }
        if settingsWindow == nil {
            let view = SettingsView(store: store, harnesses: harnesses, config: config,
                                    menuBar: statusItem?.menuBarState ?? MenuBarState(), navigation: settingsNavigation)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Harness Butler Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 900, height: 620))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The config page of a harness's first profile (from the popover's "configure").
    func configPage(for harness: Harness) -> SettingsPage {
        config.setSubscriptions(store.subscriptions)
        return config.profiles.first { $0.harness == harness }.map { .profile($0.id) } ?? .subscriptions
    }

    func windowWillClose(_ notification: Notification) {
        // Stop watching config files; unsaved edits are kept for when Settings reopens.
        if (notification.object as? NSWindow) === settingsWindow { config.closeAll() }
    }

    /// U-12: pause polling while asleep; refresh on wake.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.isPaused = true }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let store = self?.store else { return }
                store.isPaused = false
                store.refreshAll(.scheduled)
                Task { await self?.harnesses.refresh(force: false) }
            }
        }
    }
}
