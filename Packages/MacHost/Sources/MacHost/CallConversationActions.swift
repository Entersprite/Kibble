import AppCore
import AppKit
import ChatKit
import DesignSystem
import Foundation
import SyncEngine

extension MacAppDelegate {
    static func addInteractionActions(
        to actions: inout AudioCallActions,
        for id: UUID,
        calls: AudioCallController
    ) {
        guard let call = calls.call, call.id == id else { return }
        actions.microphoneRestricted = calls.interaction?.activities?.microphoneRestricted == true
        if call.phase == .connecting, call.admission == .waitingRoom, !calls.isEnding {
            actions.waitingRoomMessages = calls.interaction?.activities?.waitingRoomMessages
        }
        if case let .conversation(target) = call.target, let url = target.meetingURL {
            actions.meetingDetails = waitingRoomDetails(id: id, url: url, calls: calls)
        }
        if call.phase == .connected {
            actions.activities = activityScene(calls: calls, id: id)
            if calls.interaction?.canRaiseHand == true {
                actions.handRaised = calls.localHandIsRaised
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
                actions.meetingDetails = meetingDetails(id: id, url: url, calls: calls)
            }
        }
    }

    private static func waitingRoomDetails(
        id: UUID,
        url: URL,
        calls: AudioCallController
    ) -> CallMeetingDetails? {
        guard isBrowserURL(url) else { return nil }
        let currentAttachments = { [weak calls] () -> [CallAgendaAttachment]? in
            guard let calls, !calls.isEnding, let call = calls.call, call.id == id,
                  call.phase == .connecting, call.admission == .waitingRoom,
                  case let .conversation(target) = call.target, target.meetingURL == url else { return nil }
            guard let interaction = calls.interaction, interaction.joinURL == url else { return [] }
            return interaction.activities?.agendaAttachments ?? []
        }
        guard let attachments = currentAttachments() else { return nil }
        return CallMeetingDetails(
            id: id, url: url, dialIn: nil, attachments: attachments.filter { isBrowserURL($0.url) },
            copy: { _ in
                guard currentAttachments() != nil else { return }
                copyJoiningInfo(url: url, dialIn: nil, numbersURL: nil)
            }, openAttachment: { attachment in
                guard isBrowserURL(attachment.url),
                      currentAttachments()?.contains(attachment) == true else { return }
                NSWorkspace.shared.open(attachment.url)
            }
        )
    }

    private static func meetingDetails(
        id: UUID,
        url: URL,
        calls: AudioCallController
    ) -> CallMeetingDetails? {
        guard !calls.isEnding, let interaction = calls.interaction else { return nil }
        let alternateDialIns = interaction.alternateDialIns ?? []
        let numbersURL = interaction.dialInNumbersURL.flatMap { isBrowserURL($0) ? $0 : nil }
        let attachments = (interaction.activities?.agendaAttachments ?? []).filter { isBrowserURL($0.url) }
        let hasNumbers = interaction.dialIn != nil || !alternateDialIns.isEmpty || numbersURL != nil
        guard hasNumbers || !attachments.isEmpty else { return nil }
        let currentInteraction = { [weak calls] () -> CallInteractionState? in
            guard let calls, calls.call?.id == id, calls.call?.phase == .connected, !calls.isEnding,
                  let interaction = calls.interaction, interaction.joinURL == url else { return nil }
            return interaction
        }
        let openPhoneNumbers: (() -> Void)? = numbersURL.map { directory in
            {
                guard currentInteraction()?.dialInNumbersURL == directory else { return }
                NSWorkspace.shared.open(directory)
            }
        }
        let openAttachment = { (attachment: CallAgendaAttachment) in
            guard currentInteraction()?.activities?.agendaAttachments?.contains(attachment) == true,
                  isBrowserURL(attachment.url) else { return }
            NSWorkspace.shared.open(attachment.url)
        }
        return CallMeetingDetails(
            id: id, url: url, dialIn: interaction.dialIn, alternateDialIns: alternateDialIns,
            attachments: attachments, copy: { dialIn in
                guard let current = currentInteraction(),
                      current.dialInNumbersURL == interaction.dialInNumbersURL
                else { return }
                if let dialIn {
                    guard current.dialIn == dialIn || current.alternateDialIns?.contains(dialIn) == true
                    else { return }
                } else {
                    guard current.dialIn == nil, current.alternateDialIns?.isEmpty != false else { return }
                }
                copyJoiningInfo(url: url, dialIn: dialIn, numbersURL: numbersURL)
            }, openPhoneNumbers: openPhoneNumbers, openAttachment: openAttachment
        )
    }

    private static func copyJoiningInfo(url: URL, dialIn: CallDialIn?, numbersURL: URL?) {
        NSPasteboard.general.clearContents()
        if dialIn == nil, numbersURL == nil {
            NSPasteboard.general.writeObjects([url as NSURL])
        } else {
            var lines = [url.absoluteString]
            if let dialIn {
                lines.append(String(localized: "Dial \(dialIn.phoneNumber) and enter PIN \(dialIn.pin)#."))
            }
            if let numbersURL {
                lines.append(numbersURL.absoluteString)
            }
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
    }

    private static func isBrowserURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil
            && url.password == nil && (url.port == nil || url.port == 443)
    }

