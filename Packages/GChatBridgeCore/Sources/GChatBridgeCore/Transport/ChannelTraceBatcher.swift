import Foundation

/// Groups a sequence of individual byte arrivals into batches, the way a
/// network read actually delivers them - a burst of bytes arriving together,
/// then a pause, then the next burst.
///
/// **Why this exists.** `URLSessionTransport.stream()` iterates
/// `session.bytes(for:)` one byte at a time, so two bytes drawn from the same
/// underlying socket read arrive back-to-back with a near-zero gap, while two
/// bytes from different reads are separated by however long the read actually
/// waited. Logging every byte would be enormous and would not answer the
/// question this instrument exists for; logging the *batches* answers it
/// directly - if Google's long-poll response is being delivered to this
/// process in fixed-size steps (roughly 512 bytes, per the URL-loading-system
/// buffering hypothesis this instrument is built to test), the batch sizes
/// show it, and if it is not, they show that instead.
///
/// **Pure.** No clock is read in here - every timestamp is a parameter - which
/// is what makes this directly testable with a synthetic sequence
/// (`ChannelTraceBatcherTests`) rather than only through a real socket's
/// actual timing.
public struct ChannelTraceBatcher: Sendable {
    /// Gaps at or below this are "the same batch": noise from the loop itself
    /// (`Task` scheduling, `AsyncThrowingStream.Continuation.yield`) rather
    /// than a genuine pause in delivery.
    ///
    /// **5 milliseconds**, chosen for the two-orders-of-magnitude gap between
    /// what it has to separate: consecutive bytes drawn from one buffered
    /// async-bytes read (`URLSessionTransport.stream()`'s own source) cross no
    /// I/O boundary at all between them and are sub-millisecond apart in
    /// practice, while the shortest real wait
    /// for the *next* network read - even on a fast, otherwise-idle
    /// connection - is measured in tens of milliseconds. 5 ms sits an order of
    /// magnitude above the first and comfortably below the second, so it does
    /// not need to be exact to work; it only needs to sit somewhere in that
    /// gap, and the two are far enough apart that almost any value in between
    /// would do.
    public static let gapThreshold: Duration = .milliseconds(5)

    /// When the batch currently open started, and how many bytes it has seen
    /// so far. `nil`/`0` before the first byte of the whole stream arrives.
    private var batchStart: ContinuousClock.Instant?
    private var batchByteCount = 0
    /// When the most recent byte arrived, so the next arrival's gap can be
    /// measured against it.
    private var lastArrival: ContinuousClock.Instant?
    /// When the previous *closed* batch's last byte arrived - `nil` until the
    /// first batch closes, which is why that batch's own `gapSincePrevious` is
    /// `.zero` rather than measured against nothing.
    private var previousBatchEnd: ContinuousClock.Instant?

    public init() {}

    /// `byteCount` bytes arrived together at `instant`. Defaults to `1` for
    /// `URLSessionTransport`'s real usage, which calls this once per byte;
    /// taking a count at all is what keeps this reusable for a transport that
    /// hands over bigger chunks without changing its arithmetic.
    ///
    /// Returns the batch that just closed, if this arrival's gap from the
    /// previous one exceeded `gapThreshold` - `nil` means this arrival
    /// extended the batch already open, including the very first arrival of
    /// the stream, which has no previous batch to close.
    public mutating func arrived(
        at instant: ContinuousClock.Instant,
        byteCount: Int = 1
    ) -> ChannelTraceBatch? {
        guard let openStart = batchStart, let last = lastArrival else {
            // The stream's first byte: open the first batch. Nothing closes.
            batchStart = instant
            lastArrival = instant
            batchByteCount = byteCount
            return nil
        }
        guard instant - last > Self.gapThreshold else {
            // Still inside the batch that is already open.
            batchByteCount += byteCount
            lastArrival = instant
            return nil
        }
        let closed = ChannelTraceBatch(
            byteCount: batchByteCount,
            gapSincePrevious: previousBatchEnd.map { openStart - $0 } ?? .zero,
            start: openStart,
            end: last
        )
        previousBatchEnd = last
        batchStart = instant
        lastArrival = instant
        batchByteCount = byteCount
        return closed
    }

    /// The stream ended - cleanly or not - so whatever batch was still open
    /// has to be flushed rather than lost. `nil` only when `arrived` was
    /// never called at all: a stream that delivered zero bytes.
    public mutating func flush() -> ChannelTraceBatch? {
        guard let openStart = batchStart, let lastArrival, batchByteCount > 0 else { return nil }
        let closed = ChannelTraceBatch(
            byteCount: batchByteCount,
            gapSincePrevious: previousBatchEnd.map { openStart - $0 } ?? .zero,
            start: openStart,
            end: lastArrival
        )
        batchStart = nil
        batchByteCount = 0
        self.lastArrival = nil
        return closed
    }
}
