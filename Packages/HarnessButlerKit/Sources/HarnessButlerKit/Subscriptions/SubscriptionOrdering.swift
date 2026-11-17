import Foundation

/// List reordering with SwiftUI `onMove` semantics, without depending on SwiftUI.
public enum SubscriptionOrdering {
    public static func moving<T>(_ items: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        var items = items
        let moving = source.map { items[$0] }
        let insertAt = destination - source.count(in: 0..<destination)
        for index in source.reversed() { items.remove(at: index) }
        items.insert(contentsOf: moving, at: insertAt)
        return items
    }

    /// Apply a move expressed in pinned-only offsets; unpinned items stay where they are.
    public static func movingPinned(_ subscriptions: [Subscription], fromOffsets source: IndexSet, toOffset destination: Int) -> [Subscription] {
        let slots = subscriptions.indices.filter { subscriptions[$0].isPinned }
        let reordered = moving(slots.map { subscriptions[$0] }, fromOffsets: source, toOffset: destination)
        var result = subscriptions
        for (slot, subscription) in zip(slots, reordered) { result[slot] = subscription }
        return result
    }
}