    private static func handGestureActions(
        for id: UUID, account: Member.ID, environment: AppEnvironment
    ) -> CallHandGestureActions? {
        let calls = environment.calls
        guard calls.call?.id == id, calls.call?.phase == .connected,
              calls.interaction?.canRaiseHand == true else { return nil }
        return CallHandGestureActions(
            isEnabled: environment.raisesHandWithCameraGesture,
            setEnabled: { [weak environment, weak calls] enabled in
                guard calls?.call?.id == id, calls?.call?.phase == .connected else { return }
                environment?.saveCameraHandGesture(enabled, for: account)
            },
            raise: { [weak environment, weak calls] in
                guard environment?.settings.account == account,
                      environment?.raisesHandWithCameraGesture == true else { return }
                calls?.raiseHandIfLowered(in: id)
            }
        )
    }

    private static func activityScene(calls: AudioCallController, id: UUID) -> CallActivitiesScene? {
        guard var state = calls.interaction?.activities else { return nil }
        if calls.breakoutReturnURL != nil {
            state.availableActions.append("returnToMainRoom")
            state.availableActions.removeAll { $0 == "setCohost" }
        }
        return CallActivitiesScene(
            state: state,
            setRecordingAndTranscriptionEnabled: { [weak calls] enabled, captionLanguage in
                guard let calls, calls.call?.id == id else { throw CancellationError() }
                try await calls.setRecordingAndTranscriptionEnabled(enabled, captionLanguage: captionLanguage)
            },
            perform: { [weak calls] activity in
                guard let calls, calls.call?.id == id else { throw CancellationError() }
                switch activity.action {
                case "joinRoom": try await calls.joinBreakoutRoom(activity.resourceID)
                case "returnToMainRoom": try await calls.returnFromBreakoutRoom()
                case "setCohost" where calls.breakoutReturnURL != nil: throw CancellationError()
                default: try await calls.performActivity(activity)
                }
            }
        )
    }

    static func addCallConversationActions(
        to actions: inout AudioCallActions,
        for id: UUID,
        environment: AppEnvironment,
        showChat: @escaping @MainActor () -> Void
    ) {
        let calls = environment.calls
        if let account = environment.settings.account {
            actions.layoutPreferences = environment.callLayoutPreferences
            actions.saveLayoutPreferences = { [weak environment, weak calls] preferences in
                guard let call = calls?.call, call.id == id, !call.phase.isTerminal else { return }
                environment?.saveCallLayoutPreferences(preferences, for: account)
            }
            actions.handGesture = handGestureActions(for: id, account: account, environment: environment)
        }
        guard calls.call?.id == id, calls.call?.phase == .connected,
              case let .running(model) = environment.phase else { return }
        actions.activities?.openGuestChat = guestChatAction(
            callID: id, environment: environment, model: model, showChat: showChat
        )
        if let destination = callChatDestination(calls: calls, model: model) {
            let scene = callChatScene(destination, id: id, environment: environment, model: model)
            if calls.call?.conversationID == nil {
                actions.activities?.meetingChat = scene
            } else {
                actions.chat = scene
            }
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

    private static func callChatDestination(calls: AudioCallController, model: ChatSessionModel)
        -> CallMeetingChat? {
        if let conversation = calls.call?.conversationID {
            return CallMeetingChat(conversationID: conversation, canSend: true)
        }
        return knownMeetingChat(calls.interaction?.activities?.meetingChat, in: model.conversations)
    }

    static func knownMeetingChat(
        _ route: CallMeetingChat?,
        in directory: [Conversation]
    ) -> CallMeetingChat? {
        guard let route, directory.contains(where: { $0.id == route.conversationID && $0.kind == .meetChat })
        else { return nil }
        return route
    }

    private static func callChatScene(
        _ destination: CallMeetingChat, id: UUID, environment: AppEnvironment, model: ChatSessionModel
    ) -> CallChatScene {
        let conversation = destination.conversationID
        let chat = model.callChat
        let matches = chat.conversationID == conversation && chat.callID == id
        let route = { [weak environment, weak model] () -> CallMeetingChat? in
            guard let environment, let model, case let .running(current) = environment.phase,
                  model === current, environment.calls.call?.id == id,
                  environment.calls.call?.phase == .connected,
                  let active = callChatDestination(calls: environment.calls, model: model),
                  active.conversationID == conversation else { return nil }
            return active
        }
        return CallChatScene(
            messages: matches ? chat.messages : [],
            directory: model.directory, me: model.me, draft: matches ? chat.draft : "",
            isSending: matches && chat.isSending, error: matches ? chat.error : nil,
            updateDraft: { [weak model] text in
                guard route() != nil else { return }
                model?.updateCallChatDraft(text, in: conversation, callID: id)
            },
            send: destination.canSend && model.capabilities.canSendMessages ? { [weak model] in
                guard route()?.canSend == true else { return }
                model?.sendCallChat(in: conversation, callID: id)
            } : nil,
            open: { [weak model] in
                guard route() != nil else { return }
                model?.openCallChat(in: conversation, callID: id)
            },
            close: { [weak model] in model?.closeCallChat(in: conversation, callID: id) }
        )
    }
}
