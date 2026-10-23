import ChatKit
import DesignSystem
import SyncEngine

/// The Calls list, between the session model and the window.
extension AppEnvironment {
    /// The list as the window draws it: each retained record beside its
    /// conversation, when that conversation is still listed.
    func callHistoryScene(of model: ChatSessionModel) -> CallHistoryScene {
        let history = model.callHistory
        let conversations = Dictionary(
            model.conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let status: CallHistoryScene.Status = switch history.status {
        case .idle: .idle
        case .loading: .loading
        case .loaded: .loaded
        case .failed: .failed
        }
        return CallHistoryScene(
            showingList: history.showingList,
            items: history.calls.map { message in
                CallHistoryItem(
                    message: message, conversation: conversations[message.conversationID],
                    directory: model.directory, me: model.me
                )
            },
            status: status, hasMore: history.hasMore, isLoadingMore: history.isLoadingMore,
            loadMoreFailed: history.loadMoreFailed
        )
    }

    /// Offered only by a backend that keeps call records. Each callback acts
    /// on the session it was offered for, never a replacement's.
    var callHistoryActions: CallHistoryActions? {
        guard let model = runningModel, model.capabilities.canReadCallHistory else { return nil }
        let current = { [weak self, weak model] () -> ChatSessionModel? in
            guard let model, self?.runningModel === model else { return nil }
            return model
        }
        return CallHistoryActions(
            show: { current()?.showCallHistory() },
            loadMore: { current()?.loadMoreCallHistory() },
            retry: { current()?.retryCallHistory() },
            open: { conversation, message in current()?.open(conversation: conversation, message: message) }
        )
    }
}
