import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BreakoutCallHandoffTests {
    @Test func cardAndPreparationUseTheSameOccurrenceReference() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        service.canPreviewMeetingLinks = true
        calls.start(service: service)
        let url = try #require(URL(string: "https://meet.example.test/room"))
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let moved = first.addingTimeInterval(604_800)
        let card = Task { await calls.calendarMeetingTitle(at: url, reference: first) }
        #expect(await eventually { service.previews[url] != nil })
        #expect(service.previewReference == first && service.previewCalendarOnly)
        service.previews.removeValue(forKey: url)?.resume(returning: "Weekly review")
        let title = await card.value
        let preparation = try #require(calls.prepareMeeting(at: url, reference: first, knownTitle: title))
        #expect(calls.callWindowSession?.displayName == "Weekly review")
        let replacement = try #require(calls.prepareMeeting(at: url, reference: moved))
        #expect(replacement != preparation)
        #expect(await eventually { service.previews[url] != nil })
        #expect(service.previewReference == moved && !service.previewCalendarOnly)
        service.previews.removeValue(forKey: url)?.resume(returning: "Moved review")
        #expect(await eventually { calls.callWindowSession?.displayName == "Moved review" })
        #expect(service.operations.isEmpty)
        await calls.stop()
    }

    @Test func onlyTheCurrentPreparationCanDisplayAnAgendaTitle() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        service.canPreviewMeetingLinks = true
        calls.start(service: service)
        let first = try #require(URL(string: "https://meet.example.test/first"))
        let second = try #require(URL(string: "https://meet.example.test/second"))
        _ = try #require(calls.prepareMeeting(at: first))
        #expect(await eventually { service.previews[first] != nil })
        let stale = try #require(calls.meetingPreviewTask)
        let target = try #require(calls.prepareMeeting(at: second))
        #expect(stale.isCancelled)
        #expect(await eventually { service.previews[second] != nil })
        service.previews.removeValue(forKey: first)?.resume(returning: "Wrong meeting")
        await stale.value
        #expect(calls.callWindowSession?.displayName == "Meeting")
        service.previews.removeValue(forKey: second)?.resume(returning: "Planning review")
        #expect(await eventually { calls.callWindowSession?.displayName == "Planning review" })
        #expect(calls.call == nil && calls.meetingPreparationID == target && service.operations.isEmpty)
        calls.joinPreparedMeeting(target)
        #expect(calls.call?.displayName == "Planning review")
        #expect(await eventually { service.joined == [second] })
        await calls.stop()
    }

    @Test func aPreparedMeetingJoinsTheExactLinkOnceAfterConfirmation() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        let first = try #require(URL(string: "https://meet.example.test/first"))
        let next = try #require(URL(string: "https://meet.example.test/next?source=chat"))
        let old = try #require(calls.prepareMeeting(at: first))
        #expect(calls.prepareMeeting(at: first) == old)
        let id = try #require(calls.prepareMeeting(at: next))
        #expect(id != old)
        #expect(calls.callWindowSession?.id == id && calls.call == nil)
        calls.dismissCallWindow(old)
        calls.joinPreparedMeeting(old)
        await Task.yield()
        #expect(service.operations.isEmpty)
        #expect(calls.meetingPreparationID == id)
        calls.joinPreparedMeeting(id)
        calls.joinPreparedMeeting(id)
        #expect(await eventually { service.joined == [next] && calls.call?.phase == .connected })
        #expect(calls.meetingPreparationID == nil && calls.call?.id == id)
        await calls.stop()
    }

    @Test func meetingMediaChoicesBelongToThePreparationThatIsJoined() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        let first = try #require(URL(string: "https://meet.example.test/first"))
        let next = try #require(URL(string: "https://meet.example.test/next"))
        let old = try #require(calls.prepareMeeting(at: first))
        calls.setMeetingJoinMedia(.init(microphoneMuted: true, cameraEnabled: true), for: old)
        let id = try #require(calls.prepareMeeting(at: next))
        calls.setMeetingJoinMedia(.init(cameraEnabled: true), for: old)
        #expect(calls.meetingJoinMedia(for: id) == MeetingJoinMedia())
        let choice = MeetingJoinMedia(microphoneMuted: true, cameraEnabled: true)
        calls.setMeetingJoinMedia(choice, for: id)
        calls.joinPreparedMeeting(id)
        #expect(calls.call?.isMuted == true)
        #expect(await eventually { service.joinMedia == [choice] && calls.call?.phase == .connected })
        #expect(calls.call?.isMuted == true)
        await calls.stop()
    }

    @Test func closingThePreviewOrStoppingItsAccountPreventsJoin() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        let otherHost = try #require(URL(string: "https://other.example.test/room"))
        #expect(calls.prepareMeeting(at: otherHost) == nil)
        let url = try #require(URL(string: "https://meet.example.test/room"))
        let first = try #require(calls.prepareMeeting(at: url))
        calls.dismissCallWindow(first)
        calls.joinPreparedMeeting(first)
        #expect(calls.callWindowSession == nil)
        let second = try #require(calls.prepareMeeting(at: url))
        await calls.stop()
        calls.joinPreparedMeeting(second)
        #expect(service.operations.isEmpty && calls.callWindowSession == nil)
    }

    @Test func anIncomingCallReplacesTheUnconfirmedPreview() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        let url = try #require(URL(string: "https://meet.example.test/room"))
        let prepared = try #require(calls.prepareMeeting(at: url))
        let incoming = UUID()
        service.sink.yield(.snapshot(AudioCallSnapshot(
            id: incoming, recipient: .init(
                conversationID: .init("call-space"), memberID: .init("caller"), displayName: "Caller"
            ), direction: .incoming, phase: .incoming
        )))
        #expect(await eventually { calls.callWindowSession?.id == incoming })
        calls.joinPreparedMeeting(prepared)
        #expect(calls.meetingPreparationID == nil && calls.call?.phase == .incoming)
        #expect(service.operations.isEmpty)
        await calls.stop()
    }

    @Test(arguments: [true, false])
    func returningFromTheWaitingRoomJoinsTheSameMeetingOnlyOnRequest(_ conversationCall: Bool) async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        let url = try #require(URL(string: "https://meet.example.test/main"))
        let target = conversationCall
            ? ConversationCallTarget(conversationID: .init("opaque-space"), displayName: "Planning")
            : ConversationCallTarget(meetingURL: url, displayName: "Planning")
        var call = ConversationCallSnapshot(id: UUID(), target: target, phase: .connected)
        let id = call.id
        calls.call = AudioCallSession(call)
        service.sink.yield(.interactionChanged(callID: id, state: .init(joinURL: url)))
        #expect(await eventually { calls.interaction?.joinURL == url })
        #expect(calls.waitingRoomReturnLink(after: id) == nil)
        service.sink.yield(.interactionChanged(callID: id, state: nil))
        call.phase = .ended
        call.endReason = .sentToWaitingRoom
        service.sink.yield(conversationCall ? .conversationSnapshot(call) : .meetingSnapshot(call))
        #expect(await eventually { calls.waitingRoomReturnLink(after: id) == url })
        #expect(service.joined.isEmpty)
        calls.returnToMeeting(after: UUID())
        calls.returnToMeeting(after: id)
        #expect(await eventually { service.joined == [url] && calls.call?.phase == .connected })
        #expect(calls.call?.id != id && calls.waitingRoomReturnLink(after: id) == nil)
        await calls.stop()
    }

    @Test(arguments: [true, false])
    func aRoomJoinsOnlyAfterConfirmedParentTerminationAndCanReturn(muted: Bool) async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        let main = try #require(URL(string: "https://meet.example.test/main"))
        _ = calls.joinMeeting(at: main)
        #expect(await eventually { calls.call?.phase == .connected && calls.interaction?.activities != nil })
        #expect(calls.currentBreakoutRoomID == nil)
        if muted {
            calls.toggleMute()
            #expect(await eventually { calls.call?.isMuted == true && !calls.isUpdatingMute })
        }
        let room = try #require(calls.interaction?.activities?.rooms.first)
        try await calls.joinBreakoutRoom(room.id)
        #expect(await eventually { calls.call?.phase == .connected && service.joined.count == 2 })
        #expect(service.operations == ["join", "end", "join"])
        #expect(calls.breakoutReturnURL == main)
        #expect(await eventually { calls.currentBreakoutRoomID != nil })
        let currentRoom = try #require(calls.currentBreakoutRoomID)
        let currentCall = calls.call?.id
        await #expect(throws: CancellationError.self) { try await calls.joinBreakoutRoom(currentRoom) }
        #expect(calls.call?.id == currentCall)
        #expect(service.operations == ["join", "end", "join"])
        try await calls.returnFromBreakoutRoom()
        #expect(await eventually { calls.call?.phase == .connected && service.joined.count == 3 })
        #expect(service.joined.last == main && calls.breakoutReturnURL == nil)
        #expect(service.joinMedia.map(\.microphoneMuted) == [false, muted, muted])
        #expect(calls.call?.isMuted == muted)
        await calls.stop()
    }

    @Test func stoppingTheAccountDuringAHeldHandoffNeverJoinsAnotherMeeting() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        _ = try calls.joinMeeting(at: #require(URL(string: "https://meet.example.test/main")))
        #expect(await eventually { calls.call?.phase == .connected && calls.interaction?.activities != nil })
        let room = try #require(calls.interaction?.activities?.rooms.first)
        service.holdCleanup = true
        let handoff = Task { try await calls.joinBreakoutRoom(room.id) }
        #expect(await eventually { service.operations.last == "end" })
        await calls.stop()
        service.holdCleanup = false
        await #expect(throws: CancellationError.self) { try await handoff.value }
        #expect(service.joined.count == 1 && calls.call == nil && calls.breakoutReturnURL == nil)
    }

    @Test(arguments: [true, false])
    func confirmedClosureReturnsToTheMainCallMutedUnlessTheUserLeaves(leaving: Bool) async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        let main = try #require(URL(string: "https://meet.example.test/main"))
        let mainID = try #require(calls.joinMeeting(at: main))
        #expect(await eventually { calls.call?.phase == .connected && calls.interaction?.activities != nil })
        let room = try #require(calls.interaction?.activities?.rooms.first)
        let roomURL = try #require(room.joinURL)
        try await calls.joinBreakoutRoom(room.id)
        #expect(await eventually { calls.call?.phase == .connected && service.joined.count == 2 })
        let roomID = try #require(calls.call?.id)
        var state = CallInteractionState(joinURL: roomURL)
        var activities = CallActivitiesState()
        activities.rooms = [.init(id: UUID(), name: room.name, isOpen: false, joinURL: roomURL)]
        activities.breakoutClosing = true
        state.activities = activities
        calls.receive(.interactionChanged(callID: roomID, state: state))
        #expect(calls.breakoutTask == nil)
        activities.breakoutClosing = nil
        state.activities = activities
        calls.receive(.interactionChanged(callID: roomID, state: state))
        #expect(calls.breakoutTask == nil)
        activities.breakoutClosed = true
        state.activities = activities
        calls.receive(.interactionChanged(callID: mainID, state: state))
        #expect(calls.breakoutTask == nil)
        activities.rooms = [.init(id: UUID(), name: "Other room", isOpen: false, joinURL: main)]
        state.activities = activities
        calls.receive(.interactionChanged(callID: roomID, state: state))
        #expect(calls.breakoutTask == nil)
        activities.rooms = [.init(id: UUID(), name: room.name, isOpen: false, joinURL: roomURL)]
        state.activities = activities

        calls.receive(.interactionChanged(callID: roomID, state: state))
        calls.receive(.interactionChanged(callID: roomID, state: state))
        if leaving {
            calls.hangUp()
            #expect(await eventually { calls.call?.phase == .ended && calls.breakoutTask == nil })
            #expect(service.operations == ["join", "end", "join", "end"])
            #expect(service.joined == [main, roomURL])
        } else {
            #expect(await eventually { calls.call?.phase == .connected && service.joined.count == 3 })
            #expect(service.operations == ["join", "end", "join", "end", "join"])
            #expect(service.joined == [main, roomURL, main])
            #expect(service.joinMedia.last == .init(microphoneMuted: true))
            #expect(calls.breakoutReturnURL == nil)
        }
        await calls.stop()
    }

    @Test func invalidLinkRefusalNamesTheInputProblemAndKeepsItsDiagnosticCode() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        service.joinFailure = ServiceFailure(code: "invalidRequest", details: .object([
            "callStage": .string("meetingLinkNormalization")
        ]))
        calls.start(service: service)
        #expect(await eventually { calls.canJoinMeetingLinks })
        let url = try #require(URL(string: "https://meet.example.test/room"))
        let id = try #require(calls.joinMeeting(at: url))
        #expect(await eventually { calls.call?.phase == .failed })
        #expect(calls.call?.failureMessage?.contains("meeting link isn’t supported") == true)
        #expect(calls.diagnosticReport(callID: id)?.contains("Call control failure: invalidRequest") == true)
        #expect(calls.diagnosticReport(callID: id)?
            .contains("Call failure stage: meetingLinkNormalization") == true)
        #expect(calls.diagnosticReport(callID: id)?.contains("Call target: meetingLink") == true)
        #expect(calls.diagnosticReport(callID: id)?.contains("advertised host=true") == true)
        #expect(calls.diagnosticReport(callID: id)?.contains("example") == false)
        #expect(calls.diagnosticReport(callID: UUID()) == nil)
        service.joinFailure = nil
        let replacement = try #require(calls.joinMeeting(at: url))
        #expect(await eventually { calls.call?.phase == .connected })
        #expect(calls.diagnosticReport(callID: id) == nil)
        #expect(calls.diagnosticReport(callID: replacement)?.contains("Call failure stage") == false)
        await calls.stop()
        #expect(calls.diagnosticReport(callID: replacement) == nil)
    }

    @Test func failedCleanupNeverStartsTheRoom() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        _ = try calls.joinMeeting(at: #require(URL(string: "https://meet.example.test/main")))
        #expect(await eventually { calls.call?.phase == .connected && calls.interaction?.activities != nil })
        let room = try #require(calls.interaction?.activities?.rooms.first)
        service.failCleanup = true
        await #expect(throws: CancellationError.self) { try await calls.joinBreakoutRoom(room.id) }
        #expect(service.joined.count == 1)
        #expect(calls.breakoutReturnURL == nil)
        await calls.stop()
    }
}

