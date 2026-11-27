import Foundation

/// A hand-arranged order for a list that otherwise shows its newest entries first.
public enum ManualOrder {
    /// `ids`, as they come, arranged by `order`: the entries it names follow in its order, after those it
    /// does not name yet. An empty order leaves `ids` as they come; names of entries that are gone are ignored.
    public static func arranged<ID: Hashable>(_ ids: [ID], by order: [ID]) -> [ID] {
        guard !order.isEmpty else { return ids }
        let present = Set(ids)
        var named = Set<ID>()
        let listed = order.filter { present.contains($0) && named.insert($0).inserted }
        return ids.filter { !named.contains($0) } + listed
    }

    /// The order to keep after the entries at `offsets` of an arranged list moved to `destination`, both as
    /// SwiftUI's `onMove` reports them: every entry shown, in its new place.
    public static func moving<ID: Hashable>(_ arranged: [ID], from offsets: IndexSet, to destination: Int) -> [ID] {
        let moving = offsets.filter { arranged.indices.contains($0) }
        guard !moving.isEmpty else { return arranged }
        let target = max(0, min(destination, arranged.count))
        var result = arranged.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        result.insert(contentsOf: moving.map { arranged[$0] }, at: target - moving.filter { $0 < target }.count)
        return result
    }
}
