import ChatAPI
import ChatKit
import Foundation

extension ServiceBackend {
    /// Apply a bounded journal page atomically so historical outages do not
    /// appear between the recovery events already present in the same page.
    func receiveReplay(_ page: ServiceEventPage, generation: UUID) async throws {
        var position = cursor
        var events: [ChatEvent] = []
        for event in page.events {
            if let previous = position {
                if event.cursor.streamID == previous.streamID,
                   event.cursor.sequence <= previous.sequence {
                    continue
                }
                guard previous.sequence < UInt64.max,
                      event.cursor.streamID == previous.streamID,
                      event.cursor.sequence == previous.sequence + 1 else {
                    throw ServiceFailure.invalidResponse
                }
            }
            position = event.cursor
            events.append(event.event)
        }
        if let position, !events.isEmpty {
            try await deliverReplay(events, checkpoint: position, generation: generation)
        } else if page.events.isEmpty {
            try await deliverReplay([], checkpoint: page.checkpoint, generation: generation)
        }
    }

    private func deliverReplay(
        _ events: [ChatEvent], checkpoint: ServiceCursor, generation: UUID
    ) async throws {
        // One ACK advances only after the whole page's replica transaction.
        try await deliver(ChatDelivery(
            checkpoint: checkpoint.replicaCheckpoint, events: events,
            isSnapshot: false, isLive: false, clientTransportAvailable: true
        ), generation: generation)
    }
}
