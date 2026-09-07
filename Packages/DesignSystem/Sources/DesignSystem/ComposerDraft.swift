import Foundation

/// The composer's draft text, and the one decision about it worth testing.
///
/// A value type because this package's rule is that views take values and hand
/// back callbacks: a `@State String` inside `Composer` is not reachable from a
/// test, and `ConnectionBanner.offersReconnect(for:)` is the shape this
/// follows - the decision is testable, the view is not asked to be.
///
/// It remembers what it last adopted, and that memory is the point. The host
/// clears its own copy of a failed draft once the composer reports adopting
/// it, but a redraw can still arrive carrying the same value - and re-adopting
/// would overwrite whatever the person has typed since.
public struct ComposerDraft: Equatable, Sendable {
    public private(set) var text = ""
    private var adopted: String?

    public init() {}

    public mutating func edit(_ text: String) {
        self.text = text
    }

    public mutating func clear() {
        text = ""
    }

    /// Adopts `restoring` if it is new, and says whether it did.
    ///
    /// A `nil` forgets what was adopted, so the same text failing a second
    /// time is offered again rather than silently dropped.
    public mutating func adopt(_ restoring: String?) -> Bool {
        guard let restoring, !restoring.isEmpty else {
            adopted = nil
            return false
        }
        guard restoring != adopted else { return false }
        text = restoring
        adopted = restoring
        return true
    }
}
