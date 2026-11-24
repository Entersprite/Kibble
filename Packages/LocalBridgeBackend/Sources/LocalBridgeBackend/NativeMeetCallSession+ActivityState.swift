import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func reconcileActivities(_ snapshot: MeetActivityCollections.Snapshot) async {
        let messageDevice = snapshot.messages == nil ? nil : await device.localDeviceName
        guard !closed else { return }
        // Never apply an older full collection after a newer mutation read-back.
        let accepted = snapshot.versions.filter { $0.value >= (activityVersions[$0.key] ?? 0) }
        updateActivityCollectionFailures(snapshot.unavailableFields, confirmed: Set(accepted.keys))
        let previousPermissions = localCapturePermissions
        reconcileHostControls(snapshot)
        for (key, version) in accepted {
            activityVersions[key] = version
        }
        if accepted[1] != nil, let space = snapshot.space {
            reconcileMeetingSpace(space)
        }
        if accepted[3] != nil, let messages = snapshot.messages {
            reconcileActivityMessages(messages, local: messageDevice)
        }
        if accepted[5] != nil,
           let series = snapshot
               .pollSeries {
            pollsAccepting = series.first.map { MeetActivityCollections.number(2, $0) == 1 } ?? false
            pollSeries = series.first.flatMap { MeetActivityCollections.text(
                1,
                $0
            ) }
        }
        if accepted[7] != nil,
           let series = snapshot
               .questionSeries {
            activities.allowsAnonymousQuestions = series.first
                .map { MeetActivityCollections.number(4, $0) == 1 }
            questionsAccepting = series.first.map { MeetActivityCollections.number(2, $0) == 1 } ?? false
            questionSeries = series.first.flatMap { MeetActivityCollections.text(
                1,
                $0
            ) }
        }
        if accepted[4] != nil, let polls = snapshot.polls {
            reconcilePolls(polls)
        }
        if accepted[6] != nil, let questions = snapshot.questions {
            reconcileQuestions(questions)
        }
        if accepted[8] != nil, let breakout = snapshot.breakout {
            reconcileRooms(breakout)
        }
        if accepted[9] != nil, let people = snapshot.users {
            reconcileRoomPeople(people)
        }
        pruneActivityResources()
        updateActivityAvailability()
        await publishActivityState(previousPermissions: previousPermissions)
    }

    private func publishActivityState(previousPermissions: LocalCapturePermissions) async {
        let permissions = localCapturePermissions
        activities.microphoneRestricted = permissions.microphone ? nil : true
        if !permissions.microphone {
            if previousPermissions.microphone {
                hostControls.microphoneInterruptionVersion += 1
            }
            desiredMuted = true
        }
        if permissions.microphone != previousPermissions.microphone
            || permissions.camera != previousPermissions.camera {
            await media.setCaptureAllowed(microphone: permissions.microphone, camera: permissions.camera)
        }
        if previousPermissions.screen != localCapturePermissions.screen {
            await media.setScreenSharingAllowed(localCapturePermissions.screen)
        }
        guard !closed else { return }
        await receiveActivities?(activities)
    }

    private func pruneActivityResources() {
        let ids = Set(activities.messages.map(\.id) + (activities.waitingRoomMessages ?? []).map(\.id)
            + activities.polls.map(\.id)
            + activities.questions.map(\.id) + activities.rooms.map(\.id) + activities.people.map(\.id))
        activityResources = activityResources.filter { ids.contains($0.key) }
    }

    private func reconcileMeetingSpace(_ space: Data) {
        guard let info = try? MeetActivityCollections.bytes(6, space) else { return }
        activities.artifacts = [("recording", 20), ("transcription", 17), ("notes", 29)].map { kind, field in
            guard let session = try? MeetActivityCollections.bytes(field, info) else {
                artifactSessions[kind] = nil
                return CallArtifact(kind: kind, phase: "stopped")
            }
            artifactSessions[kind] = MeetActivityCollections.text(1, session)
            let state = (try? MeetActivityCollections.bytes(2, session))
                .flatMap { MeetActivityCollections.number(
                    1,
                    $0
                ) }
            let phases: [UInt64: String] = [1: "starting", 2: "active", 3: "stopped", 4: "preconfigured"]
            let phase = state.flatMap { phases[$0] } ?? "unknown"
            return CallArtifact(
                kind: kind, phase: phase,
                recordingCaptionLanguage: kind == "recording" && ["active", "starting"].contains(phase)
                    ? MeetActivityWire.recordingCaptionLanguage(in: session) : nil
            )
        }
        if let settings = try? MeetActivityCollections.bytes(11, info) {
            activities.attendanceReportEnabled = (MeetActivityCollections.number(4, settings) ?? 0) != 0
            activityChatLocked = MeetActivityCollections.number(2, settings) == 1
        }
    }

    private func reconcileActivityMessages(_ messages: [Data], local: String?) {
        mergeActivityMessages(messages, replacing: true, local: local)
        if canMessageWaitingRoom {
            mergeWaitingRoomMessages(messages, replacing: true)
        }
    }

    func mergeActivityMessages(_ values: [Data], replacing: Bool, local: String?) {
        var messages = replacing ? [] : activities.messages
        for value in values.prefix(256) {
            guard MeetActivityDataWire.isPublicChatText(value),
                  let body = try? MeetActivityCollections.bytes(5, value),
                  let text = MeetActivityCollections.text(1, body),
                  let name = MeetActivityCollections.text(1, value) else { continue }
            let id = activityHandle(name, kind: "message")
            let device = MeetActivityCollections.text(2, value)
            let sender = device.flatMap { participantDevices[$0]?.displayName } ?? "Participant"
            let pinned = MeetActivityDataWire.publicChatPin(in: value)
            let canChangePin = pinned.map {
                Self.canChangeMeetingMessagePin(
                    sender: device,
                    local: local,
                    pinned: $0,
                    role: hostControls.access?.role
                )
            }
            let message = CallMeetingMessage(
                id: id,
                sender: sender,
                text: text,
                isPinned: pinned,
                canChangePin: canChangePin == true ? true : nil
            )
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        }
        activities.messages = Array(messages.suffix(256))
        let messageIDs = Set(activities.messages.map(\.id))
        activityResources = activityResources
            .filter { $0.value.kind != "message" || messageIDs.contains($0.key) }
    }

    func reconcilePolls(_ values: [Data]) {
        currentActivityPolls = [:]
        activities.polls = values.compactMap { value in
            guard let name = MeetActivityCollections.text(1, value),
                  name.hasPrefix((pollSeries ?? "\0") + "/"),
                  let item = MeetActivityCollections.repeated(4, value).first,
                  let question = try? MeetActivityCollections.bytes(1, item),
                  let title = MeetActivityCollections.text(1, question) else { return nil }
            let options = MeetActivityCollections.repeated(2, question)
            let labels = options.compactMap { MeetActivityCollections.text(1, $0) }
            guard (2 ... 10).contains(options.count), labels.count == options.count,
                  labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1000 }) else { return nil }
            let id = activityHandle(name, kind: "poll")
            currentActivityPolls[id] = value
            return CallPoll(
                id: id,
                question: title,
                options: labels,
                votes: options.map { option in
                    guard let answer = try? MeetActivityCollections.bytes(2, option)
                    else { return 0 }
                    return Int(clamping: MeetActivityCollections.number(1, answer) ?? 0)
                },
                selections: options.indices.filter { index in
                    guard let answer = try? MeetActivityCollections.bytes(2, options[index])
                    else { return false }
                    return MeetActivityCollections.number(2, answer) == 1
                },
                isOpen: MeetActivityCollections.number(3, value) == 2,
                resultsVisible: [1, 2].contains(MeetActivityCollections.number(5, value) ?? 0)
                    ? MeetActivityCollections.number(5, value) == 1 : nil
            )
        }
    }

    func reconcileQuestions(_ values: [Data]) {
        currentActivityQuestions = [:]
        activities.questions = values.compactMap { value in
            guard MeetActivityCollections.number(6, value) == 1,
                  let name = MeetActivityCollections.text(1, value),
                  name.hasPrefix((questionSeries ?? "\0") + "/"),
                  let text = MeetActivityCollections.text(4, value) else { return nil }
            let votes = (try? MeetActivityCollections.bytes(9, value))
                .flatMap { MeetActivityCollections.number(
                    1,
                    $0
                ) } ?? 0
            let id = activityHandle(name, kind: "question")
            currentActivityQuestions[id] = value
            return CallQuestion(
                id: id,
                text: text,
                votes: Int(clamping: votes),
                hasVoted: MeetActivityCollections.number(10, value) == 1,
                isAnswered: MeetActivityCollections.number(7, value) == 2
            )
        }
    }

    func reconcileRoomPeople(_ people: [Data]) {
        activities.people = people.compactMap { person in
            guard let name = MeetActivityCollections.text(1, person) else { return nil }
            let profile = try? MeetActivityCollections.bytes(3, person)
            let title = profile.flatMap { MeetActivityCollections.text(1, $0) } ?? "Participant"
            return CallBreakoutPerson(id: activityHandle(name, kind: "person"), name: title)
        }
        roomAssignments = [:]
        for person in people {
            guard let name = MeetActivityCollections.text(1, person) else { continue }
            // Native Meet maps field 5 to the assignment list; field 4 is
            // the user's current room and must not become an assignment.
            for assigned in MeetActivityCollections.repeated(5, person) {
                guard let room = String(data: assigned, encoding: .utf8) else { continue }
                roomAssignments[room, default: []].append(activityHandle(name, kind: "person"))
            }
        }
        applyRoomAssignments()
    }

    func applyRoomAssignments() {
        for index in activities.rooms.indices {
            guard let name = activityResources[activities.rooms[index].id]?.name else { continue }
            activities.rooms[index].participants = roomAssignments[name] ?? []
        }
    }

    func reconcileRooms(_ value: Data) {
        breakoutInitialized = (MeetActivityCollections.number(2, value) ?? 0) != 0
        let open = MeetActivityCollections.number(2, value) == 1
        activities.rooms = MeetActivityCollections.repeated(4, value).compactMap { room in
            guard MeetActivityCollections.number(5, room) != 1,
                  let name = MeetActivityCollections.text(1, room),
                  let title = MeetActivityCollections.text(3, room) else { return nil }
            let code = (try? MeetActivityCollections.bytes(2, room)).flatMap { MeetActivityCollections.text(
                1,
                $0
            ) }
            let url = code.flatMap { URL(string: "https://meet.google.com/" + $0) }
                .flatMap { try? MeetJoinLink($0).url }
            return CallBreakoutRoom(
                id: activityHandle(name, kind: "room"),
                name: title,
                isOpen: open,
                joinURL: url
            )
        }
        applyRoomAssignments()
    }
}
