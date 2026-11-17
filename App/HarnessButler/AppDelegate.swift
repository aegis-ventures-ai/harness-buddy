import AppKit
import HarnessButlerKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: UsageStore!
    private(set) var harnesses: HarnessStore!
    private var statusItem: StatusItemController?
    private var updateNotifier: UpdateNotifier?
    private var settingsWindow: NSWindow?

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        store = UsageStore(appVersion: Self.appVersion)
        harnesses = HarnessStore(appVersion: Self.appVersion)
        statusItem = StatusItemController(store: store, harnesses: harnesses, openSettings: { [weak self] in self?.showSettings() })
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
            // --open-settings [subscriptions|menubar|about]
            if let index = CommandLine.arguments.firstIndex(of: "--open-settings") {
                let name = CommandLine.arguments.dropFirst(index + 1).first ?? ""
                showSettings(tab: SettingsTab(rawValue: name) ?? .subscriptions)
            }
            #endif
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        harnesses.stop()
        ChildProcessRegistry.shared.terminateAll()
    }

    func showSettings(tab: SettingsTab = .subscriptions) {
        if settingsWindow == nil {
            let view = SettingsView(store: store, harnesses: harnesses, menuBar: statusItem?.menuBarState ?? MenuBarState(), tab: tab)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Harness Butler Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 460))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
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
