import ChatKit
import DesignSystem
import Foundation
import SyncEngine

extension AppEnvironment {
    private static let unreadFilterKey = "unread.filter."

    static func savedUnreadFilter(in preferences: UserDefaults, namespace: String) -> UnreadFilter {
        preferences.string(forKey: unreadFilterKey + namespace).flatMap(UnreadFilter.init(rawValue:))
            ?? .badgeOnly
    }

    func unreadScene(_ model: ChatSessionModel) -> UnreadScene {
        var scene = UnreadScene()
        scene.showing = model.showingUnread
        scene.filter = unreadFilter
        scene.messages = model.visibleUnreadMessages
        scene.readOnThisDevice = model.individuallyReadUnreadMessages
        scene.conversationsWithUnread = model.unreadConversationIDs
        scene.badgeConversations = badgeConversationIDs(in: model)
        scene.isLoading = model.unreadHistoryLoading
        scene.historyFailed = model.unreadHistoryFailed
        return scene
    }

    func unreadActions(_ model: ChatSessionModel, canEditNotificationRules: Bool) -> UnreadActions {
        let canMark = canEditNotificationRules && model.capabilities.canMarkRead
        return UnreadActions(
            show: { [weak self, weak model] in
                guard let self, let model, runningModel === model else { return }
                unreadFilter = Self.savedUnreadFilter(in: preferences, namespace: preferenceNamespace)
                model.showUnread()
            },
            retry: { [weak self, weak model] in
                guard let model, self?.runningModel === model else { return }
                model.retryUnreadHistory()
            },
            setFilter: { [weak self, weak model] filter in
                guard let self, let model, runningModel === model else { return }
                unreadFilter = filter
                preferences.set(filter.rawValue, forKey: Self.unreadFilterKey + preferenceNamespace)
            },
            markMessageRead: { [weak self, weak model] message in
                guard let model, self?.runningModel === model else { return }
                model.markInboxMessageRead(message)
            },
            markRead: canMark
                ? { [weak self, weak model] messages, conversation in
                    guard let model else { return }
                    self?.markUnread(messages, in: conversation, model: model)
                } : nil,
            markAllRead: { [weak self, weak model] filter in
                guard let self, let model, runningModel === model else { return }
                let allowed = canMark ? Set(model.conversations.lazy
                    .filter { self.settings.resolved(for: $0).readReceipts }.map(\.id)) : []
                let scope = filter == .badgeOnly ? badgeConversationIDs(in: model) : nil
                model.markAllUnreadMessagesRead(
                    in: allowed, restrictingTo: scope, includingReplies: filter == .all
                )
            }
        )
    }

    private func markUnread(_ messages: [Message], in id: Conversation.ID, model: ChatSessionModel) {
        guard runningModel === model,
              let row = model.conversations.first(where: { $0.id == id }),
              settings.resolved(for: row).readReceipts else { return }
        model.markUnreadMessagesRead(messages, in: id)
    }
}
