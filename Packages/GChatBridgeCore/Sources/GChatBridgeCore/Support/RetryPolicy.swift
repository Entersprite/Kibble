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

    func waitBeforeRetry(attempt: Int) async throws {
        guard baseDelay > .zero else {
            try await sleep(.zero)
            return
        }
        let exponential = baseDelay * Int(pow(2.0, Double(attempt - 1)))
        // Jitter spreads retries so concurrent callers do not resynchronise.
        let jitter = Duration.milliseconds(Int.random(in: 0 ... 250))
        try await sleep(min(exponential + jitter, .seconds(32)))
    }
}
