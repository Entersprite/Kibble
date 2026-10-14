#if os(macOS)
    import AppKit

    /// Retain answers, not TextKit stacks. Width, padding, all attributed text
    /// and the minimum-line font are checked, including after a view rebuild.
    @MainActor
    final class MessageMeasurementCache {
        static let shared = MessageMeasurementCache()

        struct Key: Hashable {
            let text: NSAttributedString
            let width: CGFloat?
            let top, left, bottom, right: CGFloat
            let lineFont: NSFont

            init(text: NSAttributedString, width: CGFloat?, insets: NSEdgeInsets) {
                self.text = text
                self.width = width
                top = insets.top
                left = insets.left
                bottom = insets.bottom
                right = insets.right
                lineFont = .preferredFont(forTextStyle: .body)
            }
        }

        private let cache: BoundedRenderingCache<Key, CGSize>
        private(set) var hits = 0

        init(costLimit: Int = 24 * 1024 * 1024, countLimit: Int = 4000) {
            cache = BoundedRenderingCache(costLimit: costLimit, countLimit: countLimit)
        }

        func value(for key: Key) -> CGSize? {
            guard let size = cache.value(for: key) else { return nil }
            hits += 1
            return size
        }

        func insert(_ size: CGSize, for key: Key) {
            cache.insert(size, for: key, cost: 512 + key.text.length * 8)
        }

        func removeAll() {
            cache.removeAll()
            hits = 0
        }
    }
#endif