@MainActor
private final class RoomCallService: MeetingLinkAudioCallService {
    let events: AsyncStream<AudioCallEvent>
    let sink: AsyncStream<AudioCallEvent>.Continuation
    var call: ConversationCallSnapshot?
    var operations: [String] = []
    var joined: [URL] = []
    var joinMedia: [MeetingJoinMedia] = []
    let canConfigureMeetingJoinMedia = true
    var failCleanup = false
    var holdCleanup = false
    var canPreviewMeetingLinks = false
    var previews: [URL: CheckedContinuation<String?, Never>] = [:]
    var joinFailure: ServiceFailure?
    var canJoinMeetingLinks: Bool {
        true
    }

    var meetingLinkHosts: Set<String> {
        ["meet.example.test"]
    }

    init() {
        (events, sink) = AsyncStream.makeStream()
    }

    func startListening() async throws {
        sink.yield(.listenerChanged(isListening: true))
    }

    func startOutgoing(to _: AudioCallRecipient, callID _: UUID) async throws {
        throw CancellationError()
    }

    func accept(callID _: UUID) async throws {
        throw CancellationError()
    }

    func decline(callID _: UUID) async throws {
        throw CancellationError()
    }

    func setMuted(_: Bool, callID _: UUID) async throws {}
    func stop() async {}
    func previewMeetingTitle(at url: URL) async throws -> String? {
        await withCheckedContinuation { previews[url] = $0 }
    }

