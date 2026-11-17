import AppKit
import HarnessButlerKit
import SwiftUI

/// Colours and type from docs/mockups/index.html.
enum Theme {
    static func color(for harness: Harness) -> Color { Color(nsColor: nsColor(for: harness)) }

    static func nsColor(for harness: Harness) -> NSColor {
        switch harness {
        case .claude: NSColor(hex: 0xD97757)
        case .codex: NSColor(hex: 0x6FBF8E)
        case .grok: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0xC9CCD4) : NSColor(hex: 0x5A5D66)
        }
        }
    }

    static let warn = Color(nsColor: NSColor(hex: 0xE8B553))
    static let bad = Color(nsColor: NSColor(hex: 0xEC6F6F))
    static let ok = Color(nsColor: NSColor(hex: 0x7DD59A))
    static let accent = Color(nsColor: NSColor(hex: 0x8FB4F2))

    static func color(for status: UsageStatus, harness: Harness) -> Color {
        switch status {
        case .onTrack: color(for: harness)
        case .atRisk: warn
        case .limited: bad
        }
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func initial(for harness: Harness) -> String {
        switch harness {
        case .claude: "C"
        case .codex: "O"
        case .grok: "G"
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Short relative strings used across the UI.
enum Format {
    /// "38m", "1h 12m", "3d 3h".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }

    static func resets(_ date: Date?, now: Date) -> String {
        guard let date else { return "reset time unknown" }
        return "resets in \(duration(date.timeIntervalSince(now)))"
    }

    static func age(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        return seconds < 60 ? "just now" : "\(duration(seconds)) old"
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "12% ahead" (bad) / "39% behind" (good) / "on pace".
    static func pace(_ pace: Pace) -> String {
        let delta = Int(pace.deltaPercent.rounded())
        if delta == 0 { return "on pace" }
        return delta > 0 ? "\(delta)% ahead" : "\(-delta)% behind"
    }

    static func money(_ minor: Int, exponent: Int, currency: String) -> String {
        let value = Decimal(minor) / pow(10, exponent)
        return value.formatted(.currency(code: currency).precision(.fractionLength(exponent)))
    }
}
