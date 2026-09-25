import ChatKit
import Synchronization

/// Whether a read position may be published, and for which conversations.
public enum ReadReceiptPolicy: Sendable, Equatable {
    /// Every mark goes out - the default, and every test's, since before rules existed.
    case publish
    /// No account is identified yet, so its saved rules cannot be known -
    /// `CLAUDE.md`'s "assume less, never more" (spec §3.1).
    case withhold
    /// Resolve each mark's conversation against these settings.
    case resolve(NotificationSettings)
}

/// The receipts half of `SyncEngine.submit(_:)`'s chokepoint.
///
/// **A box, read at submit time, not a value pushed into the actor.** The
/// settings model writes it synchronously from the main actor; the engine
/// reads it when a mark is actually submitted. So a rule switched off during a
/// mark's two-second wait still stops that mark, and two quick edits cannot
/// arrive at the engine out of order.
public final class ReadReceiptGate: Sendable {
    private let state = Mutex<ReadReceiptPolicy>(.publish)

    public init() {}

    public var policy: ReadReceiptPolicy {
        state.withLock { $0 }
    }

    public func set(_ policy: ReadReceiptPolicy) {
        state.withLock { $0 = policy }
    }
}
