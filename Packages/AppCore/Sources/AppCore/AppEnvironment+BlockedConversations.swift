import DesignSystem
import SyncEngine

public struct BlockedConversationsSettings {
    public let state: BlockedConversationsSettingsState
    public let actions: BlockedConversationsSettingsActions
    public let session: ObjectIdentifier
}

public struct BlockedPeopleSettings {
    public let state: BlockedPeopleSettingsState
    public let actions: BlockedPeopleSettingsActions
    public let session: ObjectIdentifier
}

public extension AppEnvironment {
    var blockedConversationsSettings: BlockedConversationsSettings? {
        guard let model = runningModel, model.capabilities.canManageBlockedConversations else { return nil }
        let current: @MainActor () -> ChatSessionModel? = { [weak self, weak model] in
            guard let model, self?.runningModel === model else { return nil }
            return model
        }
        let blocked = model.blockedRooms
        let error: String? = switch blocked.failure {
        case .load: "Refresh to try loading blocked conversations again."
        case .unblock: "Couldn’t confirm the unblock. Refresh the list before trying again."
        case nil: nil
        }
        return BlockedConversationsSettings(
            state: BlockedConversationsSettingsState(
                rows: blocked.rows, isAvailable: model.isClientTransportAvailable,
                isLoading: blocked.isLoading,
                pending: blocked.pending, error: error
            ),
            actions: BlockedConversationsSettingsActions(
                refresh: { current()?.refreshBlockedConversations() },
                unblock: { current()?.unblockConversation($0) }
            ),
            session: ObjectIdentifier(model)
        )
    }

    var blockedPeopleSettings: BlockedPeopleSettings? {
        guard let model = runningModel, model.capabilities.canManageBlockedPeople else { return nil }
        let current: @MainActor () -> ChatSessionModel? = { [weak self, weak model] in
            guard let model, self?.runningModel === model else { return nil }
            return model
        }
        let blocked = model.blockedPeople
        let error: String? = switch blocked.failure {
        case .load: "Refresh to try loading blocked people again."
        case .unblock: "Couldn’t confirm the unblock. Refresh the list before trying again."
        case nil: nil
        }
        return BlockedPeopleSettings(
            state: BlockedPeopleSettingsState(
                rows: blocked.rows, isAvailable: model.isClientTransportAvailable,
                isLoading: blocked.isLoading, pending: blocked.pending, error: error
            ),
            actions: BlockedPeopleSettingsActions(
                refresh: { current()?.refreshBlockedPeople() },
                unblock: { current()?.unblockPerson($0) }
            ),
            session: ObjectIdentifier(model)
        )
    }
}
