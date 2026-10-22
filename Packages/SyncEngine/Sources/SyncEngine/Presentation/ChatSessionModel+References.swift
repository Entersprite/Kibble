import ChatKit
import Foundation

/// Opening what a quote, a forward or a link points at.
public extension ChatSessionModel {
    /// Visible quote cards share a serialized queue, with at most 128 pending
    /// addresses and 128 cached account-local results. An unresolved URL is
    /// display data, never authority.
    func messageReferencePreview(_ address: MessageAddress) async -> (quote: MessageQuote, author: Member?)? {
        guard conversations.contains(where: { $0.id == address.conversation }) else { return nil }
        if let cached = referenceWork.cached[address] {
            return cached.value
        }
        if let pending = referenceWork.previewTasks[address] {
            let generation = referenceWork.generation
            let value = await pending.value
            guard !Task.isCancelled, referenceWork.generation == generation,
                  conversations.contains(where: { $0.id == address.conversation }) else { return nil }
            return value
        }
        guard referenceWork.previewTasks.count < 128 else { return nil }
        let generation = referenceWork.generation
        let previous = referenceWork.previewTail
        let task = Task { [engine] in
            await previous?.value
            guard !Task.isCancelled else { return nil as MessageReferenceWork.Preview? }
            return try? await engine.referencedMessagePreview(address)
        }
        referenceWork.previewTasks[address] = task
        referenceWork.previewTail = Task { _ = await task.value }
        let value = await task.value
        guard referenceWork.generation == generation else { return nil }
        referenceWork.previewTasks[address] = nil
        referenceWork.cache(value, for: address)
        guard !Task.isCancelled, conversations.contains(where: { $0.id == address.conversation })
        else { return nil }
        return value
    }

    /// Opens the addressed message where it lives, as a search hit opens:
    /// its conversation scrolled to it and marked, or its thread for a reply.
    /// An address with no message opens its conversation.
    ///
    /// Nothing happens for a conversation this account does not have, or a
    /// message neither the store nor its thread's listing holds, and nothing
    /// moves once the person has gone to another conversation meanwhile. The
    /// message is found before anything is selected, so a miss leaves the
    /// window as it was.
    func openReferencedMessage(_ address: MessageAddress) {
        guard conversations.contains(where: { $0.id == address.conversation }) else { return }
        referenceWork.openTask?.cancel()
        referenceWork.openTask = nil
        guard let id = address.message else {
            select(address.conversation)
            return
        }
        let conversation = address.conversation
        let origin = selected
        let originGeneration = transcriptWork.generation
        let limit = searchWork.historyPageLimit
        referenceWork.openTask = Task { @MainActor [weak self, engine] in
            let found = try? await engine.referencedMessage(id, thread: address.thread, in: conversation)
            guard !Task.isCancelled, let self, let found, selected == origin,
                  transcriptWork.generation == originGeneration else { return }
            let target = try? await engine.loadHistory(in: conversation, until: found, pageLimit: limit)
            guard !Task.isCancelled, selected == origin,
                  transcriptWork.generation == originGeneration,
                  conversations.contains(where: { $0.id == conversation }), let target else { return }
            if selected != conversation || selectedMeetingSeries != nil {
                select(conversation)
            }
            land(on: target)
            var state = search
            state.highlight = target.message.id
            state.openGeneration += 1
            search = state
        }
    }
}

/// The open in flight. `stop()` cancels it.
struct MessageReferenceWork {
    typealias Preview = (quote: MessageQuote, author: Member?)
    struct CachedPreview { let value: Preview? }

    var openTask: Task<Void, Never>?
    var previewTasks: [MessageAddress: Task<Preview?, Never>] = [:]
    var previewTail: Task<Void, Never>?
    var cached: [MessageAddress: CachedPreview] = [:]
    var order: [MessageAddress] = []
    var generation = 0

    mutating func cache(_ value: Preview?, for address: MessageAddress) {
        if cached[address] == nil {
            order.append(address)
        }
        cached[address] = CachedPreview(value: value)
        if order.count > 128 {
            cached[order.removeFirst()] = nil
        }
    }

    mutating func reset() {
        openTask?.cancel()
        openTask = nil
        for task in previewTasks.values {
            task.cancel()
        }
        previewTasks = [:]
        previewTail?.cancel()
        previewTail = nil
        cached = [:]
        order = []
        generation += 1
    }
}
