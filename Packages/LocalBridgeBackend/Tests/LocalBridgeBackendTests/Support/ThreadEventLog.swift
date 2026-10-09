import ChatKit
import Foundation
@testable import LocalBridgeBackend

/// Every event a backend emits, from one iterator for the whole test
/// (`CLAUDE.md`: canceling a task suspended in `next()` finishes the stream),
/// with a bounded wait for one that matches. A wait that never matches returns
/// `nil` after `within`, and the test's `#require` fails rather than hangs.
actor ThreadEventLog {
    private(set) var events: [ChatEvent] = []

    init(_ backend: LocalBridgeBackend) {
        Task { await self.pump(backend) }
    }

    private func pump(_ backend: LocalBridgeBackend) async {
        for await event in backend.events {
            events.append(event)
        }
    }

    func first(
        where matches: @Sendable (ChatEvent) -> Bool,
        within limit: Duration = .seconds(2)
    ) async -> ChatEvent? {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if let found = events.first(where: matches) {
                return found
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return events.first(where: matches)
    }

    /// The thread changes seen so far, in order.
    func threadChanges() -> [ThreadChange] {
        events.compactMap { event in
            if case let .threadChanged(_, _, change) = event {
                change
            } else {
                nil
            }
        }
    }
}
