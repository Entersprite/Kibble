import ChatAPI
import Foundation

extension AccountRuntime {
    func subscribe(after cursor: ServiceCursor?) throws -> AsyncThrowingStream<Data, any Error> {
        guard !stopped else { throw ServiceFailure.accountDisabled }
        guard !quarantinedForSubscription else { throw ServiceFailure.accountCleanupPending }
        guard subscribers.count < 64 else { throw ServiceFailure.overloaded }
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>
            .makeStream(bufferingPolicy: .bufferingOldest(8))
        let page = try storage.readEvents(after: cursor, limit: 256)
        let bytes = try ServiceCodec.encode(page)
        guard bytes.count <= 4 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
        continuation.yield(bytes)
        subscribers[id] = continuation
        if page.snapshot != nil {
            requestBackfill(replay: true)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    func publish(_ page: ServiceEventPage) throws {
        let bytes = try ServiceCodec.encode(page)
        guard bytes.count <= 4 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
        for (id, subscriber) in subscribers {
            switch subscriber.yield(bytes) {
            case .dropped:
                subscriber.finish(throwing: ServiceFailure.overloaded)
                subscribers[id] = nil
            case .terminated:
                subscribers[id] = nil
            case .enqueued: break
            @unknown default:
                subscriber.finish(throwing: ServiceFailure.invalidResponse)
                subscribers[id] = nil
            }
        }
    }
}
