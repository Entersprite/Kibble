import DesignSystem

public extension AppEnvironment {
    /// Drops reusable work under memory pressure without changing the visible
    /// transcript or its reading position. The durable replica remains intact.
    func releasePresentationCaches() {
        model?.releasePresentationCaches()
        MessageRenderingCache.clear()
    }
}
