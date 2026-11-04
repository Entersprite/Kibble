import ChatKit
import Foundation

extension FixtureAudioCallService {
    func resetActivities() {
        activityState = CallActivitiesState()
        activityState.availableActions = [
            "refresh",
            "react",
            "chat",
            "recording",
            "transcription",
            "notes",
            "attendance",
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
        activityState.artifacts = ["recording", "transcription", "notes"].map { CallArtifact(
            kind: $0,
            phase: "stopped"
        ) }
        activityState.attendanceReportEnabled = false
        activityState.allowsAnonymousQuestions = true
        activityState.people = [
            CallBreakoutPerson(id: nextActivityID(), name: "You"),
            CallBreakoutPerson(id: nextActivityID(), name: "Taylor")
        ]
    }

    func activityInteraction(url: URL?) -> CallInteractionState {
        var state = CallInteractionState(joinURL: url, canRaiseHand: true, canInvite: true)
        state.activities = activityState
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
        guard (currentCall?.id == callID && currentCall?.phase == .connected) ||
            (currentConversationCall?.id == callID && currentConversationCall?.phase == .connected),
            activityState.availableActions.contains(activity.action) else { throw CancellationError() }
        switch activity.action {
        case "refresh": break
        case "react":
            activityState.reactions.append(CallMeetingReaction(
                id: nextActivityID(),
                sender: "You",
                emoji: activity.text
            ))
            activityState.reactions = Array(activityState.reactions.suffix(32))
        case "chat":
            activityState.messages.append(CallMeetingMessage(
                id: nextActivityID(),
                sender: "You",
                text: activity.text
            ))
            activityState.messages = Array(activityState.messages.suffix(256))
        default: try applyManagedActivity(activity)
        }
        continuation.yield(.interactionChanged(callID: callID, state: activityInteraction(
            url: currentConversationCall?.target
                .meetingURL ?? URL(string: "https://meet.example.test/fixture")
        )))
    }

    private func applyManagedActivity(_ activity: CallActivity) throws {
        switch activity.action {
        case "recording", "transcription", "notes":
            if let index = activityState.artifacts.firstIndex(where: { $0.kind == activity.action }) {
                activityState.artifacts[index].phase = activity.enabled ? "active" : "stopped"
            }
        case "attendance": activityState.attendanceReportEnabled = activity.enabled
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
