import ChatKit
import DesignSystem
import SyncEngine

extension AppEnvironment {
    func starredScene(of model: ChatSessionModel) -> StarredMessagesScene {
        let stars = model.stars
        var state = StarredMessagesScene()
        state.showingList = stars.showingList
        state.messages = stars.messages
        state.members = stars.members
        state.knownStars = stars.knownStars
        state.pending = stars.pending
        state.isLoading = stars.isLoading
        state.readFailed = stars.readFailed
        state.hasMore = stars.hasMore
        return state
    }

    var starredActions: StarredMessagesActions? {
        guard let model = runningModel, model.capabilities.canStarMessages else { return nil }
        let current: @MainActor () -> ChatSessionModel? = { [weak self, weak model] in
            guard let model, self?.runningModel === model else { return nil }
            return model
        }
        return StarredMessagesActions(
            show: { current()?.showStarredMessages() },
            refresh: { current()?.refreshStarredMessages() },
            loadMore: { current()?.loadMoreStarredMessages() },
            set: { current()?.setMessageStarred($0, at: $1) }
        )
    }
}