    var previewReference: Date?
    var previewCalendarOnly = false

    func previewMeetingTitle(at url: URL, reference: Date?, calendarOnly: Bool) async throws -> String? {
        previewReference = reference
        previewCalendarOnly = calendarOnly
        return try await previewMeetingTitle(at: url)
    }

    func joinMeeting(at url: URL, callID: UUID) async throws {
        try await joinMeeting(at: url, callID: callID, media: MeetingJoinMedia())
    }

    func joinMeeting(at url: URL, callID: UUID, media: MeetingJoinMedia) async throws {
        if let joinFailure {
            throw joinFailure
        }
        operations.append("join"); joined.append(url)
        joinMedia.append(media)
        let target = ConversationCallTarget(meetingURL: url, displayName: "Meeting")
        let value = ConversationCallSnapshot(
            id: callID, target: target, phase: .connected, isMuted: media.microphoneMuted
        )
        call = value; sink.yield(.meetingSnapshot(value))
        var activities = CallActivitiesState()
        activities.rooms = [CallBreakoutRoom(
            id: UUID(),
            name: "Room",
            isOpen: true,
            joinURL: URL(string: "https://meet.example.test/room")
        )]
        var interaction = CallInteractionState(joinURL: url)
        interaction.activities = activities
        sink.yield(.interactionChanged(callID: callID, state: interaction))
    }

    func hangUp(callID: UUID) async throws {
        guard var value = call, value.id == callID else { throw CancellationError() }
        operations.append("end")
        while holdCleanup {
            try await Task.sleep(for: .milliseconds(1))
        }
        value.phase = .ended
        value.failureMessage = failCleanup ? "Cleanup unconfirmed." : nil
        sink.yield(.meetingSnapshot(value))
    }
}
