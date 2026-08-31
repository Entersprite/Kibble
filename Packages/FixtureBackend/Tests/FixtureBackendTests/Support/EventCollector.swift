import ChatKit
import Foundation

/// Reads a backend's event stream on behalf of a test.
///
/// One collector per backend, created before anything is connected. That is not
/// a convenience: `ChatBackend.events` documents that an `AsyncStream` splits
/// its elements unpredictably across concurrent iterations, so a test with two
/// `for await` loops would see events vanish. Funnelling every assertion
/// through one iterator makes the suite obey the same single-consumer rule the
/// app has to.
///
/// `next(_:)` suspends until that many events have arrived. It has no timeout
/// of its own - the suites that use it carry a `.timeLimit` trait, so a backend
/// that stops emitting fails the run instead of hanging it.
actor EventCollector {
    /// Swift will not let an actor call a `mutating` async method on one of its
    /// own stored properties, which is what `AsyncIterator.next()` is. Holding
    /// the iterator in a reference box sidesteps that; the unchecked
    /// `Sendable` is honest because the actor is the only thing that touches it
    /// and its access is therefore already serialised.
    private final class IteratorBox: @unchecked Sendable {
        var iterator: AsyncStream<ChatEvent>.AsyncIterator

        init(_ iterator: AsyncStream<ChatEvent>.AsyncIterator) {
            self.iterator = iterator
        }
    }

    private let box: IteratorBox

    init(_ stream: AsyncStream<ChatEvent>) {
        box = IteratorBox(stream.makeAsyncIterator())
    }

    /// The next `count` events, in order.
    func next(_ count: Int = 1) async -> [ChatEvent] {
        var collected: [ChatEvent] = []
        for _ in 0 ..< count {
            guard let event = await box.iterator.next() else { break }
            collected.append(event)
        }
        return collected
    }

    /// The next event, or `nil` if the stream finished - which, for a
    /// conforming backend, it never should.
    func nextOne() async -> ChatEvent? {
        await next(1).first
    }
}
