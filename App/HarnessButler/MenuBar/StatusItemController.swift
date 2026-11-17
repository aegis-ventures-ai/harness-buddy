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
        let hosting = NSHostingController(rootView: PopoverView(
            store: store,
            harnesses: harnesses,
            navigation: navigation,
            openSettings: { [weak self] page in self?.closePopoverThen { openSettings(page) } }
        ))
        // Let NSPopover size itself from SwiftUI's preferred size. Otherwise the hosting view resizes
        // the popover window from its bottom edge when content changes (rows loading, detail page),
        // and the popover grows up under the menubar.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

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
        let items = pinned.map { ($0, store.usage(for: $0.id)) }
        var tooltip = MenuBarTitle.tooltip(for: items, now: now) ?? ""
        var label = MenuBarTitle.accessibilityLabel(for: items, now: now)
        for harness in updates {
            let line = "\(harness.displayName) \(harnesses.status(for: harness).latest.map(\.description) ?? "") available"
            tooltip += "\n" + line
            label += "\nUpdate available: " + line
        }
        button.toolTip = tooltip
        button.setAccessibilityLabel(label)
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

/// Builds the menubar title (M-2): percent mode is one `glyph NN%` segment per pinned subscription,
/// in list order; worst-of is one ring; mini bars are two bars per subscription.
enum MenuBarTitle {
    static func attributedString(for items: [(Subscription, SubscriptionUsage)], now: Date, mode: MenuBarMode = AppSettings.menuBarMode) -> NSAttributedString {
        switch mode {
        case .percent: percent(items, now: now)
        case .worstOf: worstOf(items, now: now)
        case .miniBars: miniBars(items, now: now)
        }
    }

