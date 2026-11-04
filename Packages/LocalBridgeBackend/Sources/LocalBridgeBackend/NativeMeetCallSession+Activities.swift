import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func setActivitiesHandler(_ receive: @escaping @Sendable (CallActivitiesState) async -> Void) async {
        receiveActivities = receive
        await receive(activities)
        guard activityChannelsTask == nil else { return }
        activityChannelsTask = Task { [media] in
            try? await media.prepareActivityChannel("reactions")
            guard !Task.isCancelled else { return }
            try? await media.prepareActivityChannel("meet_messages")
        }
    }

    func performActivity(_ activity: CallActivity) async throws {
        guard ready, !closed, connection == nil else { throw MeetDeviceSessionError.busy }
        let task = Task {
            _ = await refresh?.result
            try await check()
            do {
                try await applyActivity(activity)
            } catch {
                if case MeetCallClientError.httpStatus(403, _) = error {
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
    }

    func applyActivity(_ activity: CallActivity) async throws {
        if ["react", "chat"].contains(activity.action),
           !activities.availableActions.contains(activity.action) {
            throw ChatError.unsupported(capability: "meetingActivity")
        }
        activitySequence += 1
        let sequence = activitySequence
        if activity.action == "createRooms", activity.options.count > 1 {
            activitySequence += UInt64(activity.options.count - 1)
        }
        let space = await device.activitySpace
        if activity.action == "react" {
            try await sendReaction(activity, sequence: sequence)
            return
        }
        if activity.action == "chat" {
            let data = try MeetActivityDataWire.chat(activity.text, sequence: sequence)
            let response = try await media.exchangeActivityData(channel: "meet_messages", data: data) {
                MeetActivityDataWire.isChatResponse($0, sequence: sequence)
            }
            let message = try MeetActivityDataWire.chatResponse(response, sequence: sequence)
            await mergeActivityMessages([message], replacing: false)
            return
        }
        if activity.action == "refresh" {
            if let denied = try? await device.activityPolicyDenials() {
                deniedActivities = denied
            }
            try await check()
            let snapshot = try await device.activityCollections()
            try await check()
            await reconcileActivities(snapshot)
            return
        }
        // Re-read source state before resource-addressed operations. It is not a
        // write retry and a missing/foreign resource never falls back to creation.
        let snapshot = try await device.activityCollections()
        try await check()
        await reconcileActivities(snapshot)
        guard activities.availableActions.contains(activity.action) else {
            throw ChatError.unsupported(capability: "meetingActivity")
        }
        let baseline = Set(activities.polls.map(\.id) + activities.questions.map(\.id) + activities.rooms
            .map(\.id))
        let request = try await activityRequest(activity, space: space, sequence: sequence)
        _ = try await device.performActivity(request)
        try await check()
        let confirmed = try await device.activityCollections()
        try await check()
        await reconcileActivities(confirmed)
        try confirmActivity(activity, baseline: baseline)
    }

    private func sendReaction(_ activity: CallActivity, sequence: UInt64) async throws {
        let data = try MeetActivityDataWire.reaction(activity.text, sequence: sequence)
        if let lastReactionTime,
           now() - lastReactionTime < .milliseconds(250) {
            throw MeetDeviceSessionError.busy
        }
        lastReactionTime = now()
        try await media.sendActivityData(channel: "reactions", data: data)
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
            let phase = activities.artifacts.first { $0.kind == activity.action }?.phase
            let allowed = activity.enabled ? ["stopped", "preconfigured"] : ["active", "starting"]
            guard let phase, allowed.contains(phase) else { throw MeetDeviceSessionError.busy }
            return try MeetActivityWire.artifact(
                space: space,
                kind: activity.action,
                start: activity.enabled,
                session: artifactSessions[activity.action],
                requestID: UUID()
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
            return try MeetActivityWire.assignRoom(
                space: space,
                room: activityResource(activity.resourceID, kind: "room"),
                people:
                activity.participantIDs.map { try activityResource(
                    $0,
                    kind: "person"
                ) }
            )
        case "createRooms":
            if !breakoutInitialized {
                _ = try await device.performActivity(MeetActivityWire.initializeRooms(space: space))
                breakoutInitialized = true
            }
            return try MeetActivityWire.configureRooms(
                space: space,
                open: activities.rooms.contains(where: \.isOpen),
                names: activity.options,
                sequence: sequence
            )
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
            "room": Set(activities.rooms.map(\.id)), "person": Set(activities.people.map(\.id))
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
        guard nativeScope == scope, native === session else { throw MeetDMCallTrialError.superseded }
    }
}
