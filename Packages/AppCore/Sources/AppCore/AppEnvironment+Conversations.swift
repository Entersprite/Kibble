import ChatKit
import DesignSystem
import Foundation
import SyncEngine

public extension AppEnvironment {
    /// Whether per-conversation rules can be edited: a running session with an
    /// identified account. Rules belong to an account (spec §3.1).
    var canEditNotificationRules: Bool {
        guard case .running = phase else { return false }
        return settings.account != nil
    }

    /// One conversation's editor state - the sheet's and the pane's.
    func conversationRuleState(for id: Conversation.ID) -> ConversationRuleState {
        let current = settings.settings
        let listed = runningModel?.conversations.first { $0.id == id }
        let conversation = listed ?? Conversation(id: id, kind: .unknown(""))
        let title = listed.map {
            Display.title(of: $0, directory: runningModel?.directory ?? [:], me: runningModel?.me)
        } ?? "Unavailable conversation"
        return ConversationRuleState(
            id: id, title: title,
            rule: current.rule(for: .conversation(id)) ?? NotificationRule(),
            inherited: current.inherited(byConversation: conversation),
            resolved: current.resolve(for: conversation)
        )
    }

    /// "Paused until …", or `nil` - for the pane and the menu bar.
    var pauseStatus: String? {
        guard settings.account != nil else { return nil }
        return Display.pauseStatus(settings.currentPause, now: settings.currentDate)
    }

    func pauseNotifications(_ duration: PauseDuration) {
        settings.pause(for: duration)
    }

    func resumeNotifications() {
        settings.resume()
    }

    internal var runningModel: ChatSessionModel? {
        guard case let .running(model) = phase else { return nil }
        return model
    }
}
