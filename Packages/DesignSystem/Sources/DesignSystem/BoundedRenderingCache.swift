#if os(macOS)
    import Foundation

    /// A deterministic cost- and count-bounded LRU. Hits and eviction both
    /// take constant time; a hit never rebuilds an ordered key array.
    @MainActor
    final class BoundedRenderingCache<Key: Hashable, Value> {
        private final class Entry {
            let key: Key
            let value: Value
            let cost: Int
            weak var previous: Entry?
            var next: Entry?

            init(key: Key, value: Value, cost: Int) {
                self.key = key
                self.value = value
                self.cost = cost
            }
        }

        private let costLimit: Int
        private let countLimit: Int
        private var entries: [Key: Entry] = [:]
        private var oldest: Entry?
        private var newest: Entry?
        private(set) var cost = 0
        var count: Int {
            entries.count
        }

        var isEmpty: Bool {
            entries.isEmpty
        }

        init(costLimit: Int, countLimit: Int) {
            self.costLimit = max(0, costLimit)
            self.countLimit = max(0, countLimit)
        }

        func value(for key: Key) -> Value? {
            guard let entry = entries[key] else { return nil }
            unlink(entry)
            append(entry)
            return entry.value
        }

        func insert(_ value: Value, for key: Key, cost: Int) {
            if let previous = entries.removeValue(forKey: key) {
                unlink(previous)
                self.cost -= previous.cost
            }
            let cost = max(1, cost)
            guard countLimit > 0, cost <= costLimit else { return }
            let entry = Entry(key: key, value: value, cost: cost)
            entries[key] = entry
            append(entry)
            self.cost += cost
            while entries.count > countLimit || self.cost > costLimit {
                guard let entry = oldest else { break }
                unlink(entry)
                entries.removeValue(forKey: entry.key)
                self.cost -= entry.cost
            }
        }

        func removeAll() {
            // Break the forward chain iteratively, avoiding recursive release
            // of thousands of retained entries on account teardown.
            while let entry = oldest {
                unlink(entry)
            }
            entries.removeAll(keepingCapacity: false)
            cost = 0
        }

        private func unlink(_ entry: Entry) {
            if let previous = entry.previous {
                previous.next = entry.next
            } else {
                oldest = entry.next
            }
            if let next = entry.next {
                next.previous = entry.previous
            } else {
                newest = entry.previous
            }
            entry.previous = nil
            entry.next = nil
        }

        private func append(_ entry: Entry) {
            entry.previous = newest
            newest?.next = entry
            newest = entry
            if oldest == nil {
                oldest = entry
            }
        }
    }

#endif

/// The host clears reusable rendering work at account teardown and under
/// memory pressure. Only immutable text and measurements are retained;
/// these caches own no views, actions, account services or tasks.
@MainActor
public enum MessageRenderingCache {
    public static func clear() {
        #if os(macOS)
            MessageTextCache.shared.removeAll()
            MessageMeasurementCache.shared.removeAll()
        #endif
    }
}
