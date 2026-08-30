import Foundation
import Testing
@testable import GChatBridgeCore

/// The channel state machine leans on this: a payload-truncation error means the
/// SID is expiring and must be re-registered *without* backoff, while a network
/// error must back off. Getting the delay schedule wrong is invisible until the
/// client is hammering Google during an outage, so it is pinned here.
@Suite("Retry policy")
struct RetryPolicyTests {
    /// Records what was slept instead of sleeping, so the schedule is asserted
    /// as data rather than as elapsed wall-clock time.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Duration] = []
        var durations: [Duration] {
            lock.withLock { storage }
        }

        func record(_ duration: Duration) {
            lock.withLock { storage.append(duration) }
        }
    }

    @Test("delay grows exponentially across attempts")
    func exponentialGrowth() async throws {
        let recorder = Recorder()
        let policy = RetryPolicy(
            maxAttempts: 5,
            baseDelay: .milliseconds(500),
            sleep: { recorder.record($0) }
        )

        for attempt in 1 ... 4 {
            try await policy.waitBeforeRetry(attempt: attempt)
        }

        let slept = recorder.durations
        #expect(slept.count == 4)
        // Jitter is additive and bounded at 250ms, so exact equality is wrong;
        // strict monotonic growth is the actual contract.
        for (earlier, later) in zip(slept, slept.dropFirst()) {
            #expect(later > earlier, "delay must grow: \(earlier) then \(later)")
        }
    }

    @Test("delay is capped so an outage cannot produce an unbounded wait")
    func capped() async throws {
        let recorder = Recorder()
        let policy = RetryPolicy(
            maxAttempts: 20,
            baseDelay: .seconds(1),
            sleep: { recorder.record($0) }
        )

        for attempt in 1 ... 12 {
            try await policy.waitBeforeRetry(attempt: attempt)
        }

        let longest = try #require(recorder.durations.max())
        #expect(longest <= .seconds(32), "cap breached: \(longest)")
    }

    @Test(".immediate keeps the attempt count but never waits")
    func immediateDoesNotWait() async throws {
        #expect(RetryPolicy.immediate.maxAttempts == RetryPolicy.default.maxAttempts)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            for attempt in 1 ... 4 {
                try await RetryPolicy.immediate.waitBeforeRetry(attempt: attempt)
            }
        }
        #expect(elapsed < .milliseconds(100), "immediate policy actually slept: \(elapsed)")
    }
}
