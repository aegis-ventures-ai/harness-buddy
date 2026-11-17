import AppKit
import HarnessButlerKit
import SwiftUI

/// The menubar item: percent mode (M-2), status colours with a glyph (M-3),
/// left-click popover and right-click menu (M-5), tooltip (M-6), update badge (M-4).
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let harnesses: HarnessStore
    private let openSettings: (SettingsPage?) -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var clock: Timer?
    let menuBarState = MenuBarState()
    let navigation = PopoverNavigation()

    init(store: UsageStore, harnesses: HarnessStore, openSettings: @escaping (SettingsPage?) -> Void) {
        self.store = store
        self.harnesses = harnesses
        self.openSettings = openSettings
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            store: store,
            harnesses: harnesses,
            navigation: navigation,
            openSettings: { [weak self] page in self?.closePopoverThen { openSettings(page) } }
        ))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        statusItem.autosaveName = "HarnessButlerStatusItem"

        observeStore()
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        // Countdowns and pace move with time even when data doesn't.
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    // MARK: - Rendering

    private func observeStore() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let now = Date.now
        let pinned = store.pinned
        let title = NSMutableAttributedString(attributedString: MenuBarTitle.attributedString(for: pinned.map { ($0, store.usage(for: $0.id)) }, now: now))
        let updates = harnesses.updatesAvailable
        if !updates.isEmpty, AppSettings.showUpdateBadge {
            title.append(MenuBarTitle.updateBadge())
        }
        if pinned.isEmpty {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Harness Butler")
        } else {
            button.image = nil
        }
        button.attributedTitle = title
        menuBarState.width = button.intrinsicContentSize.width
        updateVisibility()
        var tooltip = MenuBarTitle.tooltip(for: pinned.map { ($0, store.usage(for: $0.id)) }, now: now) ?? ""
        for harness in updates {
            tooltip += "\nUpdate available: \(harness.displayName) \(harnesses.status(for: harness).latest.map(\.description) ?? "")"
        }
        button.toolTip = tooltip
        button.setAccessibilityLabel(button.toolTip ?? "Harness Butler")
    }

    /// Hidden when the item's window is gone, off every screen, or fully occluded while the menubar shows.
    private func updateVisibility() {
        guard let window = statusItem.button?.window else {
            menuBarState.isLikelyHidden = true
            return
        }
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        let menuBarShowing = NSMenu.menuBarVisible()
        menuBarState.isLikelyHidden = !window.isVisible || !onScreen
            || (menuBarShowing && !window.occlusionState.contains(.visible))
    }

    #if DEBUG
    /// `--open-popover`: show the popover at launch (for screenshots and UI checks).
    func openPopoverForDebugging() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.behavior = .applicationDefined // stays open for screenshots; click the item to close
        togglePopover(button)
    }
    #endif

    /// Open the popover on a page (e.g. from an update notification).
    func showPopover(_ page: PopoverNavigation.Page) {
        navigation.show(page)
        guard let button = statusItem.button, !popover.isShown else { return }
        togglePopover(button)
    }

    /// Open the popover on a subscription's detail page (from a usage notification).
    func showSubscription(_ id: UUID) {
        navigation.show(.usage)
        if store.subscriptions.contains(where: { $0.id == id }) { navigation.selection = id }
        guard let button = statusItem.button, !popover.isShown else { return }
        togglePopover(button)
    }

    // MARK: - Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        store.refreshAll(.popoverOpened)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Harness Butler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // keep left-click for the popover
    }

    @objc private func refresh() { store.refreshAll(.manual) }
    @objc private func settings() { openSettings(nil) }

    private func closePopoverThen(_ action: @escaping () -> Void) {
        popover.performClose(nil)
        action()
    }
}

/// Builds the percent-mode title: one `glyph NN%` segment per pinned subscription, in list order.
enum MenuBarTitle {
    static func attributedString(for items: [(Subscription, SubscriptionUsage)], now: Date) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        for (index, (subscription, usage)) in items.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "  ", attributes: [.font: font])) }

            let snapshot = usage.snapshot?.current(at: now)
            let window = snapshot.flatMap { UsageRules.headlineWindow(of: $0, at: now) }
            let status = window.map { UsageRules.status(of: $0, at: now) } ?? .onTrack
            let stale = SubscriptionGroup.classify(usage, cadence: subscription.cadence, at: now) == .stale

            let color: NSColor = switch status {
            case .limited: NSColor(hex: 0xEC6F6F)
            case .atRisk: NSColor(hex: 0xE8B553)
            case .onTrack: stale ? .secondaryLabelColor : .labelColor
            }

            result.append(logo(for: subscription.harness, font: font))
            // API spend without a budget has no window: show the month-to-date amount instead.
            let text = window.map { Format.percent($0.remainingPercent) }
                ?? snapshot?.spend.map { Format.compactDollars($0.monthToDate, currency: $0.currency) } ?? "–"
            result.append(NSAttributedString(string: "\u{2009}" + text, attributes: [.font: font, .foregroundColor: color]))

            // Never colour-only (M-3): at risk and limited also get a symbol.
            let marker: String? = switch status {
            case .atRisk: "exclamationmark.triangle.fill"
            case .limited: "xmark.octagon.fill"
            case .onTrack: stale ? "clock.badge.exclamationmark" : nil
            }
            if let marker {
                result.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
                result.append(symbol(marker, color: color, font: font, size: 9))
            }
        }
        return result
    }

    private static func logo(for harness: Harness, font: NSFont) -> NSAttributedString {
        guard let image = Theme.tintedLogo(for: harness, size: 13) else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    private static func symbol(_ name: String, color: NSColor, font: NSFont, size: CGFloat) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return NSAttributedString()
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let y = (font.capHeight - image.size.height) / 2
        attachment.bounds = CGRect(x: 0, y: y, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// M-4: a small accent dot after the title.
    static func updateBadge() -> NSAttributedString {
        let result = NSMutableAttributedString(string: "\u{2009}")
        result.append(symbol("circle.fill", color: NSColor(hex: 0x8FB4F2), font: NSFont.systemFont(ofSize: NSFont.systemFontSize), size: 6))
        return result
    }

    /// M-6 tooltip and VoiceOver label: name, % left, reset per pinned subscription.
    static func tooltip(for items: [(Subscription, SubscriptionUsage)], now: Date) -> String? {
        guard !items.isEmpty else { return "Harness Butler — no pinned subscriptions" }
        return items.map { subscription, usage in
            guard let snapshot = usage.snapshot?.current(at: now),
                  let window = UsageRules.headlineWindow(of: snapshot, at: now) else {
                if let spend = usage.snapshot?.spend {
                    return "\(subscription.name): \(Format.dollars(spend.monthToDate, currency: spend.currency)) this month, projected \(Format.dollars(spend.projectedMonthEnd(at: now), currency: spend.currency))"
                }
                return "\(subscription.name): \(usage.issue?.message ?? "loading…")"
            }
            return "\(subscription.name): \(Format.percent(window.remainingPercent)) left (\(window.label)), \(Format.resets(window.resetsAt, now: now))"
        }.joined(separator: "\n")
    }
}
