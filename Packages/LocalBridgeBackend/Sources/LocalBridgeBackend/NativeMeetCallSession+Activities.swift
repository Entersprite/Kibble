import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func setActivitiesHandler(_ receive: @escaping @Sendable (CallActivitiesState) async -> Void) async {
        guard !closed else { return }
        receiveActivities = receive
        await receive(activities)
        refreshAgendaArtifacts()
        guard !closed, assignedActivityChannels == nil, activityChannelsTask == nil else { return }
        activityChannelsTask = Task { [media] in
            try? await media.prepareActivityChannel("reactions")
            guard !Task.isCancelled else { return }
            try? await media.prepareActivityChannel("meet_messages")
        }
    }

    func performActivity(_ activity: CallActivity) async throws {
        if activity.action == "keepHandRaised" {
            try await keepAutomaticHandRaised(activity)
            return
        }
        guard ready, !closed, closing == nil, connection == nil else { throw MeetDeviceSessionError.busy }
        let endsConference = activity.action == "endConference"
        let task = Task {
            _ = await refresh?.result
            try await check()
            do {
                if endsConference {
                    return try await endConference(activity)
                }
                if let setting = HostActivity(rawValue: activity.action) {
                    try await updateHostSetting(setting, enabled: activity.enabled)
                } else {
                    try await dispatchActivity(activity)
                }
            } catch {
                // Meet can refuse a Host Management change while breakout rooms are open.
                // The next explicit attempt still requires fresh host authorization.
                if ![
                    HostActivity.hostManagement.rawValue,
                    "setCohost",
                    "muteParticipant",
                    "lowerParticipantHand",
                    "removeParticipant",
                    "blockParticipant",
                    "setPinForEveryone",
                    "sendParticipantToWaitingRoom",
                    "respondToAdmission",
                    "respondToAdmissions"
                ]
                .contains(activity.action),
                case MeetCallClientError.httpStatus(403, _) = error {
                    deniedActivities.insert(activity.action)
                    activities.availableActions.removeAll { $0 == activity.action }
                    await receiveActivities?(activities)
                }
                throw error
            }
            try await check()
        }
        connection = task
        defer { connection = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        if endsConference {
            // Close awaits connection work. The provider receipt has settled that work.
            connection = nil
            await close()
        }
    }

    private func dispatchActivity(_ activity: CallActivity) async throws {
        switch activity.action {
        case "setMeetingAccess": try await updateMeetingAccess(activity)
        case "setCohost": try await changeParticipantCohost(activity)
        case "setPinForEveryone": try await setPinForEveryone(activity)
        case "muteParticipant", "muteAllParticipants": try await muteOtherParticipants(activity)
        case "lowerParticipantHand", "lowerAllHands": try await moderateHands(activity)
        case "removeParticipant", "blockParticipant", "sendParticipantToWaitingRoom":
            try await ejectParticipant(activity)
        case "respondToAdmission", "respondToAdmissions": try await respondToWaitingParticipants(activity)
        default: try await applyActivity(activity)
        }
    }

    func applyActivity(_ activity: CallActivity) async throws {
        guard activities.acceptsRecordingCaptionChoice(activity) else {
            throw ChatError.unsupported(capability: "recordingCaptions")
        }
        activitySequence += 1
        let sequence = activitySequence
        if ["createRooms", "createAndOpenRooms"].contains(activity.action), activity.options.count > 1 {
            activitySequence += UInt64(activity.options.count - 1)
        }
        switch activity.action {
        case "captions", "react", "chat", "chatWaitingRoom", "setMeetingMessagePin":
            return try await applyChannelActivity(activity, sequence: sequence)
        case "refresh": return try await refreshMeetingActivities()
        default: break
        }
        let preparation = try await prepareActivityWrite(activity)
        let baseline = Set(activities.polls.map(\.id) + activities.questions.map(\.id) + activities.rooms
            .map(\.id))
        let space = await device.activitySpace
        let request = try await activityRequest(activity, space: space, sequence: sequence)
        try await check()
        _ = try await device.performActivity(request, observed: preparation.snapshot)
        try await check()
        try await confirmActivityWrite(activity, baseline: baseline, fields: preparation.fields)
        if activity.enabled == false, ["recording", "transcription", "notes"].contains(activity.action) {
            refreshAgendaArtifacts()
        }
    }

    private func applyChannelActivity(_ activity: CallActivity, sequence: UInt64) async throws {
        guard activities.availableActions.contains(activity.action) else {
            throw ChatError.unsupported(capability: "meetingActivity")
        }
        switch activity.action {
        case "captions": try await configureCaptions(activity, sequence: sequence)
        case "react": try await sendReaction(activity, sequence: sequence)
        case "chat": try await sendActivityMessage(activity.text, sequence: sequence)
        case "chatWaitingRoom": try await sendWaitingRoomMessage(activity.text, sequence: sequence)
        case "setMeetingMessagePin": try await setMeetingMessagePin(activity, sequence: sequence)
        default: throw ChatError.unsupported(capability: "meetingActivity")
        }
    }

    private func refreshMeetingActivities() async throws {
        let denied = try? await device.activityPolicyDenials()
        try await check()
        if let denied {
            // The artifact policy read cannot clear a refusal of this meeting's host-first control.
            let hostFirst = HostActivity.allowJoiningBeforeHost.rawValue
            deniedActivities = denied.union(deniedActivities.intersection([hostFirst]))
        }
        let snapshot = try await device.activityCollections(isolatingOptionalFailures: true)
        try await check()
        await reconcileActivities(snapshot)
        refreshAgendaArtifacts()
    }

    func retireMeetingActivities() {
        resetCaptions()
        meetingMessageTimes.removeAll()
        activities.recordingCaptionLanguages.removeAll()
        activities.hostSettings = nil
        activities.meetingChat = nil
        activities.sharedPinLimit = nil
        activities.moderatorMute = nil
        activities.ownHandLowered = nil
        activities.automaticHandLowering = nil
        automaticHand.clearObservation()
        observedOwnHand = nil
        requestedOwnLowering = nil
        activities.waitingParticipants.removeAll()
        clearWaitingRoomMessages()
        hostControls = HostControlsState()
        agendaArtifactRead?.cancel()
        agendaArtifactRead = nil
        activities.artifactFiles.removeAll()
        activities.agendaAttachments = nil
        activities.agendaGuests = nil
        agendaGuestRows.removeAll()
        agendaGuestHandles.removeAll()
        agendaGuestPresenceAliases = nil
        activityChannelsTask?.cancel()
    }

    private func sendReaction(_ activity: CallActivity, sequence: UInt64) async throws {
        let data = try MeetActivityDataWire.reaction(activity.text, sequence: sequence)
        if let lastReactionTime,
           now() - lastReactionTime < .milliseconds(250) {
            throw MeetDeviceSessionError.busy
        }
        lastReactionTime = now()
        try await media.sendActivityData(channel: "reactions", data: data)
        try await check()
        activities.reactions.append(CallMeetingReaction(
            id: UUID(),
            participantID: participantLocalDevice
                .flatMap { participantHandles[$0] },
            sender: "You",
            emoji: activity.text
        ))
        activities.reactions = Array(activities.reactions.suffix(32))
        await receiveActivities?(activities)
    }

    func activityRequest(
        _ activity: CallActivity,
        space: String,
        sequence: UInt64
    ) async throws -> MeetActivityWire.Request {
        if ["recording", "transcription", "notes", "attendance"].contains(activity.action) {
            return try artifactActivityRequest(activity, space: space)
        }
        switch activity.action {
        case "createPoll":
            guard let parent = pollSeries else { throw MeetDeviceSessionError.notJoined }
            return try MeetActivityWire.createPoll(
                parent: parent,
                title: activity.text,
                options: activity.options,
                sequence: sequence
            )
        case "votePoll", "closePoll", "sharePollResults": return try pollActivityRequest(activity)
        case "askQuestion":
            guard let parent = questionSeries,
                  activity.enabled || activities.allowsAnonymousQuestions == true else {
                throw ChatError.unsupported(capability: "anonymousQuestion")
            }
            return try MeetActivityWire.createQuestion(
                parent: parent,
                text: activity.text,
                anonymous: !activity.enabled,
                sequence: sequence
            )
        case "voteQuestion": return try MeetActivityWire.voteQuestion(
                activityResource(activity.resourceID, kind: "question"),
                voted: activity.enabled
            )
        case "answerQuestion":
            _ = try activityResource(activity.resourceID, kind: "question")
            guard let id = activity.resourceID, let current = currentActivityQuestions[id] else {
                throw ChatError.unsupported(capability: "callActivityResource")
            }
            return try MeetActivityWire.answerQuestion(current)
        default: return try await roomActivityRequest(activity, space: space, sequence: sequence)
        }
    }

    private func pollActivityRequest(_ activity: CallActivity) throws -> MeetActivityWire.Request {
        switch activity.action {
        case "votePoll":
            let name = try activityResource(activity.resourceID, kind: "poll")
            guard let poll = activities.polls.first(where: { $0.id == activity.resourceID }), poll.isOpen,
                  activity.selections.count == 1,
                  activity.selections.allSatisfy({ poll.options.indices.contains($0) })
            else { throw MeetDeviceSessionError.busy }
            return try MeetActivityWire.votePoll(name, option: poll.options[activity.selections[0]])
        case "sharePollResults", "closePoll":
            _ = try activityResource(activity.resourceID, kind: "poll")
            guard let id = activity.resourceID, let current = currentActivityPolls[id] else {
                throw ChatError.unsupported(capability: "callActivityResource")
            }
            return try MeetActivityWire.updatePoll(
                current, open: activity.action == "closePoll" ? false : nil,
                resultsVisible: activity.action == "sharePollResults" ? activity.enabled : nil
            )
        default: throw ChatError.unsupported(capability: "callActivity")
        }
    }

    private func artifactActivityRequest(_ activity: CallActivity, space: String) throws -> MeetActivityWire
        .Request {
        switch activity.action {
        case "recording", "transcription", "notes":
            guard activities.artifacts.first(where: { $0.kind == activity.action })?
                .canSetEnabled(activity.enabled) == true else { throw MeetDeviceSessionError.busy }
            return try MeetActivityWire.artifact(
                space: space,
                kind: activity.action,
                start: activity.enabled,
                session: artifactSessions[activity.action],
                requestID: UUID(),
                recordingCaptionLanguage: activity.recordingCaptionLanguage
            )
        case "attendance": return try MeetActivityWire.attendance(
                space: space,
                enabled: activity.enabled,
                requestID: UUID()
            )
        default: throw ChatError.unsupported(capability: "callActivity")
        }
    }

    private func roomActivityRequest(
        _ activity: CallActivity,
        space: String,
        sequence: UInt64
    ) async throws -> MeetActivityWire.Request {
        switch activity.action {
        case "assignRoom":
            let room = try activityResource(activity.resourceID, kind: "room")
            let requested = Set(activity.participantIDs)
            let before = activities.rooms.first { $0.id == activity.resourceID }?.participants ?? []
            return try MeetActivityWire.assignRoom(
                space: space,
                room: room,
                people: activity.participantIDs.map { try activityResource($0, kind: "person") },
                unassigning: before.filter { !requested.contains($0) }.map {
                    try activityResource($0, kind: "person")
                }
            )
        case "createRooms", "createAndOpenRooms":
            guard !activity.options.isEmpty else { throw MeetCallWire.WireError.invalidIdentifier }
            let request = try MeetActivityWire.configureRooms(
                space: space, open: true, names: activity.options, sequence: sequence
            )
            if !breakoutInitialized {
                _ = try await device.performActivity(MeetActivityWire.initializeRooms(space: space))
                breakoutInitialized = true
            }
            return request
        case "openRooms", "closeRooms":
            return try MeetActivityWire.configureRooms(
                space: space,
                open: activity.action == "openRooms",
                names: [],
                sequence: sequence
            )
        default: throw ChatError.unsupported(capability: "callActivity")
        }
    }

    func activityResource(_ id: UUID?, kind: String) throws -> String {
        let identifiers: [String: Set<UUID>] = [
            "poll": Set(activities.polls.map(\.id)), "question": Set(activities.questions.map(\.id)),
            "room": Set(activities.rooms.map(\.id)), "person": Set(activities.people.map(\.id)),
            "message": Set(activities.messages.map(\.id))
        ]
        guard let id, identifiers[kind]?.contains(id) == true,
              let value = activityResources[id], value.kind == kind else {
            throw ChatError.unsupported(capability: "callActivityResource")
        }
        return value.name
    }

    func activityHandle(_ name: String, kind: String) -> UUID {
        if let existing = activityResources
            .first(where: { $0.value.name == name && $0.value.kind == kind }) {
            return existing.key
        }
        let id = UUID()
        if activityResources.count < 4096 {
            activityResources[id] = (kind, name)
        }
        return id
    }

    func receiveActivityData(channel: String, data: Data) async {
        guard ready, !closed else { return }
        if channel == "reactions", let values = try? MeetActivityDataWire.reactions(data) {
            for value in values {
                let key = participantDevices.keys
                    .first { $0 == value.device || $0.hasSuffix("/devices/" + value.device) }
                activities.reactions.append(CallMeetingReaction(
                    id: UUID(),
                    participantID: key.flatMap { participantHandles[$0] },
                    sender: key.flatMap { participantDevices[$0]?.displayName } ?? value.displayName,
                    emoji: value.emoji
                ))
            }
            activities.reactions = Array(activities.reactions.suffix(32))
            await receiveActivities?(activities)
        } else if channel == "meet_messages" {
            needsRefresh = true
        } else if channel == MeetMediaSessionWire.ActivityChannel.captions.rawValue {
            await receiveCaptionData(data)
        }
    }
}

public extension MeetDMCallTrial {
    func observeNativeActivities(
        scope: UUID,
        receive: @escaping @Sendable (CallActivitiesState) async -> Void
    ) async throws {
        guard nativeScope == scope, let native else { throw MeetDMCallTrialError.superseded }
        await native.setActivitiesHandler(receive)
    }

    func performNativeActivity(_ activity: CallActivity, scope: UUID) async throws {
        guard nativeScope == scope, let session = native else { throw MeetDMCallTrialError.superseded }
        try await session.performActivity(activity)
        // The terminal snapshot retires the source session before the receipt returns.
        if activity.action == "endConference", native == nil, cleanupScope == scope {
            return
        }
        guard nativeScope == scope, native === session else { throw MeetDMCallTrialError.superseded }
    }
}