    /// The standard menubar text size (13 pt), with fixed-width digits so the item doesn't jitter.
    private static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular) }
    /// Standard status-item icon size.
    static let iconSize: CGFloat = 16

    private static func statusColor(_ status: UsageStatus, stale: Bool) -> NSColor {
        switch status {
        case .limited: NSColor(hex: 0xEC6F6F)
        case .atRisk: NSColor(hex: 0xE8B553)
        case .onTrack: stale ? .secondaryLabelColor : .labelColor
        }
    }

    /// Never colour-only (M-3): at risk and limited also get a symbol, stale data a clock.
    private static func marker(_ status: UsageStatus, stale: Bool, color: NSColor, font: NSFont) -> NSAttributedString? {
        let name: String? = switch status {
        case .atRisk: "exclamationmark.triangle.fill"
        case .limited: "xmark.octagon.fill"
        case .onTrack: stale ? "clock.badge.exclamationmark" : nil
        }
        guard let name else { return nil }
        let result = NSMutableAttributedString(string: "\u{2009}", attributes: [.font: font])
        result.append(symbol(name, color: color, font: font, size: 11))
        return result
    }

    private static func isStale(_ subscription: Subscription, _ usage: SubscriptionUsage, now: Date) -> Bool {
        SubscriptionGroup.classify(usage, cadence: subscription.cadence, at: now) == .stale
    }

    // MARK: Worst-of

    private static func worstOf(_ items: [(Subscription, SubscriptionUsage)], now: Date) -> NSAttributedString {
        let font = font
        let result = NSMutableAttributedString()
        let candidates = items.map { (snapshot: $0.1.snapshot, isStale: isStale($0.0, $0.1, now: now)) }
        guard let index = UsageRules.mostConstrained(candidates, at: now),
              let snapshot = items[index].1.snapshot?.current(at: now),
              let window = UsageRules.headlineWindow(of: snapshot, at: now) else {
            // Nothing with a window yet (loading, errors, or API spend without a budget).
            if let (_, usage) = items.first(where: { $0.1.snapshot?.spend != nil }), let spend = usage.snapshot?.spend {
                return NSAttributedString(string: Format.compactDollars(spend.monthToDate, currency: spend.currency), attributes: [.font: font])
            }
            return items.isEmpty ? result : NSAttributedString(string: "–", attributes: [.font: font])
        }
        let status = UsageRules.status(of: window, at: now)
        let stale = candidates[index].isStale
        let color = statusColor(status, stale: stale)
        let ringColor: NSColor = status == .onTrack && !stale ? Theme.nsColor(for: items[index].0.harness) : color
        result.append(attachment(ring(remaining: window.remainingPercent / 100, color: ringColor), font: font))
        result.append(NSAttributedString(string: "\u{2009}" + Format.percent(window.remainingPercent), attributes: [.font: font, .foregroundColor: color]))
        if let marker = marker(status, stale: stale, color: color, font: font) { result.append(marker) }
        return result
    }

    /// A 16 pt ring: track plus an arc for the remaining fraction, clockwise from the top.
    static func ring(remaining: Double, color: NSColor) -> NSImage {
        let size: CGFloat = iconSize
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let lineWidth: CGFloat = 2.5
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = (size - lineWidth) / 2
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()
            let fraction = max(0, min(1, remaining))
            if fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        image.accessibilityDescription = "\((remaining * 100).rounded().displayInt) percent left"
        return image
    }

    // MARK: Mini bars

    private static func miniBars(_ items: [(Subscription, SubscriptionUsage)], now: Date) -> NSAttributedString {
        let font = font
        let result = NSMutableAttributedString()
        for (index, (subscription, usage)) in items.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            result.append(logo(for: subscription.harness, font: font))
            result.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
            let stale = isStale(subscription, usage, now: now)
            guard let snapshot = usage.snapshot?.current(at: now) else {
                result.append(NSAttributedString(string: "–", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
                continue
            }
            let windows = UsageRules.miniBarWindows(of: snapshot)
            if windows.isEmpty {
                let text = snapshot.spend.map { Format.compactDollars($0.monthToDate, currency: $0.currency) } ?? "–"
                result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: stale ? NSColor.secondaryLabelColor : NSColor.labelColor]))
                continue
            }
            let bars = windows.map { window -> (remaining: Double, color: NSColor) in
                let status = UsageRules.status(of: window, at: now)
                let color: NSColor = status == .onTrack ? (stale ? .secondaryLabelColor : Theme.nsColor(for: subscription.harness)) : statusColor(status, stale: stale)
                return (window.remainingPercent / 100, color)
            }
            result.append(attachment(barsImage(bars), font: font))
            let worst = windows.map { UsageRules.status(of: $0, at: now) }.max() ?? .onTrack
            if let marker = marker(worst, stale: stale, color: statusColor(worst, stale: stale), font: font) { result.append(marker) }
        }
        return result
    }

    /// Stacked 30×4 pt bars, filled to the remaining fraction (as in the mockup).
    static func barsImage(_ bars: [(remaining: Double, color: NSColor)]) -> NSImage {
        let width: CGFloat = 30, barHeight: CGFloat = 4, gap: CGFloat = 3
        let height = CGFloat(bars.count) * barHeight + CGFloat(max(0, bars.count - 1)) * gap
        let image = NSImage(size: NSSize(width: width, height: max(height, barHeight)), flipped: true) { _ in
            for (index, bar) in bars.enumerated() {
                let y = CGFloat(index) * (barHeight + gap)
                let track = NSRect(x: 0, y: y, width: width, height: barHeight)
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
                let fill = NSRect(x: 0, y: y, width: width * max(0, min(1, bar.remaining)), height: barHeight)
                if fill.width > 0 {
                    bar.color.setFill()
                    NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
            return true
        }
        image.accessibilityDescription = bars.map { "\(($0.remaining * 100).rounded().displayInt) percent left" }.joined(separator: ", ")
        return image
    }

    private static func attachment(_ image: NSImage, font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    // MARK: Percent

    private static func percent(_ items: [(Subscription, SubscriptionUsage)], now: Date) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = font
        for (index, (subscription, usage)) in items.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "  ", attributes: [.font: font])) }

            let snapshot = usage.snapshot?.current(at: now)
            let window = snapshot.flatMap { UsageRules.headlineWindow(of: $0, at: now) }
            let status = window.map { UsageRules.status(of: $0, at: now) } ?? .onTrack
            let stale = isStale(subscription, usage, now: now)
            let color = statusColor(status, stale: stale)

            result.append(logo(for: subscription.harness, font: font))
            // API spend without a budget has no window: show the month-to-date amount instead.
            let text = window.map { Format.percent($0.remainingPercent) }
                ?? snapshot?.spend.map { Format.compactDollars($0.monthToDate, currency: $0.currency) } ?? "–"
            result.append(NSAttributedString(string: "\u{2009}" + text, attributes: [.font: font, .foregroundColor: color]))
            if let marker = marker(status, stale: stale, color: color, font: font) { result.append(marker) }
        }
        return result
    }

    private static func logo(for harness: Harness, font: NSFont) -> NSAttributedString {
        guard let image = Theme.tintedLogo(for: harness, size: iconSize) else { return NSAttributedString() }
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
        result.append(symbol("circle.fill", color: NSColor(hex: 0x8FB4F2), font: NSFont.systemFont(ofSize: NSFont.systemFontSize), size: 7))
        return result
    }

    /// M-6 tooltip: one short line per pinned subscription, e.g. "Claude Work: 82% left · resets 2d 21h",
    /// with a status word only when it needs attention. Short enough not to wrap.
    static func tooltip(for items: [(Subscription, SubscriptionUsage)], now: Date) -> String? {
        guard !items.isEmpty else { return "Harness Butler — no pinned subscriptions" }
        return items.map { subscription, usage in
            let stale = SubscriptionGroup.classify(usage, cadence: subscription.cadence, at: now) == .stale
            guard let snapshot = usage.snapshot?.current(at: now) else {
                return "\(subscription.name): \(usage.issue == nil ? "loading…" : "no data")"
            }
            var parts: [String]
            var status = UsageStatus.onTrack
            if let window = UsageRules.headlineWindow(of: snapshot, at: now) {
                status = UsageRules.status(of: window, at: now)
                parts = ["\(Format.percent(window.remainingPercent)) left"]
                if let resetsAt = window.resetsAt { parts.append("resets \(Format.duration(resetsAt.timeIntervalSince(now)))") }
            } else if let spend = snapshot.spend {
                parts = ["\(Format.compactDollars(spend.monthToDate, currency: spend.currency)) so far",
                         "\(Format.compactDollars(spend.projectedMonthEnd(at: now), currency: spend.currency)) projected"]
            } else {
                parts = ["no data"]
            }
            switch status {
            case .limited: parts.append("limited")
            case .atRisk: parts.append("at risk")
            case .onTrack: if stale { parts.append("stale") }
            }
            return "\(subscription.name): " + parts.joined(separator: " · ")
        }.joined(separator: "\n")
    }

    /// VoiceOver label: the fuller version, with window names and issues.
    static func accessibilityLabel(for items: [(Subscription, SubscriptionUsage)], now: Date) -> String {
        guard !items.isEmpty else { return "Harness Butler, no pinned subscriptions" }
        return items.map { subscription, usage in
            guard let snapshot = usage.snapshot?.current(at: now),
                  let window = UsageRules.headlineWindow(of: snapshot, at: now) else {
                if let spend = usage.snapshot?.spend {
                    return "\(subscription.name): \(Format.dollars(spend.monthToDate, currency: spend.currency)) this month, projected \(Format.dollars(spend.projectedMonthEnd(at: now), currency: spend.currency))"
                }
                return "\(subscription.name): \(usage.issue?.message ?? "loading")"
            }
            return "\(subscription.name): \(Format.percent(window.remainingPercent)) left (\(window.label)), \(Format.resets(window.resetsAt, now: now))"
        }.joined(separator: "\n")
    }
}
