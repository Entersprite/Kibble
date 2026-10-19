import ChatKit
import ChatPersistence
import Foundation

struct TypingKey: Hashable {
    var conversation: Conversation.ID
    var thread: MessageThread.ID?
    var member: Member.ID
    init(_ update: TypingUpdate) {
        conversation = update.conversationID
        thread = update.threadID
        member = update.member
    }
}

struct TypingLease {
    var update: TypingUpdate
    var deadline: ContinuousClock.Instant
}

extension SyncEngine {
    func processActivity(_ event: ChatEvent) {
        switch event {
        case let .scopedTypingChanged(update):
            trackTyping(update)
        case let .typingChanged(conversation, member, typing):
            let update = TypingUpdate(conversationID: conversation, member: member, isTyping: typing)
            try? store.apply([.setScopedTyping(update)])
            trackTyping(update)
        case let .messageReceived(message):
            clearTyping { $0.conversation == message.conversationID && $0.member == message.sender
                && $0.thread == (message.isReply ? message.threadID : nil)
            }
        case let .conversationRemoved(id, _):
            clearTyping { $0.conversation == id }
        case let .connectionStateChanged(state):
            if state != .connected {
                typingLeases = [:]
                typingExpiry?.cancel()
                try? store.apply([.clearActivityTyping])
                desiredTyping = nil
                sentTyping = nil
                typingIdle?.cancel()
            }
        default: break
        }
    }

    func trackTyping(_ update: TypingUpdate) {
        let key = TypingKey(update)
        if let prior = typingLeases[key]?.update.version, let next = update.version, next < prior {
            return
        }
        if update.isTyping {
            if typingLeases.count >= 256, typingLeases[key] == nil, let oldest = typingLeases.min(by: {
                $0.value.deadline < $1.value.deadline
            })?.key {
                clearTyping { $0 == oldest }
            }
            typingLeases[key] = TypingLease(update: update, deadline: .now.advanced(by: typingTiming.expiry))
        } else {
            typingLeases[key] = nil
        }
        scheduleTypingExpiry()
    }

    func clearTyping(where matches: (TypingKey) -> Bool) {
        for key in typingLeases.keys.filter(matches) {
            guard var update = typingLeases.removeValue(forKey: key)?.update else { continue }
            update.isTyping = false
            var writes: [StoreWrite] = [.setScopedTyping(update)]
            if key.thread == nil {
                writes.append(.setTyping(conversation: key.conversation, member: key.member, isTyping: false))
            }
            try? store.apply(writes)
        }
    }

    func scheduleTypingExpiry() {
        typingExpiry?.cancel()
        guard let deadline = typingLeases.values.map(\.deadline).min() else { return }
        typingExpiry = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self else { return }
            await expireTyping()
        }
    }

    private func expireTyping() {
        let now = ContinuousClock.now
        let expired = Set(typingLeases.filter { $0.value.deadline <= now }.map(\.key))
        clearTyping { expired.contains($0) }
        scheduleTypingExpiry()
    }
}
