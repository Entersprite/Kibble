import AppCore
import AppKit
import ChatKit
import DesignSystem
import Foundation

extension MacAppDelegate {
    static func addInteractionActions(
        to actions: inout AudioCallActions,
        for id: UUID,
        calls: AudioCallController
    ) {
        if calls.call?.id == id, calls.call?.phase == .connected {
            actions.activities = activityScene(calls: calls, id: id)
            if calls.interaction?.canRaiseHand == true {
                actions.handRaised = calls.isHandRaised
                actions.isUpdatingHand = calls.isUpdatingInteraction
                actions.toggleHandRaised = {
                    if calls.call?.id == id {
                        calls.toggleHandRaised()
                    }
                }
            }
            if let url = calls.interaction?.joinURL, url.scheme == "https", url.user == nil,
               url.password == nil {
                actions.meetingURL = url
                actions.copyMeetingLink = {
                    guard calls.call?.id == id else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                }
            }
        }
    }

    private static func activityScene(calls: AudioCallController, id: UUID) -> CallActivitiesScene? {
        guard var state = calls.interaction?.activities else { return nil }
        if calls.breakoutReturnURL != nil {
            state.availableActions.append("returnToMainRoom")
        }
        return CallActivitiesScene(state: state) { [weak calls] activity in
            guard let calls, calls.call?.id == id else { throw CancellationError() }
            switch activity.action {
            case "joinRoom": try await calls.joinBreakoutRoom(activity.resourceID)
            case "returnToMainRoom": try await calls.returnFromBreakoutRoom()
            default: try await calls.performActivity(activity)
            }
        }
    }

    static func addCallConversationActions(
        to actions: inout AudioCallActions,
        for id: UUID,
        environment: AppEnvironment
    ) {
        let calls = environment.calls
        guard calls.call?.id == id, calls.call?.phase == .connected,
              case let .running(model) = environment.phase else { return }
        if let conversation = calls.call?.conversationID {
            let chat = model.callChat
            actions.chat = CallChatScene(
                messages: chat.conversationID == conversation ? chat.messages : [],
                directory: model.directory,
                me: model.me, draft: chat.conversationID == conversation ? chat.draft : "",
                isSending: chat.isSending, error: chat.error,
                updateDraft: { [weak model] in model?.updateCallChatDraft($0, in: conversation) },
                send: model.capabilities
                    .canSendMessages ? { [weak model] in model?.sendCallChat(in: conversation) } : nil,
                open: { [weak model] in model?.openCallChat(in: conversation) },
                close: { [weak model] in model?.closeCallChat(in: conversation) }
            )
        }
        if calls.interaction?.canInvite == true {
            actions.invitations = CallInvitationActions(search: { [weak environment, weak model] query in
                guard let environment, let model, calls.call?.id == id,
                      case let .running(current) = environment.phase,
                      current === model else { throw CancellationError() }
                let people = try await model.searchCallPeople(query)
                guard calls.call?.id == id else { throw CancellationError() }
                return people
            }, invite: { member in
                guard calls.call?.id == id else { throw CancellationError() }
                try await calls.inviteToCall(member)
            })
        }
    }
}
