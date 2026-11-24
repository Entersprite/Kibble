import ChatKit
import DesignSystem
import Foundation
import SyncEngine

public extension AppEnvironment {
    /// Whether per-conversation rules can be edited: a running session with an
    /// identified account. Rules belong to an account (spec §3.1).
    var canEditNotificationRules: Bool {
        guard case .running = phase else { return false }
        return settings.account != nil && (policyStatus?.canEdit ?? (policyReplica == nil))
    }

    func spaceNotificationSetting(for id: Conversation.ID) -> SpaceNotificationSetting? {
        guard let session = runningModel, session.capabilities.canSetNotificationLevel,
              let conversation = session.conversations.first(where: { $0.id == id && $0.kind == .space })
        else { return nil }
        return SpaceNotificationSetting(
            level: conversation.notificationLevel, muted: conversation.isMuted,
            canSave: session.connectionState == .connected, muteUntil: conversation.notificationMuteUntil
        ) { [weak self] level in
            guard self?.runningModel === session else { throw CancellationError() }
            try await session.setSpaceNotificationLevel(level, in: id)
        }
    }

    func conversationMuteSetting(for id: Conversation.ID) -> ConversationMuteSetting? {
        guard let session = runningModel, let row = session.conversations.first(where: { $0.id == id }),
              session.capabilities.canSetConversationMute(in: row.kind)
        else { return nil }
        let pause: Pause = row.isMuted ? row.notificationMuteUntil.map(Pause.until) ?? .untilResumed : .off
        return ConversationMuteSetting(
            pause: pause, canSave: session.connectionState == .connected
        ) { [weak self] pause in
            guard self?.runningModel === session else { throw CancellationError() }
            try await session.setConversationMute(pause, in: id)
        }
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
        return ConversationRuleState(
            id: id, title: title,
            rule: current.rule(for: .conversation(id)) ?? NotificationRule(),
            inherited: current.inherited(byConversation: conversation),
            resolved: current.resolve(for: conversation)
        )
    }

    /// "Paused until …", or `nil` - for the pane and the menu bar. `nil` with
    /// no account too, with no guard of its own: the model then holds default
    /// settings, and they are not paused.
    var pauseStatus: String? {
        deviceNotificationPause?.status ?? Display.pauseStatus(
            settings.currentPause,
            now: settings.currentDate
        )
    }

    func pauseNotifications(_ duration: PauseDuration) {
        if let deviceNotificationPause {
            deviceNotificationPause.pause(for: duration)
        } else {
            settings.pause(for: duration)
        }
    }

    func resumeNotifications() {
        deviceNotificationPause?.resume()
        if deviceNotificationPause == nil || settings.isPaused {
            settings.resume()
        }
    }

    internal var runningModel: ChatSessionModel? {
        guard case let .running(model) = phase else { return nil }
        return model
    }
}
