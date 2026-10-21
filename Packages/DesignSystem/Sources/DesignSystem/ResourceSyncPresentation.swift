import ChatKit

extension ChatSceneState {
    var resourceSyncWarning: String? {
        let failed = resourceSyncStatuses.filter {
            $0.phase == .failed && ($0.conversationID == nil || $0.conversationID == selected)
        }
        if failed.contains(where: { $0.resource == .directory }) {
            return "Could not refresh conversations. Showing saved data."
        }
        if failed.contains(where: { $0.resource == .history }) {
            return "Could not refresh messages. Showing saved data."
        }
        if failed.contains(where: { $0.resource == .followedThreads }) {
            return "Followed threads could not be refreshed."
        }
        return nil
    }
}
