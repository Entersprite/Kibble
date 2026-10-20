import ChatKit

/// Where the transcript scrolls (ruling 14). A scroll target, once loaded,
/// is scrolled to once, and after that the newest message is again what
/// arrivals scroll to. Pure, so each case is a test.
enum TranscriptScroll {
    /// A target as it was asked for: the message, and the open that asked
    /// (`ChatSceneState.searchOpenGeneration`). The same message asked for
    /// again by a newer open is a new request, so it is honoured again.
    struct Request: Equatable {
        let id: Message.ID
        var generation = 0
    }

    /// What `onChange` watches: the newest message, the target, its
    /// generation, and whether the target has loaded. So a target that
    /// arrives after the newest still fires, and so does the same target
    /// opened again.
    struct Trigger: Equatable {
        let newest: Message.ID?
        let target: Message.ID?
        let generation: Int
        let targetLoaded: Bool
        let loadingNewer: Bool
        let latestJump: Bool

        init(_ state: ChatSceneState) {
            newest = state.messages.last?.id
            target = state.scrollTarget
            generation = state.searchOpenGeneration
            targetLoaded = state.scrollTarget.map { id in state.messages.contains { $0.id == id } } ?? false
            loadingNewer = state.isLoadingNewerMessages
            latestJump = state.newerMessagesAreLatestJump
        }

        /// The same, for the thread panel's messages.
        init(_ panel: ThreadPanelState) {
            newest = panel.messages.last?.id
            target = panel.scrollTarget
            generation = panel.scrollGeneration
            targetLoaded = panel.scrollTarget.map { id in panel.messages.contains { $0.id == id } } ?? false
            loadingNewer = false
            latestJump = false
        }
    }

    enum Destination: Equatable {
        case message(Message.ID)
        case newest(Message.ID)
    }

    static func destination(
        messages: [Message], target: Message.ID?, generation: Int = 0, honoured: Request?,
        followNewest: Bool = true
    ) -> Destination? {
        if let target, Request(id: target, generation: generation) != honoured,
           messages.contains(where: { $0.id == target }) {
            return .message(target)
        }
        return followNewest ? messages.last.map { .newest($0.id) } : nil
    }
}
