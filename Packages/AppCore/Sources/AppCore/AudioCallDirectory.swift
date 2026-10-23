import ChatKit
import Foundation
import SyncEngine

extension AppEnvironment {
    func startCalls(service: (any AudioCallService)?, model: ChatSessionModel) {
        calls.start(service: service, directory: {
            AudioCallRecipient.directory(
                conversations: model.conversations, members: model.directory, me: model.me
            )
        })
        guard service != nil, model.capabilities.canDiscoverCalls else { return }
        calls.discovery.start(watching: { [weak self, weak model] in
            guard let self, let model else { return .init() }
            return callWatch(model)
        }, fetch: { [weak model] id in
            try await model?.callAvailability(in: id)
        })
    }

    /// The conversation on screen, while the window is seen and its calls can
    /// be joined: nothing else is asked about. Not the one this session is in
    /// a call in, which offers Return to Call whatever the answer; its call
    /// ending asks again.
    private func callWatch(_ model: ChatSessionModel) -> CallDiscoveryMonitor.Watch {
        guard isViewing, !model.showingMentions, !model.threads.showingList,
              let id = model.selected, calls.activeConversationID != id,
              let conversation = model.conversations.first(where: { $0.id == id }) else { return .init() }
        let joinable = switch conversation.kind {
        case .directMessage: calls.supportsExistingJoin
        case .space, .groupDirectMessage: calls.supportsConversationCalls
        default: false
        }
        guard joinable else { return .init() }
        return .init(
            conversation: id,
            inCall: calls.activeConversationID != nil,
            latestCallMessage: model.messages.last(where: { $0.callStatus != nil })?.id
        )
    }
}
