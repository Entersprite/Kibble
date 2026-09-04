import Foundation

/// Bounded exponential backoff for retryable failures (429 and 5xx).
///
/// The sleep function is injectable so tests exercise the retry logic without
/// actually waiting.
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: Duration
    public let sleep: @Sendable (Duration) async throws -> Void

    public init(
        maxAttempts: Int,
        baseDelay: Duration,
        sleep: @Sendable @escaping (Duration) async throws -> Void
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.sleep = sleep
    }

    /// Google's documented guidance: exponential backoff with jitter, capped.
    public static let `default` = RetryPolicy(
        maxAttempts: 4,
        baseDelay: .milliseconds(500),
        sleep: { try await Task.sleep(for: $0) }
    )

    /// Same attempt count, no waiting. For tests.
    public static let immediate = RetryPolicy(
        maxAttempts: 4,
        baseDelay: .zero,
        sleep: { _ in }
    )

    /// The exponent is clamped to this before the `Double` -> `Int`
    /// conversion, not after. `Int(pow(2.0, Double(attempt - 1)))` traps once
    /// `attempt` reaches 64 - `pow(2.0, 63.0)` is 2^63, one more than
    /// `Int.max`, and `Int(_:)` on a `Double` that large is a hard fatal
    /// error, not a throw (confirmed by execution: attempt 63 survives,
    /// attempt 64 traps with "Double value cannot be converted to Int
    /// because the result would be greater than Int.max"). The 32-second cap
    /// below is applied to the *result* of the multiply, so it never
    /// protected this conversion, and nothing bounds `attempt` from reaching
    /// 64: the reconnect taxonomy removed the attempt ceiling that used to
    /// stop a recoverable failure outright, so a captive portal, a DNS
    /// failure, or a Google outage reaches it in about half an hour of
    /// continuous failure.
    ///
    /// 32 is a wide margin, not a tight fit. With `RetryPolicy.default`'s
    /// 500ms base, the delay already saturates at attempt 7 (`2^6 * 500ms ==
    /// 32s`), so every attempt below that never approaches this clamp and is
    /// completely unaffected by it, and every attempt at or beyond it already
    /// produces a result far past the 32-second cap whether the exponent is
    /// clamped here or not - `min(_:.seconds(32))` below lands on exactly the
    /// same 32 seconds either way. `Int(pow(2.0, 32.0))` is a few billion,
    /// nowhere near where the `Int` conversion or the `Duration` multiply
    /// that follows could themselves overflow, so this is safe for every
    /// `attempt`, including `Int.max`.
    private static let maxExponent = 32

    func waitBeforeRetry(attempt: Int) async throws {
        guard baseDelay > .zero else {
            try await sleep(.zero)
            return
        }
        let exponent = min(attempt - 1, Self.maxExponent)
        let exponential = baseDelay * Int(pow(2.0, Double(exponent)))
        // Jitter spreads retries so concurrent callers do not resynchronise.
        let jitter = Duration.milliseconds(Int.random(in: 0 ... 250))
        try await sleep(min(exponential + jitter, .seconds(32)))
    }
}
