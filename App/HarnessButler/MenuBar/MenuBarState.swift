import AppKit
import Observation

/// What Settings needs to know about the live status item (M-1).
@Observable
final class MenuBarState {
    /// Width of the status item's title in points.
    var width: CGFloat = 0
    /// macOS hides status items that don't fit (e.g. beside the notch); best-effort detection.
    var isLikelyHidden = false

    /// Above this the item risks being hidden on smaller or notched displays.
    static let wideThreshold: CGFloat = 220
    var isWide: Bool { width > Self.wideThreshold }
}
