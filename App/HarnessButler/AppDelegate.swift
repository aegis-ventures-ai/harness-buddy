import AppKit
import HarnessButlerKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: UsageStore!
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = UsageStore(appVersion: Self.appVersion)
        statusItem = StatusItemController(store: store, openSettings: { [weak self] in self?.showSettings() })
        observeSleep()
        Task {
            await store.start()
            #if DEBUG
            if CommandLine.arguments.contains("--open-popover") {
                try? await Task.sleep(for: .seconds(3))
                statusItem?.openPopoverForDebugging()
            }
            #endif
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        ChildProcessRegistry.shared.terminateAll()
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
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
            }
        }
    }
}
