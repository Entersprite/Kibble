import ChatKit
import Foundation

extension FixtureAudioCallService {
    private static let defaultCallActions = [
        "refresh",
        "react",
        "chat",
        "chatWaitingRoom",
        "setMeetingMessagePin",
        "captions",
        "recording",
        "transcription",
        "notes",
        "attendance",
        "hostManagement",
        "allowJoiningBeforeHost",
        "allowJoinRequests",
        "setMeetingAccess",
        "muteParticipant",
        "lowerParticipantHand",
        "lowerAllHands",
        "removeParticipant",
        "blockParticipant",
        "setPinForEveryone",
        "sendParticipantToWaitingRoom",
        "respondToAdmission",
        "respondToAdmissions",
        "createPoll",
        "votePoll",
        "closePoll",
        "sharePollResults",
        "askQuestion",
        "voteQuestion",
        "answerQuestion",
        "assignRoom",
        "createRooms",
        "openRooms",
        "closeRooms"
    ]

    func resetActivities(includeAgenda: Bool = false) {
        activityState = CallActivitiesState()
        activityState.sharedPinLimit = 3
        activityState.availableActions = Self.defaultCallActions
        activityState.artifacts = ["recording", "transcription", "notes"].map { CallArtifact(
            kind: $0,
            phase: "stopped"
        ) }
        if includeAgenda {
            activityState.agendaAttachments = [CallAgendaAttachment(
                title: "Planning agenda", url: URL(string: "https://files.example.test/planning-agenda")!
            )]
            activityState.agendaGuests = [.init(
                id: nextActivityID(),
                displayName: "Olive Outfield",
                response: "accepted",
                chatAddress: "olive@example.invalid"
            )]
        }
        activityState.attendanceReportEnabled = false
        activityState.hostSettings = CallHostSettings(
            managementEnabled: false, reactionsAllowed: true, chatMessagesAllowed: true,
            screenSharingAllowed: true, microphoneAllowed: true, cameraAllowed: true,
            joiningBeforeHostAllowed: true, waitingRoomEnabled: false,
            meetingAccess: CallMeetingAccess(
                preset: "trusted",
                availablePresets: ["open", "trusted", "restricted"],
                joinRequestsAllowed: true
            )
        )
        activityState.captionLanguages = CallCaptionLanguages(
            live: ["en-US"], translations: ["en-US": ["fr-FR", "hu-HU"]]
        )
        activityState.recordingCaptionLanguages = ["en-US", "fr-FR"]
        activityState.allowsAnonymousQuestions = true
        activityState.people = [
            CallBreakoutPerson(id: nextActivityID(), name: "You"),
            CallBreakoutPerson(id: nextActivityID(), name: "Taylor")
        ]
    }

    func activityInteraction(url: URL?) -> CallInteractionState {
        var state = CallInteractionState(joinURL: url, canRaiseHand: true, canInvite: true)
        state.activities = activityState
        let hasDialIn = url?.host == "meet.example.test"
        state.dialIn = hasDialIn ? .init(phoneNumber: "+1 202-555-0142", pin: "012345678") : nil
        state.alternateDialIns = hasDialIn ? [.init(phoneNumber: "+44 20 7946 0958", pin: "987654321")] : nil
        return state
    }

