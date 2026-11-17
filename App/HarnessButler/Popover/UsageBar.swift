import HarnessButlerKit
import SwiftUI

/// Segmented "remaining" bar with a pace marker (U-4).
struct UsageBar: View {
    var remainingPercent: Double
    /// Where a linear burn would put "remaining" now; `nil` hides the marker.
    var paceRemainingPercent: Double?
    var color: Color
    var segments = 20
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 2
            let width = (geometry.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let filled = (remainingPercent / 100 * Double(segments)).rounded().displayInt
            ZStack(alignment: .leading) {
                HStack(spacing: gap) {
                    ForEach(0..<segments, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index < filled ? color : Color.secondary.opacity(0.2))
                            .frame(width: width)
                    }
                }
                if let pace = paceRemainingPercent {
                    // Outlined so it stays visible on pale (Grok) and dark segments alike.
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2, height: height + 4)
                        .overlay(Rectangle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 0.75))
                        .offset(x: max(0, min(geometry.size.width - 1.5, geometry.size.width * pace / 100)))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A small status ring shown before "% left".
struct StatusRing: View {
    var status: UsageStatus
    var stale: Bool

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: 1.5)
            .background(Circle().fill(status == .onTrack && !stale ? .clear : color))
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        if stale { return .secondary }
        return switch status {
        case .onTrack: Theme.ok
        case .atRisk: Theme.warn
        case .limited: Theme.bad
        }
    }
}

/// Provider logo on a tinted tile.
struct HarnessAvatar: View {
    var harness: Harness
    var size: CGFloat = 22

    var body: some View {
        Image(Theme.logoName(for: harness))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Theme.logoColor(for: harness))
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.color(for: harness).opacity(0.15)))
            .accessibilityLabel(harness.displayName)
    }
}
