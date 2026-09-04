import Foundation
import Testing
@testable import GChatBridgeCore

/// `ChannelTraceBatcher` is pure - no clock, no I/O - so every arrival here is
/// a synthetic instant built by advancing one fixed starting point, never
/// `ContinuousClock.now` read mid-test. That is what makes these assertions
/// exact rather than "probably fast enough on this machine".
struct ChannelTraceBatcherTests {
    private let start = ContinuousClock.now

    // MARK: - The boundary itself

    /// A gap of exactly `gapThreshold` is still the same batch - the batcher's
    /// own contract is "larger than", not "at least", so this is the one
    /// value most likely to flip on an off-by-one.
    @Test func aGapExactlyAtTheThresholdStaysInTheSameBatch() {
        var batcher = ChannelTraceBatcher()
        #expect(batcher.arrived(at: start) == nil)
        let closed = batcher.arrived(at: start + ChannelTraceBatcher.gapThreshold)
        #expect(closed == nil)
        #expect(batcher.flush()?.byteCount == 2)
    }

    /// One tick past the threshold closes the batch that was open.
    @Test func aGapOneTickPastTheThresholdClosesTheBatch() {
        var batcher = ChannelTraceBatcher()
        #expect(batcher.arrived(at: start) == nil)
        let closed = batcher.arrived(at: start + ChannelTraceBatcher.gapThreshold + .nanoseconds(1))
        #expect(closed?.byteCount == 1)
        #expect(closed?.start == start)
    }

    // MARK: - A single-byte batch

    /// A batch that opens and is immediately closed by the next arrival's gap
    /// carries exactly one byte - the smallest batch this type can produce.
    @Test func aSingleByteBatchReportsOneByte() {
        var batcher = ChannelTraceBatcher()
        _ = batcher.arrived(at: start)
        let closed = batcher.arrived(at: start + .milliseconds(50))
        #expect(closed?.byteCount == 1)
        #expect(closed?.gapSincePrevious == .zero) // the first batch has no predecessor
    }

    // MARK: - One long run with no gaps

    /// A thousand arrivals with no gap between any two never close a batch on
    /// their own - only `flush()` at the stream's end reports it, with every
    /// byte accounted for.
    @Test func oneLongRunWithNoGapsStaysOneBatchUntilFlushed() {
        var batcher = ChannelTraceBatcher()
        var instant = start
        for _ in 0 ..< 1000 {
            let closed = batcher.arrived(at: instant)
            #expect(closed == nil)
            instant += .microseconds(1)
        }
        let flushed = batcher.flush()
        #expect(flushed?.byteCount == 1000)
        #expect(flushed?.start == start)
        // Flushing again reports nothing: there is no batch left open.
        #expect(batcher.flush() == nil)
    }

    // MARK: - Several batches in sequence

    /// The property the whole instrument is built on: consecutive batches
    /// each carry the right byte count and the right gap from the one before,
    /// not just the first one.
    @Test func consecutiveBatchesCarryTheGapSincePreviousCorrectly() {
        var batcher = ChannelTraceBatcher()
        _ = batcher.arrived(at: start) // batch 1 opens
        _ = batcher.arrived(at: start + .microseconds(1)) // batch 1, still inside

        let secondBatchStart = start + .milliseconds(20)
        let firstClosed = batcher.arrived(at: secondBatchStart) // closes batch 1, opens batch 2
        #expect(firstClosed?.byteCount == 2)
        #expect(firstClosed?.start == start)
        #expect(firstClosed?.gapSincePrevious == .zero)

        let thirdBatchStart = secondBatchStart + .milliseconds(30)
        let secondClosed = batcher.arrived(at: thirdBatchStart) // closes batch 2, opens batch 3
        #expect(secondClosed?.byteCount == 1)
        #expect(secondClosed?.start == secondBatchStart)
        // Measured from batch 1's LAST byte (secondBatchStart's predecessor's
        // last arrival, which is start + 1µs), not from batch 1's start.
        #expect(secondClosed?.gapSincePrevious == secondBatchStart - (start + .microseconds(1)))

        let thirdClosed = batcher.flush()
        #expect(thirdClosed?.byteCount == 1)
        #expect(thirdClosed?.start == thirdBatchStart)
        // Measured from batch 2's last (and only) byte, at secondBatchStart.
        #expect(thirdClosed?.gapSincePrevious == thirdBatchStart - secondBatchStart)
    }

    // MARK: - Nothing ever arrived

    @Test func flushingBeforeAnyArrivalReportsNothing() {
        var batcher = ChannelTraceBatcher()
        #expect(batcher.flush() == nil)
    }
}
