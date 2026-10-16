import ChatKit
import Foundation

public extension SyncEngine {
    /// A single serialized worker coalesces draft activity while a request is outstanding.
    func updateTyping(_ update: TypingUpdate, in conversation: Conversation) {
        guard activityRunning, capabilities.canSendTypingState, !isGhosting else { return }
        typingIdle?.cancel()
        desiredTyping = update.isTyping && typingPrivacy.allows(conversation) ? update : nil
        if desiredTyping != nil {
            let idle = typingTiming.idle
            typingIdle = Task { [weak self] in
                do { try await Task.sleep(for: idle) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.endTyping()
            }
        }
        startTypingPublisher()
    }

    func endTyping(in conversation: Conversation.ID, thread: MessageThread.ID?) {
        guard desiredTyping?.conversationID == conversation, desiredTyping?.threadID == thread else { return }
        endTyping()
    }

    func endTyping() {
        desiredTyping = nil
        typingIdle?.cancel()
        startTypingPublisher()
    }

    func typingSettingsChanged() {
        // Settings can change while a start is on the wire. Its worker still sends the matching stop.
        endTyping()
    }

    private func startTypingPublisher() {
        guard typingPublisher == nil, activityRunning else { return }
        typingPublisherGeneration += 1
        let generation = typingPublisherGeneration
        typingPublisher = Task { [weak self] in await self?.publishTyping(generation: generation) }
    }

    private func publishTyping(generation: Int) async {
        defer {
            if generation == typingPublisherGeneration {
                typingPublisher = nil
            }
        }
        while activityRunning, !Task.isCancelled, generation == typingPublisherGeneration {
            if let sent = sentTyping, sent != desiredTyping {
                sentTyping = nil
                try? await backend.send(.setTyping(
                    conversationID: sent.conversationID,
                    threadID: sent.threadID,
                    isTyping: false
                ))
                continue
            }
            let renewing = desiredTyping != nil && desiredTyping == sentTyping
                && (typingLastSent?.duration(to: .now) ?? .zero) >= typingTiming.renewal
            guard let desired = desiredTyping, sentTyping == nil || renewing else { return }
            let conversation = (try? store.conversations())?.first { $0.id == desired.conversationID }
            guard let conversation, typingPrivacy.allows(conversation) else {
                desiredTyping = nil
                continue
            }
            do {
                try await backend.send(.setTyping(
                    conversationID: desired.conversationID,
                    threadID: desired.threadID,
                    isTyping: true
                ))
                // Remember an accepted start even if the desired context changed during the await.
                // The next iteration stops it before publishing another context.
                guard activityRunning, !Task.isCancelled,
                      generation == typingPublisherGeneration else { return }
                sentTyping = desired
                typingLastSent = .now
                if renewing {
                    return
                }
            } catch { return }
        }
    }
}
