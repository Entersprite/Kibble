import ChatKit
import Foundation
import GChatBridgeCore

/// A reaction push is a trigger, never the source of truth (reactions spec
/// §2.2): wait, then ask `list_messages` for the message and emit the server's
/// complete set.
///
/// **Coalesced per message.** Requests during the wait are absorbed; a request
/// during the fetch earns exactly one more fetch. A burst costs at most two
/// calls. The wait (`defaultReactionRefetchDelay`) also keeps a refetch from
/// running ahead of Google's commit of the person's own reaction; that one
/// second is enough is `[Verify]`, the §36.7 family.
///
/// A failed call, or a message not on the page, emits nothing: a missing
/// count is not something a person can act on, and history corrects it.
extension LocalBridgeBackend {
    static let defaultReactionRefetchDelay: Duration = .seconds(1)
    static let reactionRefetchPageSize: Int32 = 50

    enum ReactionRefetchPhase { case waiting, fetching(again: Bool) }

    struct ReactionRefetches {
        var phases: [ChatKit.Message.ID: ReactionRefetchPhase] = [:]
        var tasks: [ChatKit.Message.ID: Task<Void, Never>] = [:]
    }

    func requestReactionRefetch(_ target: ReactedMessage) {
        switch reactionRefetches.phases[target.messageID] {
        case .waiting?:
            return
        case .fetching?:
            reactionRefetches.phases[target.messageID] = .fetching(again: true)
        case nil:
            startReactionRefetch(target)
        }
    }

    /// `disconnect()` and `channelStopped` both call this: nothing waits or
    /// fetches into the next session.
    func forgetReactionRefetches() {
        reactionRefetches.tasks.values.forEach { $0.cancel() }
        reactionRefetches = ReactionRefetches()
    }

    private func startReactionRefetch(_ target: ReactedMessage) {
        reactionRefetches.phases[target.messageID] = .waiting
        let generation = directoryGeneration
        let delay = reactionRefetchDelay
        reactionRefetches.tasks[target.messageID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.runReactionRefetch(target, generation: generation)
        }
    }

    private func runReactionRefetch(_ target: ReactedMessage, generation: Int) async {
        guard !Task.isCancelled, generation == directoryGeneration else { return }
        guard let apiClient else {
            finishReactionRefetch(target)
            return
        }
        reactionRefetches.phases[target.messageID] = .fetching(again: false)
        var request = ListMessagesRequest()
        request.requestHeader = APIRequestHeader.make()
        request.parentID = target.parent
        request.pageSize = Self.reactionRefetchPageSize
        let response = try? await apiClient.call(.listMessages, request)
        guard !Task.isCancelled, generation == directoryGeneration else { return }
        if let wire = response?.messages.first(where: { $0.id.messageID == target.messageID.rawValue }),
           let message = ChannelEventMapping.domainMessage(wire) {
            emit(.reactionChanged(messageID: target.messageID, reactions: message.reactions))
        }
        let again = if case .fetching(again: true)? = reactionRefetches.phases[target.messageID] {
            true
        } else {
            false
        }
        finishReactionRefetch(target)
        if again {
            startReactionRefetch(target)
        }
    }

    private func finishReactionRefetch(_ target: ReactedMessage) {
        reactionRefetches.phases[target.messageID] = nil
        reactionRefetches.tasks[target.messageID] = nil
    }
}