    func nextActivityID() -> UUID {
        activitySequence += 1
        let bytes = (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: activitySequence >> ($0 * 8)) }
        return UUID(uuid: (
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7]
        ))
    }

    public func performCallActivity(_ activity: CallActivity, callID: UUID) async throws {
        guard isConnected(callID),
              activityState.availableActions.contains(activity.action),
              activityState.acceptsRecordingCaptionChoice(activity) else { throw CancellationError() }
        switch activity.action {
        case "endConference":
            guard activity.enabled else { throw CancellationError() }
            try await hangUp(callID: callID)
            return
        case "refresh": break
        case "keepHandRaised":
            try keepFixtureHandRaised(activity)
        case "muteParticipant", "muteAllParticipants", "removeParticipant", "blockParticipant", "setCohost",
             "sendParticipantToWaitingRoom", "setPinForEveryone", "lowerParticipantHand", "lowerAllHands",
             "respondToAdmission", "respondToAdmissions":
            try performFixturePeopleActivity(activity, callID: callID)
        case "react":
            activityState.reactions.append(CallMeetingReaction(
                id: nextActivityID(),
                sender: "You",
                emoji: activity.text
            ))
            activityState.reactions = Array(activityState.reactions.suffix(32))
        case "chat", "chatWaitingRoom", "setMeetingMessagePin": try performFixtureMeetingChat(activity)
        case "captions": try applyFixtureCaptions(activity)
        default: try applyManagedActivity(activity)
        }
        publishFixtureActivities(callID: callID)
    }

    private func performFixtureMeetingChat(_ activity: CallActivity) throws {
        if activity.action == "chatWaitingRoom" {
            let message = CallMeetingMessage(id: nextActivityID(), sender: "You", text: activity.text)
            activityState.waitingRoomMessages = Array(((activityState.waitingRoomMessages ?? []) + [message])
                .suffix(256))
            return
        }
        if activity.action == "chat" {
            activityState.messages.append(CallMeetingMessage(
                id: nextActivityID(), sender: "You", text: activity.text,
                isPinned: false, canChangePin: true
            ))
            activityState.messages = Array(activityState.messages.suffix(256))
            return
        }
        guard activity.participantIDs.isEmpty,
              let index = activityState.messages.firstIndex(where: {
                  $0.id == activity.resourceID && $0.canChangePin == true
              }) else { throw CancellationError() }
        activityState.messages[index].isPinned = activity.enabled
    }

    private func performFixturePeopleActivity(_ activity: CallActivity, callID: UUID) throws {
        switch activity.action {
        case "setCohost": try setFixtureCohost(activity, callID: callID)
        case "setPinForEveryone": try setFixtureSharedPin(activity, callID: callID)
        case "lowerParticipantHand", "lowerAllHands": try lowerFixtureHands(activity, callID: callID)
        case "sendParticipantToWaitingRoom": try sendFixtureParticipantToWaitingRoom(activity, callID: callID)
        case "respondToAdmission", "respondToAdmissions": try respondToFixtureAdmission(
                activity,
                callID: callID
            )
        default: try moderateFixtureParticipants(activity, callID: callID)
        }
    }

    private func sendFixtureParticipantToWaitingRoom(_ activity: CallActivity, callID: UUID) throws {
        guard activity.enabled, let devices = participantDevices,
              let target = devices.first(where: { $0.id == activity.resourceID && !$0.isLocal
                      && !$0.isPresentation && $0.canSendToWaitingRoom == true
              }),
              activityState.waitingParticipants.count < 256,
              activityState.waitingParticipants.contains(where: \.isInWaitingRoom)
        else { throw CancellationError() }
        activityState.waitingParticipants.append(CallWaitingParticipant(
            id: nextActivityID(), name: target.displayName ?? "Guest", canDeny: false
        ))
        let remaining = devices.filter { $0.id != target.id && $0.parentID != target.id }
        setParticipantDevices(remaining, callID: callID)
    }

    public func setWaitingParticipants(_ participants: [CallWaitingParticipant], callID: UUID) {
        guard isConnected(callID), participants.count <= 256,
              Set(participants.map(\.id)).count == participants.count else { return }
        activityState.waitingParticipants = participants
        publishFixtureActivities(callID: callID)
    }

    public func setMeetingChat(_ meetingChat: CallMeetingChat?, callID: UUID) {
        guard isConnected(callID) else { return }
        activityState.meetingChat = meetingChat
        publishFixtureActivities(callID: callID)
    }

    func isConnected(_ callID: UUID) -> Bool {
        (currentCall?.id == callID && currentCall?.phase == .connected)
            || (currentConversationCall?.id == callID && currentConversationCall?.phase == .connected)
    }

    func publishFixtureActivities(callID: UUID) {
        let url = if let currentConversationCall {
            currentConversationCall.target.meetingURL
        } else {
            URL(string: "https://meet.example.test/fixture")
        }
        continuation.yield(.interactionChanged(callID: callID, state: activityInteraction(url: url)))
    }

    private func respondToFixtureAdmission(_ activity: CallActivity, callID: UUID) throws {
        let bulk = activity.action == "respondToAdmissions"
        let ids = bulk ? activity.participantIDs : activity.resourceID.map { [$0] } ?? []
        let requested = Set(ids)
        guard bulk ? activity.resourceID == nil : activity.participantIDs.isEmpty,
              !ids.isEmpty, ids.count <= 256, requested.count == ids.count else { throw CancellationError() }
        let eligible = activityState.waitingParticipants.filter {
            requested.contains($0.id) && (activity.enabled || $0.canDeny)
        }
        guard !eligible.isEmpty else { throw CancellationError() }
        let confirmed = Set(eligible.map(\.id))
        activityState.waitingParticipants.removeAll { confirmed.contains($0.id) }
        if activity.enabled {
            let joined = eligible.map {
                CallParticipantDevice(id: nextActivityID(), displayName: $0.name, role: .participant)
            }
            setParticipantDevices((participantDevices ?? []) + joined, callID: callID)
        }
        if confirmed != requested {
            publishFixtureActivities(callID: callID)
            throw ChatError.transport("Some waiting requests could not be confirmed.")
        }
    }

    private func setFixtureCohost(_ activity: CallActivity, callID: UUID) throws {
        guard let id = activity.resourceID, var devices = participantDevices,
              let index = devices.firstIndex(where: { $0.id == id && !$0.isLocal && !$0.isPresentation }),
              devices[index].role == (activity.enabled ? .participant : .cohost) else {
            throw CancellationError()
        }
        devices[index].role = activity.enabled ? .cohost : .participant
        setParticipantDevices(devices, callID: callID)
    }

    private func moderateFixtureParticipants(_ activity: CallActivity, callID: UUID) throws {
        let bulk = activity.action == "muteAllParticipants"
        guard activity.enabled, bulk == (activity.resourceID == nil), var devices = participantDevices else {
            throw CancellationError()
        }
        let targets = devices.indices.filter {
            !devices[$0].isLocal && !devices[$0]
                .isPresentation && (bulk || devices[$0].id == activity.resourceID)
        }
        guard bulk || !targets.isEmpty else { throw CancellationError() }
        if activity.action == "blockParticipant" {
            guard activity.participantIDs.isEmpty, let target = targets.first,
                  devices[target].canBlockInMeeting == true else { throw CancellationError() }
        }
        if ["removeParticipant", "blockParticipant"].contains(activity.action), let id = activity.resourceID {
            setParticipantDevices(devices.filter { $0.id != id && $0.parentID != id }, callID: callID)
            return
        }
        for index in targets {
            devices[index].microphoneMuted = true
        }
        setParticipantDevices(devices, callID: callID)
    }

    private func applyFixtureCaptions(_ activity: CallActivity) throws {
        guard activity.enabled else {
            activityState.captions = nil
            return
        }
        guard activity.options.count == 2, let languages = activityState.captionLanguages else {
            throw CancellationError()
        }
        let spoken = activity.options[0], display = activity.options[1]
        guard languages.supports(spoken: spoken, display: display) else { throw CancellationError() }
        let examples = ["en-US": "Welcome to the meeting.", "fr-FR": "Bienvenue.", "hu-HU": "Üdvözlöm!"]
        activityState.captions = CallCaptionState(
            spokenLanguage: spoken,
            displayLanguage: display,
            segments: [
                CallCaptionSegment(id: nextActivityID(), speaker: "Taylor", text: examples[display] ?? "")
            ]
        )
    }

    private func applyManagedActivity(_ activity: CallActivity) throws {
        switch activity.action {
        case "recording", "transcription", "notes":
            if let index = activityState.artifacts.firstIndex(where: { $0.kind == activity.action }) {
                activityState.artifacts[index].phase = activity.enabled ? "active" : "stopped"
                activityState.artifacts[index].recordingCaptionLanguage = activity.recordingCaptionLanguage
            }
        case "attendance": activityState.attendanceReportEnabled = activity.enabled
        case "hostManagement", "allowReactions", "allowChatMessages", "allowScreenSharing",
             "allowMicrophone", "allowCamera", "allowJoiningBeforeHost", "allowJoinRequests",
             "setMeetingAccess":
            try applyHostSetting(activity)
        case "createPoll":
            guard (2 ... 10).contains(activity.options.count),
                  !activity.text.isEmpty else { throw CancellationError() }
            activityState.polls.append(CallPoll(
                id: nextActivityID(),
                question: activity.text,
                options: activity.options,
                votes: activity.options.map { _ in 0 },
                isOpen: true, resultsVisible: false
            ))
        case "votePoll", "closePoll", "sharePollResults": try updatePoll(activity)
        case "askQuestion":
            activityState.questions.append(CallQuestion(id: nextActivityID(), text: activity.text))
        case "voteQuestion", "answerQuestion": try updateQuestion(activity)
        default: try applyFixtureRooms(activity)
        }
    }

    private func applyFixtureRooms(_ activity: CallActivity) throws {
        switch activity.action {
        case "assignRoom":
            guard let index = activityState.rooms.firstIndex(where: { $0.id == activity.resourceID }),
                  Set(activity.participantIDs).isSubset(of: Set(activityState.people.map(\.id)))
            else { throw CancellationError() }
            activityState.rooms[index].participants = activity.participantIDs
        case "createRooms":
            activityState.rooms += activity.options.map { name in
                CallBreakoutRoom(
                    id: nextActivityID(),
                    name: name,
                    isOpen: false,
                    joinURL: URL(string: "https://meet.example.test/room")
                )
            }
        case "openRooms", "closeRooms":
            for index in activityState.rooms
                .indices {
                activityState.rooms[index].isOpen = activity.action == "openRooms"
            }
        default: throw ChatError.unsupported(capability: "callActivity")
        }
    }

    private func updatePoll(_ activity: CallActivity) throws {
        guard let index = activityState.polls.firstIndex(where: { $0.id == activity.resourceID }) else {
            throw CancellationError()
        }
        if activity.action == "sharePollResults" {
            activityState.polls[index].resultsVisible = activity.enabled; return
        }
        if activity.action == "closePoll" {
            activityState.polls[index].isOpen = false; return
        }
        var poll = activityState.polls[index]
        guard poll.isOpen,
              activity.selections.allSatisfy({ poll.options.indices.contains($0) })
        else { throw CancellationError() }
        for selected in poll.selections {
            poll.votes[selected] -= 1
        }
        poll.selections = activity.selections
        for selected in poll.selections {
            poll.votes[selected] += 1
        }
        activityState.polls[index] = poll
    }

    private func updateQuestion(_ activity: CallActivity) throws {
        guard let index = activityState.questions.firstIndex(where: { $0.id == activity.resourceID }) else {
            throw CancellationError()
        }
        if activity.action == "answerQuestion" {
            activityState.questions[index].isAnswered = true; return
        }
        var question = activityState.questions[index]
        question.votes += (activity.enabled ? 1 : 0) - (question.hasVoted ? 1 : 0)
        question.hasVoted = activity.enabled
        activityState.questions[index] = question
    }
}
