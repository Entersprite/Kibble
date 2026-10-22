import ChatKit
import Foundation

/// One conversation's history urgency, kept while any read of it or any
/// person waiting for it holds it.
struct HeldHistoryUrgency {
    let urgency = WorkUrgency()
    var holders = 0
}

extension AccountRuntime {
    func withProviderWork<Value: Sendable>(
        epoch: UUID, urgency: WorkUrgency? = nil, _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        try await providerWork.acquire(id, owner: instanceID, urgency: urgency)
        do {
            try checkEpoch(epoch)
            let value = try await operation()
            await providerWork.release(id)
            return value
        } catch {
            await providerWork.release(id)
            throw error
        }
    }

    /// A provider history read of `conversation`. It is interactive while a
    /// person waits for that conversation's history, including after it queued.
    func withHistoryWork<Value: Sendable>(
        in conversation: Conversation.ID, epoch: UUID, _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let urgency = holdHistoryUrgency(conversation)
        defer { dropHistoryUrgency(conversation) }
        return try await withProviderWork(epoch: epoch, urgency: urgency, operation)
    }

    /// Marks a person as waiting for `conversation`'s history while `read`
    /// runs, and raises its reads that are already queued.
    func awaitingHistory<Value>(
        of conversation: Conversation.ID, _ read: () async throws -> Value
    ) async throws -> Value {
        let urgency = holdHistoryUrgency(conversation)
        urgency.raise()
        defer {
            urgency.lower()
            dropHistoryUrgency(conversation)
        }
        await providerWork.urgencyRaised()
        return try await read()
    }

    private func holdHistoryUrgency(_ conversation: Conversation.ID) -> WorkUrgency {
        var held = reads.historyUrgency[conversation] ?? HeldHistoryUrgency()
        held.holders += 1
        reads.historyUrgency[conversation] = held
        return held.urgency
    }

    private func dropHistoryUrgency(_ conversation: Conversation.ID) {
        guard var held = reads.historyUrgency[conversation] else { return }
        held.holders -= 1
        reads.historyUrgency[conversation] = held.holders > 0 ? held : nil
    }
}
