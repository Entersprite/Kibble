#if os(macOS)
    import AppKit
    import Testing
    @testable import DesignSystem

    @MainActor
    struct BoundedRenderingCacheTests {
        /// Every key hashes alike: equality, not the hash, must choose a hit.
        private struct Colliding: Hashable {
            let value: Int
            func hash(into hasher: inout Hasher) {
                hasher.combine(0)
            }
        }

        @Test func hitsPromoteEntriesAndCostEvictsLeastRecentlyUsed() {
            let cache = BoundedRenderingCache<Colliding, String>(costLimit: 10, countLimit: 3)
            cache.insert("first", for: Colliding(value: 1), cost: 4)
            cache.insert("second", for: Colliding(value: 2), cost: 4)
            #expect(cache.value(for: Colliding(value: 1)) == "first")
            cache.insert("third", for: Colliding(value: 3), cost: 4)
            #expect(cache.value(for: Colliding(value: 2)) == nil)
            #expect(cache.value(for: Colliding(value: 1)) == "first")
            #expect(cache.value(for: Colliding(value: 3)) == "third")
            #expect(cache.count == 2)
            #expect(cache.cost == 8)
        }

        @Test func countLimitOversizedValuesReplacementAndClearingAreBounded() {
            let cache = BoundedRenderingCache<Int, String>(costLimit: 100, countLimit: 2)
            cache.insert("a", for: 1, cost: 1)
            cache.insert("b", for: 2, cost: 1)
            cache.insert("c", for: 3, cost: 1)
            #expect(cache.value(for: 1) == nil)
            cache.insert("updated", for: 2, cost: 10)
            #expect(cache.value(for: 2) == "updated")
            #expect(cache.cost == 11)
            cache.insert("oversized", for: 4, cost: 101)
            #expect(cache.count == 2)
            #expect(cache.value(for: 4) == nil)
            cache.removeAll()
            #expect(cache.isEmpty)
            #expect(cache.cost == 0)
            #expect(cache.value(for: 2) == nil)
        }
    }
#endif
