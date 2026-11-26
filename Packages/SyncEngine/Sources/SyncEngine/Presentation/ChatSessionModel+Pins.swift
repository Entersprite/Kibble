import ChatKit
import Foundation

public extension ChatSessionModel {
    func refreshPins() {
        guard capabilities.canReadMessagePins, let conversation = selected,
              pinWork.mutation == nil else { return }
        guard case .connected = connectionState else { return }
        guard pinWork.read == nil else {
            pinWork.needsRefresh = true
            return
        }
        pinWork.needsRefresh = false
        let token = UUID()
        pinWork.token = token
        isLoadingPins = true
        pinWork.read = Task { [weak self, engine] in
            do {
                let value = try await engine.pinnedMessages(in: conversation)
                guard !Task.isCancelled, let self, pinWork.token == token,
                      selected == conversation else { return }
                pinWork.hasFreshPins = true
                pins = value
                pinsError = nil
                isLoadingPins = false
                pinWork.read = nil
                if pinWork.needsRefresh {
                    refreshPins()
                }
            } catch {
                guard !Task.isCancelled, let self, pinWork.token == token,
                      selected == conversation else { return }
                pinWork.hasFreshPins = false
                pins.canModify = false
                pinsError = "Could not refresh pinned messages."
                isLoadingPins = false
                pinWork.read = nil
            }
        }
    }

    func setPinned(_ pinned: Bool, message: Message) {
        guard capabilities.canReadMessagePins, pins.canModify, selected == message.conversationID,
              pinWork.mutation == nil else { return }
        pinWork.read?.cancel()
        pinWork.read = nil
        let token = UUID()
        pinWork.token = token
        let previous = pins
        pins.messages.removeAll { $0.id == message.id }
        if pinned {
            pins.messages.insert(message, at: 0)
        }
        isLoadingPins = true
        pinsError = nil
        pinWork.mutation = Task { [weak self, engine] in
            do {
                _ = try await engine.setMessagePinned(pinned, message: message)
                // Read through the query path too: this renews scoped media authority.
                let value = try await engine.pinnedMessages(in: message.conversationID)
                guard !Task.isCancelled, let self, pinWork.token == token,
                      selected == message.conversationID else { return }
                pins = value
                isLoadingPins = false
                pinWork.mutation = nil
                if pinWork.needsRefresh {
                    refreshPins()
                }
            } catch {
                guard !Task.isCancelled, let self, pinWork.token == token,
                      selected == message.conversationID else { return }
                pins = previous
                pinsError = "Could not confirm the pin change. Refresh pins before trying again."
                isLoadingPins = false
                pinWork.mutation = nil
                // Retire write permission until the confirmed collection can be read.
                pins.canModify = false
                refreshPins()
            }
        }
    }
}

extension ChatSessionModel {
    func watchPins(in conversation: Conversation.ID) {
        guard capabilities.canReadMessagePins else { return }
        conversationWatchers.append(observe(store.observeMessagePins(in: conversation)) { [weak self] saved in
            guard let self, selected == conversation else { return }
            if pinWork.mutation == nil, var cached = saved.pins {
                cached.canModify = pinWork.hasFreshPins && pins.canModify
                pins = cached
            }
            guard pinWork.revision != saved.revision else { return }
            pinWork.revision = saved.revision
            if pinWork.mutation != nil {
                pinWork.needsRefresh = true
            } else {
                refreshPins()
            }
        })
    }

    func resetPins() {
        pinWork.read?.cancel()
        pinWork.mutation?.cancel()
        pinWork = MessagePinWork()
        pins = PinnedMessages()
        pinsError = nil
        isLoadingPins = false
    }
}

struct MessagePinWork {
    var revision: Int64?
    var hasFreshPins = false
    var needsRefresh = false
    var token = UUID()
    var read: Task<Void, Never>?
    var mutation: Task<Void, Never>?
}
