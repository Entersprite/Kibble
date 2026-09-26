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
    ///
    /// Looked up in `model`, the session this launch built, not
    /// `runningModel`: an account is identified during connect on every
    /// returning launch, and stays after `.failed`, so the pane is editable
    /// then - and through `runningModel` every row read "Unavailable
    /// conversation" with Other's values (the slice 2 final review's m5).
    func conversationRuleState(for id: Conversation.ID) -> ConversationRuleState {
        let current = settings.settings
        let listed = model?.conversations.first { $0.id == id }
        let conversation = listed ?? Conversation(id: id, kind: .unknown(""))
        let title = listed.map {
            Display.title(of: $0, directory: model?.directory ?? [:], me: model?.me)
        } ?? "Unavailable conversation"
        let global = current.resolvedGlobal.delivery
        return ConversationRuleState(
            id: id, title: title,
            rule: current.rule(for: .conversation(id)) ?? NotificationRule(),
            inherited: current.inherited(byConversation: conversation),
            resolved: current.resolve(for: conversation),
            audibleFallback: global == .off ? .bannerAndSound : global
        )
    }

    /// "Paused until …", or `nil` - for the pane and the menu bar. `nil` with
    /// no account too, with no guard of its own: the model then holds default
    /// settings, and they are not paused.
    var pauseStatus: String? {
        Display.pauseStatus(settings.currentPause, now: settings.currentDate)
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
