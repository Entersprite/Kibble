import Foundation

extension SyncEngine {
    /// A fresh bounded observation for each model attachment. Transport recovery
    /// also arrives on empty or already-applied replay pages; provider facts stay
    /// in the replica and are never replaced by a local retry diagnosis.
    public func clientTransportAvailability() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, sink) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        clientTransportObservers[id] = sink
        sink.yield(clientTransportAvailable)
        sink.onTermination = { [weak self] _ in
            Task { await self?.removeClientTransportObserver(id) }
        }
        return stream
    }

    func updateClientTransport(_ available: Bool) {
        guard available != clientTransportAvailable else { return }
        clientTransportAvailable = available
        for observer in clientTransportObservers.values {
            observer.yield(available)
        }
        if available, tracksMessageDelivery {
            do {
                try startDeliveryReconciliation(store.messageDeliveries())
            } catch {
                record(error)
            }
        }
    }

    private func removeClientTransportObserver(_ id: UUID) {
        clientTransportObservers[id] = nil
    }
}
