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

    /// Whole-slice review, Critical 2: before the fix, `waitBeforeRetry`
    /// computed `Int(pow(2.0, Double(attempt - 1)))` with no bound on the
    /// exponent, and the 32-second cap two lines down was applied to the
    /// *result* of that conversion, never to the conversion itself. Attempt
    /// 63 is the last value that survives - confirmed standalone, outside
    /// this suite, so watching it trap could not abort the whole package's
    /// `swift test` run: `Int(pow(2.0, Double(62)))` is `4611686018427387904`.
    /// Attempt 64 traps: `pow(2.0, 63.0)` is 2^63, one more than `Int.max`,
    /// and `Int(_:)` on a `Double` that large is a hard fatal error, not a
    /// throw - `Fatal error: Double value cannot be converted to Int because
    /// the result would be greater than Int.max`, reproduced the same way
    /// before this fix landed, with `swift test --filter
    /// attemptSixtyFourNoLongerTraps` aborting the process rather than
    /// failing red. Nothing bounded `attempt` from reaching 64: the
    /// reconnect taxonomy removed the attempt ceiling that used to stop a
    /// recoverable failure outright (`ChannelSession`'s own "unbounded on
    /// purpose" doc comment), so an account stuck behind a captive portal or
    /// a Google outage reaches it in about half an hour of continuous
    /// failure.
    @Test("attempt 64 - the old trap point - lands on the same 32-second cap instead")
    func attemptSixtyFourNoLongerTraps() async throws {
        let recorder = Recorder()
        let policy = RetryPolicy(
            maxAttempts: 100,
            baseDelay: .milliseconds(500),
            sleep: { recorder.record($0) }
        )

        try await policy.waitBeforeRetry(attempt: 64)

        let slept = try #require(recorder.durations.first)
        #expect(slept == .seconds(32), "attempt 64 must saturate at the cap, not trap: \(slept)")
    }

    /// Attempt 63 was already the last attempt that did not trap before this
    /// fix - pinned here so the clamp this fix introduces cannot quietly
    /// start clamping one attempt too early and change behaviour that used to
    /// be safe.
    @Test("attempt 63 - the last value that survived before the fix - still saturates at the cap")
    func attemptSixtyThreeStillSaturates() async throws {
        let recorder = Recorder()
        let policy = RetryPolicy(
            maxAttempts: 100,
            baseDelay: .milliseconds(500),
            sleep: { recorder.record($0) }
        )

        try await policy.waitBeforeRetry(attempt: 63)

        let slept = try #require(recorder.durations.first)
        #expect(slept == .seconds(32), "attempt 63: \(slept)")
    }

    /// Something absurd, per the review's own instruction - not just past the
    /// old trap point, but as large as an `Int` can be.
    @Test("an absurd attempt count does not trap either")
    func absurdAttemptCountDoesNotTrap() async throws {
        let recorder = Recorder()
        let policy = RetryPolicy(
            maxAttempts: 100,
            baseDelay: .milliseconds(500),
            sleep: { recorder.record($0) }
        )

        try await policy.waitBeforeRetry(attempt: .max)

        let slept = try #require(recorder.durations.first)
        #expect(slept == .seconds(32), "Int.max: \(slept)")
    }
}
